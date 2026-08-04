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
- `jq`, `curl`, `bc` (`brew install jq bc` on macOS, `sudo apt install -y jq curl bc` on Debian/Ubuntu)

The `setup.sh` script runs a preflight check and tells you exactly which commands to run if anything is missing.

## Install

### Option 1: Let Claude Code install it

Just point a Claude Code session at the repo:

> Clone https://github.com/pete-builds/claude-code-statusline and run its setup.sh

Claude handles cloning, dependency checks, and the settings.json merge.

### Option 2: Setup script

```bash
git clone https://github.com/pete-builds/claude-code-statusline.git
cd claude-code-statusline
./setup.sh
```

**Windows/WSL note:** clone from inside WSL (not from Windows Git or git-bash) so the shell scripts get LF line endings. The repo pins `eol=lf` via `.gitattributes`, but some tools ignore attributes. If you see `bad interpreter: /bin/bash^M`, run `dos2unix statusline.sh setup.sh`.

### Option 3: Manual install

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

### Labeling gateway keys

If you run more than one key against the same gateway (e.g. a personal key and
a work key that both go through `litellm.example.com`), set
`ANTHROPIC_KEY_LABEL` before launching Claude Code and the label appears after
the gateway host on the ENV row: `GW:example·work`. Capped at 16 characters.

The usual pattern is a shell alias or wrapper that exports the label alongside
the base URL and key it belongs to.

**Bash / zsh (Linux, macOS, WSL, Git Bash):**

```bash
alias claude-work='ANTHROPIC_BASE_URL=https://litellm.example.com \
                   ANTHROPIC_AUTH_TOKEN=sk-... \
                   ANTHROPIC_KEY_LABEL=work claude'
alias claude-personal='ANTHROPIC_BASE_URL=https://litellm.example.com \
                       ANTHROPIC_AUTH_TOKEN=sk-... \
                       ANTHROPIC_KEY_LABEL=personal claude'
```

**PowerShell (Windows):** aliases can't set env vars inline, so use a function:

```powershell
function claude-work {
  $env:ANTHROPIC_BASE_URL   = "https://litellm.example.com"
  $env:ANTHROPIC_AUTH_TOKEN = "sk-..."
  $env:ANTHROPIC_KEY_LABEL  = "work"
  claude @args
}
```

**Windows cmd:** use a `.bat` wrapper that `set`s the three variables and then
calls `claude %*`.

Nothing is validated server-side; the label is a local display hint. If
`ANTHROPIC_KEY_LABEL` is unset, the ENV row shows `GW:host` on its own as
before.

### Notes for Cornell AI Gateway users

If your `ANTHROPIC_BASE_URL` points at `https://api.ai.it.cornell.edu/`, the
ENV row shows `GW:cornell` (the parser takes the second-to-last dotted
segment of the host).

The gateway rate table in `statusline.sh` is preloaded with Cornell's flat
$/1M-token pricing and only fires when `GW_HOST == "cornell"`, so no other
gateway is affected. When rates change, edit the `case "$MODEL"` block —
values were last verified against the Confluence pricing page (541787315,
v187) on 2026-07-20.

`ANTHROPIC_KEY_LABEL` is handy alongside the bridge-keychain flow when you
run more than one Cornell key (e.g. personal vs a shared project key)
against the same base URL — set it in whichever alias exports the key and
the bar shows `GW:cornell·<label>`.

### Adapting the rate table for your own gateway

Non-Cornell users can copy the pattern. Replace `"cornell"` in the guard
with the second-to-last hostname segment of your gateway (whatever appears
after `GW:` in the bar), then edit the `case "$MODEL"` block to match your
gateway's model IDs and rates.

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

## Privacy & trust

Worth knowing before you install.

**Third-party network calls.** Every status refresh sends cached requests (not every keystroke) to three providers:

- `api.ipify.org` returns your public IP
- `ipapi.co` geolocates your IP to city and lat/lon
- `api.open-meteo.com` returns current weather for those coordinates

None of these calls are authenticated. Nothing is sent to me or to any server I control. But those three providers can log your IP and approximate location. If that's not acceptable for your setup (corporate VPN, privacy-conscious workflow, etc.), either edit the script to remove the location and weather blocks or run it behind a filtering proxy.

**Supply chain.** The script runs with your shell's privileges every time Claude Code refreshes the statusline. If this repository or my GitHub account is compromised, anyone who pulls updates or re-runs `setup.sh` gets the attacker's code executed automatically. The repo has no commit signing enforcement. To freeze what you're running, pin to a specific commit SHA:

```bash
git checkout <commit-sha>
./setup.sh
```

**Local writes.** Setup installs to `~/.claude/statusline.sh` and merges a `statusLine` key into `~/.claude/settings.json`, preserving other keys. Runtime writes go to `~/.cache/claude/statusline/`: location, weather, and git caches, plus `context_window_debug.log`, a rotating log capped at 200 lines containing short session IDs, token counts, and model names. Nothing leaves your machine through this log.

**Non-risks.** Session JSON from Claude Code is shell-quoted via `jq @sh` before use, so there's no command injection path. API keys, when present, are only rendered as their last 4 characters. The script doesn't call any network endpoint beyond the three listed above.
