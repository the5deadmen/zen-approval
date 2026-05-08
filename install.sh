#!/bin/bash
# install.sh — zen-approval
# bash <(curl -fsSL https://raw.githubusercontent.com/the5deadmen/zen-approval/main/install.sh)

set -e

echo ""
echo "📱 Quel est ton canal ntfy ?"
echo "   (ouvre ntfy sur ton tel, crée un canal unique genre : claude-prenom-xxxx)"
echo ""
read -p "Canal : " NTFY_TOPIC

if [ -z "$NTFY_TOPIC" ]; then
  echo "❌ Canal vide. Installation annulée."
  exit 1
fi

TOKEN=$(openssl rand -hex 16)

echo ""
echo "✅ Canal : $NTFY_TOPIC"
echo "📁 Installation en cours..."
echo ""

CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"

mkdir -p "$HOOKS_DIR"

# ─── 1. approval-server.js ───────────────────────────────────────────────────
cat > "$CLAUDE_DIR/approval-server.js" << 'SERVEREOF'
const http = require("http");

const NTFY_TOPIC = "__NTFY_TOPIC__";
const TOKEN      = "__TOKEN__";
const PORT       = 7878;
const TIMEOUT_MS = 5 * 60 * 1000;

let pendingRequest = null;

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);

  if (req.method === "POST" && url.pathname === "/ask") {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", async () => {
      const { action, tool } = JSON.parse(body);
      console.log(`\n[ACTION] [${tool}] ${action}`);
      await sendNtfy(tool, action);
      const approved = await waitForAnswer();
      console.log(approved ? "[OK] Approuve" : "[REFUSE] Refuse");
      res.writeHead(200);
      res.end(JSON.stringify({ approved }));
    });
    return;
  }

  if (req.method === "GET" && url.pathname === "/yes") {
    if (url.searchParams.get("token") !== TOKEN) {
      res.writeHead(403, { "Content-Type": "text/plain" });
      res.end("403 Forbidden");
      return;
    }
    if (pendingRequest) { pendingRequest.resolve(true); pendingRequest = null; }
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    res.end("<h2 style='font-family:sans-serif;color:green;padding:40px'>OUI — Claude continue.</h2>");
    return;
  }

  if (req.method === "GET" && url.pathname === "/no") {
    if (url.searchParams.get("token") !== TOKEN) {
      res.writeHead(403, { "Content-Type": "text/plain" });
      res.end("403 Forbidden");
      return;
    }
    if (pendingRequest) { pendingRequest.resolve(false); pendingRequest = null; }
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    res.end("<h2 style='font-family:sans-serif;color:red;padding:40px'>NON — Claude abandonne.</h2>");
    return;
  }

  if (req.method === "GET" && url.pathname === "/health") {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("ok");
    return;
  }

  res.writeHead(404);
  res.end();
});

async function sendNtfy(tool, action) {
  const localIP = getLocalIP();
  const yesURL  = `http://${localIP}:${PORT}/yes?token=${TOKEN}`;
  const noURL   = `http://${localIP}:${PORT}/no?token=${TOKEN}`;
  try {
    await fetch(`https://ntfy.sh/${NTFY_TOPIC}`, {
      method: "POST",
      headers: {
        "Title":        `Claude — ${tool}`,
        "Priority":     "high",
        "Tags":         "warning",
        "Actions":      `view, OUI, ${yesURL}; view, NON, ${noURL}`,
        "Content-Type": "text/plain",
      },
      body: `[${tool}] ${action}`,
    });
    console.log("[ntfy] Notification envoyee");
  } catch (e) {
    console.error("[ntfy] Erreur:", e.message);
  }
}

function waitForAnswer() {
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      pendingRequest = null;
      console.log("[timeout] Refuse automatiquement apres 5 min");
      resolve(false);
    }, TIMEOUT_MS);
    pendingRequest = { resolve: (val) => { clearTimeout(timer); resolve(val); } };
  });
}

function getLocalIP() {
  const nets = require("os").networkInterfaces();
  for (const name of Object.keys(nets))
    for (const net of nets[name])
      if (net.family === "IPv4" && !net.internal) return net.address;
  return "localhost";
}

server.listen(PORT, () => {
  console.log(`[server] Approval server sur http://localhost:${PORT}`);
  console.log(`[ntfy]   Canal : ntfy.sh/${NTFY_TOPIC}\n`);
});
SERVEREOF

sed -i "" "s/__NTFY_TOPIC__/$NTFY_TOPIC/g" "$CLAUDE_DIR/approval-server.js"
sed -i "" "s/__TOKEN__/$TOKEN/g"           "$CLAUDE_DIR/approval-server.js"

# ─── 2. pre-tool-use.sh ──────────────────────────────────────────────────────
cat > "$HOOKS_DIR/pre-tool-use.sh" << 'HOOKEOF'
#!/bin/bash
# ~/.claude/hooks/pre-tool-use.sh
# Niveaux : [BLOQUE] [VALIDATION] [AUTO] [REFUSE] [OK]

SERVER="http://localhost:7878"

# ── Parse stdin ────────────────────────────────────────────────────────────────
TMPFILE=$(mktemp)
cat > "$TMPFILE"

TOOL=$(python3 -c "
import json
d = json.load(open('$TMPFILE'))
print(d.get('tool_name', ''))
" 2>/dev/null)

COMMAND=$(python3 -c "
import json
d = json.load(open('$TMPFILE'))
print(d.get('tool_input', {}).get('command', ''))
" 2>/dev/null)

FILE_PATH=$(python3 -c "
import json
d = json.load(open('$TMPFILE'))
i = d.get('tool_input', {})
print(i.get('file_path', '') or i.get('path', '') or i.get('old_path', '') or '')
" 2>/dev/null)

rm -f "$TMPFILE"

# ── Helpers ────────────────────────────────────────────────────────────────────
log() { echo "$1" >&2; }

block() {
  log "[BLOQUE] $1"
  python3 -c "import json,sys; print(json.dumps({'decision':'block','reason':sys.argv[1]}))" "$1"
  exit 1
}

ask() {
  log "[VALIDATION] $TOOL : $1"
  local PAYLOAD
  PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({'tool': sys.argv[1], 'action': sys.argv[2][:300]}))
" "$TOOL" "$1" 2>/dev/null)

  local RESPONSE
  RESPONSE=$(curl -s --max-time 310 -X POST "$SERVER/ask" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")

  if echo "$RESPONSE" | grep -q '"approved":true'; then
    log "[OK] Approuve"
    exit 0
  else
    log "[REFUSE] Refuse par l'utilisateur"
    python3 -c "import json; print(json.dumps({'decision':'block','reason':'Refuse par utilisateur'}))"
    exit 1
  fi
}

auto() {
  log "[AUTO] $TOOL${1:+ : $1}"
  exit 0
}

# ── Détection fichiers sensibles (outils Read/Edit/Write) ──────────────────────
is_sensitive_path() {
  local p="$1"
  [[ -z "$p" ]] && return 1
  local b
  b=$(basename "$p")
  [[ "$b" =~ ^\.env(\..*)?$ ]] && return 0
  [[ "$p" =~ \.(pem|key|p12|pfx)$ ]] && return 0
  [[ "$b" =~ ^id_(rsa|ed25519|ecdsa|dsa)(\.pub)?$ ]] && return 0
  [[ "$b" == "authorized_keys" ]] && return 0
  [[ "$b" == ".npmrc" || "$b" == ".pypirc" ]] && return 0
  [[ "$p" =~ /\.ssh/ || "$p" =~ /\.aws/ ]] && return 0
  [[ "$p" =~ /config/secrets ]] && return 0
  return 1
}

# Détection fichiers sensibles dans une commande bash
cmd_has_sensitive() {
  local cmd="$1"
  echo "$cmd" | grep -qE '(^|[[:space:]])\.env([[:space:].]|$)' && return 0
  echo "$cmd" | grep -qE '\.env\.' && return 0
  echo "$cmd" | grep -qE '[[:alnum:]_-]+\.(pem|key)([[:space:]]|$)' && return 0
  echo "$cmd" | grep -qE '(^|[[:space:]])(id_rsa|id_ed25519|id_ecdsa|id_dsa)([[:space:]]|$)' && return 0
  echo "$cmd" | grep -qE '(^|[[:space:]])\.(npmrc|pypirc)([[:space:]]|$)' && return 0
  echo "$cmd" | grep -qE '\.ssh/' && return 0
  echo "$cmd" | grep -qE '\.aws/' && return 0
  echo "$cmd" | grep -qE 'config/secrets' && return 0
  return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# OUTIL BASH
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$TOOL" == "Bash" ]]; then

  # ── 1. BLOQUE DIRECT ──────────────────────────────────────────────────────

  # rm -rf (toutes combinaisons : -rf, -fr, -rfv, -Rf, etc.)
  if echo "$COMMAND" | grep -qE '\brm\b' && \
     echo "$COMMAND" | grep -qE '\-[a-zA-Z]*(r[a-zA-Z]*f|f[a-zA-Z]*r)'; then
    block "rm recursif+force interdit : $COMMAND"
  fi

  # git push --force / --force-with-lease
  if echo "$COMMAND" | grep -qE '\bgit[[:space:]]+push\b.*--force(-with-lease)?([[:space:]]|$)'; then
    block "git push --force interdit : $COMMAND"
  fi

  # git reset --hard
  if echo "$COMMAND" | grep -qE '\bgit[[:space:]]+reset\b.*--hard([[:space:]]|$)'; then
    block "git reset --hard interdit : $COMMAND"
  fi

  # git clean
  if echo "$COMMAND" | grep -qE '\bgit[[:space:]]+clean\b'; then
    block "git clean interdit : $COMMAND"
  fi

  # find -delete
  if echo "$COMMAND" | grep -qE '\bfind\b' && \
     echo "$COMMAND" | grep -qE '[[:space:]]-delete([[:space:]]|$)'; then
    block "find -delete interdit : $COMMAND"
  fi

  # Pipe vers shell
  if echo "$COMMAND" | grep -qE '\|[[:space:]]*/?(bash|sh)([[:space:]]|$)'; then
    block "Pipe vers shell interdit : $COMMAND"
  fi

  # sudo
  if echo "$COMMAND" | grep -qE '(^|[;&|][[:space:]]*)sudo[[:space:]]'; then
    block "sudo interdit : $COMMAND"
  fi

  # chmod -R / chown -R
  if echo "$COMMAND" | grep -qE '\bchmod[[:space:]]+-R\b'; then
    block "chmod -R interdit : $COMMAND"
  fi
  if echo "$COMMAND" | grep -qE '\bchown[[:space:]]+-R\b'; then
    block "chown -R interdit : $COMMAND"
  fi

  # ── 2. AUTO PASS ──────────────────────────────────────────────────────────

  if echo "$COMMAND" | grep -qE '^(ls|pwd|echo|wc|file|which|type|whoami|date|uname|df|du|ps|env|printenv)([[:space:]]|$)'; then
    cmd_has_sensitive "$COMMAND" && ask "$COMMAND"
    auto "$COMMAND"
  fi

  if echo "$COMMAND" | grep -qE '^(cat|head|tail|less|more)([[:space:]]|$)'; then
    cmd_has_sensitive "$COMMAND" && ask "$COMMAND"
    auto "$COMMAND"
  fi

  if echo "$COMMAND" | grep -qE '^grep([[:space:]]|$)'; then
    auto "$COMMAND"
  fi

  if echo "$COMMAND" | grep -qE '^cd([[:space:]]|$)'; then
    auto "$COMMAND"
  fi

  if echo "$COMMAND" | grep -qE '^(mkdir|touch)([[:space:]]|$)'; then
    auto "$COMMAND"
  fi

  if echo "$COMMAND" | grep -qE '^(cp|mv)([[:space:]]|$)'; then
    cmd_has_sensitive "$COMMAND" && ask "$COMMAND"
    auto "$COMMAND"
  fi

  if echo "$COMMAND" | grep -qE '^find([[:space:]]|$)' && \
     ! echo "$COMMAND" | grep -qE '[[:space:]]-delete'; then
    auto "$COMMAND"
  fi

  if echo "$COMMAND" | grep -qE '^sed([[:space:]]|$)' && \
     ! echo "$COMMAND" | grep -qE 'sed[[:space:]]+-i'; then
    auto "$COMMAND"
  fi

  if echo "$COMMAND" | grep -qE '^awk([[:space:]]|$)' && \
     ! echo "$COMMAND" | grep -qE '>[[:space:]]*\S'; then
    auto "$COMMAND"
  fi

  if echo "$COMMAND" | grep -qE '^git[[:space:]]+(status|diff|log|show|describe|rev-parse|ls-files|ls-tree|shortlog|blame)([[:space:]]|$)'; then
    auto "$COMMAND"
  fi

  if echo "$COMMAND" | grep -qE '^git[[:space:]]+branch([[:space:]]+(-[avrl]|-{1,2}(all|remotes|verbose|list))|$)'; then
    auto "$COMMAND"
  fi

  if echo "$COMMAND" | grep -qE '^git[[:space:]]+stash([[:space:]]|$)'; then
    auto "$COMMAND"
  fi

  if echo "$COMMAND" | grep -qE '^git[[:space:]]+(add|commit)([[:space:]]|$)'; then
    auto "$COMMAND"
  fi

  if echo "$COMMAND" | grep -qE '^npm[[:space:]]+run[[:space:]]+(build|lint|typecheck|type-check|test|start|dev|format|check)([[:space:]]|$)'; then
    auto "$COMMAND"
  fi
  if echo "$COMMAND" | grep -qE '^npm[[:space:]]+(test|start)([[:space:]]|$)'; then
    auto "$COMMAND"
  fi

  if echo "$COMMAND" | grep -qE '^node[[:space:]]+[^-].*\.m?[jt]s([[:space:]]|$)'; then
    auto "$COMMAND"
  fi

  # ── 3. VALIDATION ─────────────────────────────────────────────────────────

  if cmd_has_sensitive "$COMMAND"; then
    ask "Fichier sensible detecte : $COMMAND"
  fi

  if echo "$COMMAND" | grep -qE '^npm[[:space:]]+(install|i|update|uninstall|remove|un|ci|dedupe|audit)\b'; then
    ask "$COMMAND"
  fi
  if echo "$COMMAND" | grep -qE '^npx[[:space:]]'; then
    ask "$COMMAND"
  fi
  if echo "$COMMAND" | grep -qE '^pnpm[[:space:]]+(add|install|update|upgrade|remove|uninstall)\b'; then
    ask "$COMMAND"
  fi
  if echo "$COMMAND" | grep -qE '^yarn[[:space:]]+(add|upgrade|remove)\b'; then
    ask "$COMMAND"
  fi
  if echo "$COMMAND" | grep -qE '^bun[[:space:]]+(add|install|update|remove|x)\b'; then
    ask "$COMMAND"
  fi

  if echo "$COMMAND" | grep -qE '^curl[[:space:]]'; then
    ask "$COMMAND"
  fi
  if echo "$COMMAND" | grep -qE '^wget[[:space:]]'; then
    ask "$COMMAND"
  fi

  if echo "$COMMAND" | grep -qE '^git[[:space:]]+(clone|pull|push|merge|rebase|reset|cherry-pick|fetch)\b'; then
    ask "$COMMAND"
  fi

  if echo "$COMMAND" | grep -qE '^rm[[:space:]]'; then
    ask "$COMMAND"
  fi

  auto "$COMMAND"

fi

# ══════════════════════════════════════════════════════════════════════════════
# OUTILS FICHIERS : Read, Edit, Write, MultiEdit
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$TOOL" =~ ^(Read|Edit|Write|MultiEdit)$ ]]; then
  if is_sensitive_path "$FILE_PATH"; then
    ask "Acces fichier sensible [$TOOL] : $FILE_PATH"
  fi
  auto
fi

# ── Tous les autres outils (MCP, etc.) → AUTO ─────────────────────────────────
auto
HOOKEOF

chmod +x "$HOOKS_DIR/pre-tool-use.sh"

# ─── 3. settings.json global ─────────────────────────────────────────────────
if [ -f "$CLAUDE_DIR/settings.json" ]; then
  cp "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.json.backup"
  echo "   ⚠️  settings.json existant sauvegardé → settings.json.backup"
fi

cat > "$CLAUDE_DIR/settings.json" << 'SETTINGSEOF'
{
  "permissions": {
    "allow": [
      "Read(*)",
      "Edit(*)",
      "Write(*)",
      "Bash(*)"
    ],
    "deny": [
      "Bash(rm -rf *)",
      "Bash(rm -fr *)",
      "Bash(rm -Rf *)",
      "Bash(rm -rF *)",
      "Bash(git push --force *)",
      "Bash(git push --force)",
      "Bash(git push --force-with-lease *)",
      "Bash(git push --force-with-lease)",
      "Bash(git reset --hard *)",
      "Bash(git reset --hard)",
      "Bash(git clean *)",
      "Bash(find * -delete *)",
      "Bash(sudo *)",
      "Bash(chmod -R *)",
      "Bash(chown -R *)"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/pre-tool-use.sh"
          }
        ]
      }
    ]
  }
}
SETTINGSEOF

# ─── 4. LaunchAgent macOS — démarrage automatique ────────────────────────────
PLIST="$HOME/Library/LaunchAgents/com.claude-approval.plist"
NODE_PATH=$(which node)

launchctl unload "$PLIST" 2>/dev/null || true

cat > "$PLIST" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.claude-approval</string>
  <key>ProgramArguments</key>
  <array>
    <string>${NODE_PATH}</string>
    <string>${CLAUDE_DIR}/approval-server.js</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${CLAUDE_DIR}/approval-server.log</string>
  <key>StandardErrorPath</key>
  <string>${CLAUDE_DIR}/approval-server.log</string>
</dict>
</plist>
PLISTEOF

launchctl load "$PLIST"

echo ""
echo "✅ Installation terminée !"
echo ""
echo "   ~/.claude/approval-server.js    → serveur (port 7878)"
echo "   ~/.claude/hooks/pre-tool-use.sh → hook PreToolUse"
echo "   ~/.claude/settings.json         → permissions + deny rules"
echo "   LaunchAgent chargé              → démarre au login"
echo ""
echo "📱 Canal ntfy : $NTFY_TOPIC"
echo "   Abonne-toi à ce canal dans l'app ntfy."
echo ""
echo "🧪 Test : curl http://localhost:7878/health"
echo ""
echo "🚀 Lance Claude Code — c'est prêt."
