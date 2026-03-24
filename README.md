# Claude Code Statusline

A labeled-row status bar for the Claude Code TUI. Displays location, weather,
environment info, context window usage, git status, and session metrics.
Works on macOS and Linux.

```
─── | CC STATUSLINE | ────────────────────────────────────────────────────
LOC: Ithaca | 5:02p | Sun Mar 01 | ⛅  25°F · 10mph · 56%
ENV: CC: v2.1.63 | OAuth | anthropic.claude-4.6-sonnet
● CONTEXT: ●●●●●○○○○○○○○○○○○○○○○○○○ 23% used | In:3.4M  Out:21.0k
◆ GIT: ai-cli-workspace | Branch: main | ↑1 ↓0 | clean
+ SESSION: +30 -5 lines | 37m54s | #476c2e1 | 🔋 30% | ~$10.52 est
```

## Requirements

- macOS or Linux (including WSL)
- [Claude Code](https://claude.ai/download) v2.x+
- `jq` (`brew install jq` on macOS, `sudo apt install jq` on Debian/Ubuntu)
- `curl`

## Install

### Option 1: Setup script

Copy `statusline.sh` and `setup.sh` to a local folder, then:

```bash
chmod +x setup.sh
./setup.sh
```

### Option 2: Manual install

1. Copy `statusline.sh` to your Claude config directory:

```bash
cp statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

2. Add the statusline config to `~/.claude/settings.json`. If the file already
   exists, merge this into your existing settings:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```

Start a new Claude Code session — the statusline appears automatically.

## What each row shows

| Row | Contents |
|---|---|
| LOC | Auto-detected city, time, date, current weather |
| ENV | Claude Code version, auth method, active model |
| CONTEXT | Context window fill bar, % used, cumulative token counts |
| GIT | Project name, branch, ahead/behind remote, modified file count |
| SESSION | Lines added/removed, session duration, session ID, battery, cost |

### Auth display

| Label | Meaning |
|---|---|
| `OAuth` | Logged in via Anthropic account (Pro or Max subscription) |
| `API:..xxxx` | Direct Anthropic API key (last 4 chars) |
| `GW:hostname` | API gateway (last 4 chars of key, gateway hostname shown) |

### Context bar colors

The bar fills left to right as your context window fills up. Color indicates
how close you are to the context limit:

- Green → normal
- Yellow → approaching limit, start wrapping up your current task
- Red → near limit, time to manage context

**Context management options:**

- `/compact` — summarizes conversation history in place. Convenient but can lose context or misrepresent what was discussed. Use with caution on complex tasks.
- Safer pattern: ask Claude to write a summary of the current state to a markdown file, then run `/clear`, and open the new session by reading that file. You get a clean context with reliable continuity.

## Data sources

- **Location:** [ipapi.co](https://ipapi.co) — free, HTTPS, no API key, cached 1 hour
- **Weather:** [Open-Meteo](https://open-meteo.com) — free, no API key, cached 10 minutes
- Both services must be reachable. If blocked by a Pi-hole or firewall, whitelist
  `ipapi.co` and `api.open-meteo.com`
