# zen-approval

Stop clicking "yes" all day. Get a push notification on your phone instead.

When Claude Code wants to do something risky (git push, rm, writing .env files), your phone gets a notification with **YES / NO** buttons. Everything else runs without asking.

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

## How it works

**Blocked outright** — no notification, instant reject:
- `rm -rf`
- `git push --force`
- `git reset --hard`
- `DROP TABLE`

**Sends a notification** — you approve or reject from your phone:
- `git push origin main`
- `rm` / `unlink`
- Writing `.env` files

**Passes silently** — no interruption:
- `git add`, `git commit`, `git status`, `git diff`
- `npm install`, `npm run`
- `Read`, `Edit`, `ls`, `mkdir`, `cp`, `mv`

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
curl http://localhost:7878/yes

# Simulate a sensitive action
curl -X POST http://localhost:7878/ask \
  -H "Content-Type: application/json" \
  -d '{"tool":"Bash","action":"git push origin main"}'
```

You should get a notification on your phone with YES / NO buttons.

---

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.claude-approval.plist
rm ~/Library/LaunchAgents/com.claude-approval.plist
rm ~/.claude/approval-server.js
rm ~/.claude/hooks/pre-tool-use.sh
```
