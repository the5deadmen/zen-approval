#!/bin/bash
# install.sh — Lance une seule fois depuis n'importe où
# bash ~/Downloads/install-claude-approval.sh

set -e

# ─── Canal ntfy ──────────────────────────────────────────────────────────────
echo ""
echo "📱 Quel est ton canal ntfy ?"
echo "   (ouvre ntfy sur ton tel, crée un canal unique genre : claude-prenom-xxxx)"
echo ""
read -p "Canal : " NTFY_TOPIC

if [ -z "$NTFY_TOPIC" ]; then
  echo "❌ Canal vide. Installation annulée."
  exit 1
fi

# Token de sécurité — généré à l'install, jamais partagé
TOKEN=$(openssl rand -hex 12)

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
const TOKEN = "__TOKEN__";
const PORT = 7878;
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
      console.log(approved ? "[OK] Approuve" : "[NON] Refuse");
      res.writeHead(200);
      res.end(JSON.stringify({ approved }));
    });
    return;
  }

  if (req.method === "GET" && url.pathname === "/yes") {
    if (url.searchParams.get("token") !== TOKEN) { res.writeHead(403); res.end("Forbidden"); return; }
    if (pendingRequest) { pendingRequest.resolve(true); pendingRequest = null; }
    res.writeHead(200, { "Content-Type": "text/html" });
    res.end("<h2 style='font-family:sans-serif;color:green;padding:40px'>OUI - Claude continue.</h2>");
    return;
  }

  if (req.method === "GET" && url.pathname === "/no") {
    if (url.searchParams.get("token") !== TOKEN) { res.writeHead(403); res.end("Forbidden"); return; }
    if (pendingRequest) { pendingRequest.resolve(false); pendingRequest = null; }
    res.writeHead(200, { "Content-Type": "text/html" });
    res.end("<h2 style='font-family:sans-serif;color:red;padding:40px'>NON - Claude abandonne.</h2>");
    return;
  }

  res.writeHead(404);
  res.end();
});

async function sendNtfy(tool, action) {
  const localIP = getLocalIP();
  try {
    await fetch(`https://ntfy.sh/${NTFY_TOPIC}`, {
      method: "POST",
      headers: {
        "Title": "Claude - Action sensible",
        "Priority": "high",
        "Tags": "warning",
        "Actions": `view, OUI, http://${localIP}:${PORT}/yes?token=${TOKEN}; view, NON, http://${localIP}:${PORT}/no?token=${TOKEN}`,
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
      console.log("[timeout] Refuse automatiquement");
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
  console.log(`[server] Approval server demarre sur http://localhost:${PORT}`);
  console.log(`[ntfy] Canal: ntfy.sh/${NTFY_TOPIC}\n`);
});
SERVEREOF

# Injecter le canal et le token
sed -i "" "s/__NTFY_TOPIC__/$NTFY_TOPIC/g" "$CLAUDE_DIR/approval-server.js"
sed -i "" "s/__TOKEN__/$TOKEN/g" "$CLAUDE_DIR/approval-server.js"

# ─── 2. pre-tool-use.sh ──────────────────────────────────────────────────────
cat > "$HOOKS_DIR/pre-tool-use.sh" << 'HOOKEOF'
#!/bin/bash
TOOL="$1"
INPUT="$2"
SERVER="http://localhost:7878"

# Toujours bloqué, jamais de demande
if echo "$INPUT" | grep -qE "rm -rf|--force|reset --hard|DROP TABLE"; then
  echo "Bloque automatiquement : $TOOL" >&2
  exit 1
fi

# Demande validation
NEEDS_APPROVAL=false
echo "$INPUT" | grep -qE "git push origin main" && NEEDS_APPROVAL=true
echo "$INPUT" | grep -qE "^rm |unlink" && NEEDS_APPROVAL=true
[ "$TOOL" = "Write" ] && echo "$INPUT" | grep -qE "\.(env)$" && NEEDS_APPROVAL=true

if [ "$NEEDS_APPROVAL" = "true" ]; then
  echo "En attente de ton approbation..." >&2
  RESPONSE=$(curl -s -X POST "$SERVER/ask" \
    -H "Content-Type: application/json" \
    -d "{\"tool\": \"$TOOL\", \"action\": $(echo "$INPUT" | head -c 300 | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}")
  echo "$RESPONSE" | grep -q '"approved":true' || { echo "Refuse." >&2; exit 1; }
  echo "Approuve." >&2
fi

exit 0
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
      "Bash(npm run *)",
      "Bash(npm install *)",
      "Bash(npm ci)",
      "Bash(git add *)",
      "Bash(git commit *)",
      "Bash(git status)",
      "Bash(git diff *)",
      "Bash(git log *)",
      "Bash(git stash)",
      "Bash(git stash pop)",
      "Bash(git checkout *)",
      "Bash(git branch *)",
      "Bash(ls *)",
      "Bash(cat *)",
      "Bash(mkdir *)",
      "Bash(cp *)",
      "Bash(mv *)"
    ],
    "deny": [
      "Bash(rm -rf *)",
      "Bash(git push --force*)",
      "Bash(git reset --hard *)",
      "Bash(git push origin main)"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/pre-tool-use.sh \"$TOOL_NAME\" \"$TOOL_INPUT\""
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

echo "✅ Installation terminée !"
echo ""
echo "   ~/.claude/approval-server.js    → serveur"
echo "   ~/.claude/hooks/pre-tool-use.sh → hook"
echo "   ~/.claude/settings.json         → permissions globales"
echo "   LaunchAgent chargé              → démarre au login"
echo ""
echo "📱 Canal ntfy configuré : $NTFY_TOPIC"
echo "   Abonne-toi à ce canal dans l'app ntfy sur ton tel."
echo ""
echo "🧪 Test rapide :"
echo "   curl http://localhost:7878/yes"
echo ""
echo "🚀 Lance Claude Code normalement, c'est prêt."
