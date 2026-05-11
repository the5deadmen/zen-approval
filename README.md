# zen-approval

Stop clicking "yes" all day. Get a push notification on your phone — or approve directly from the terminal.

When Claude Code wants to do something risky (git push, rm, writing .env files), you get a notification on your phone with **YES / NO** buttons AND clickable approval links in the terminal. First response wins. Everything else runs without asking.

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/the5deadmen/zen-approval/main/install.sh | bash
```

The script will ask for your ntfy channel name, then set up everything automatically.

**Requirements:**
- Node.js
- Claude Code
- [ntfy](https://ntfy.sh) app on your phone (iOS / Android) — free, no account needed
- Same WiFi network as your Mac

---

## Dual-channel approval

When a risky action is detected, the terminal shows:

```
────────────────────────────────────────
  APPROBATION REQUISE
  [Bash] git push origin main

  OUI → http://192.168.1.x:7878/yes?token=...
  NON → http://192.168.1.x:7878/no?token=...

  En attente (tel ou lien ci-dessus)...
────────────────────────────────────────
```

Click the link in the terminal or tap the notification on your phone. First response wins.

---

## How it works

**Blocked outright** — no notification, instant reject:
- `rm -rf`
- `git push --force`
- `git reset --hard`
- `git clean`
- `find -delete`
- `sudo`
- Pipe to shell (`| bash`)

**Sends a notification** — you approve or reject from your phone:
- `git push origin main`
- `npm install`, `npx`
- `rm` / `unlink`
- `curl`, `wget`
- Writing `.env` files

**Passes silently** — no interruption:
- `git add`, `git commit`, `git status`, `git diff`
- `npm run build`, `npm test`, `npm start`
- `Read`, `Edit`, `ls`, `mkdir`, `cp`, `mv`

**Ambiguous** — unrecognized Bash command → sends a notification:
- Bash commands that don't match any tier above
- MCP tools and other non-Bash tools pass silently

---

## What gets installed

| File | Purpose |
|------|---------|
| `~/.claude/approval-server.js` | Node server running on port 7878 |
| `~/.claude/hooks/pre-tool-use.sh` | Hook called before every Claude tool use |
| `~/.claude/settings.json` | Global Claude Code permissions |
| `~/Library/LaunchAgents/com.claude-approval.plist` | Auto-start on login (macOS) |

---

## Test it

```bash
# Check the server is running
curl http://localhost:7878/health

# Simulate a sensitive action
curl -X POST http://localhost:7878/ask \
  -H "Content-Type: application/json" \
  -d '{"tool":"Bash","action":"git push origin main"}'
```

You should get a notification on your phone with YES / NO buttons.

---

## Manual install

If you prefer not to pipe to bash:

```bash
git clone https://github.com/the5deadmen/zen-approval.git
cd zen-approval
bash install.sh
```

---

## Design decisions

**If the server is unreachable, actions are auto-approved.** The alternative (blocking everything) would freeze Claude entirely on a server crash. The LaunchAgent restarts it automatically, so downtime is brief.

**Your ntfy channel name is your password.** Use something unguessable like `claude-john-a8f3e1`. Anyone who knows the channel can see your notifications.

**The install merges into your existing settings.json** — it adds permissions and the hook without touching your other config.

---

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.claude-approval.plist
rm ~/Library/LaunchAgents/com.claude-approval.plist
rm ~/.claude/approval-server.js
rm ~/.claude/hooks/pre-tool-use.sh
```

The uninstall does not modify `settings.json` — remove the `PreToolUse` hook entry manually if needed.
