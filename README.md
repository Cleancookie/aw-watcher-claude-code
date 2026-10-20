# aw-watcher-claude-code

Tracks Claude Code sessions in [ActivityWatch](https://activitywatch.net) running on the Windows host, from WSL.

```
Claude Code hooks ──► aw-heartbeat.sh ──curl.exe──► Windows localhost:5600
(SessionStart, UserPromptSubmit,          bucket: aw-watcher-claude-code_<windows-host>
 PostToolUse, Stop)                        type:   app.claude-code.activity
```

Event data: `project` (git repo name), `branch`, `ticket` (`AB#1234`, parsed from branch), `title` (Claude's session title), `model` (main conversation model), `effort` (latest main-thread request's `output_config.effort`), `session_id`, `cost_usd`.

`cost_usd` is an estimate at API list price from `prices.json`: transcript token usage (incl. subagents, deduped by message id) × rate. It is the cost incurred during that event, and subagent cost counts under the main model. Fast mode, batch and `inference_geo` multipliers are ignored.

## How it works

- `curl.exe` via WSL interop reaches AW on Windows' localhost; AW binds `127.0.0.1` so `$WINDOWS_IP` does not work.
- AW's `/heartbeat` endpoint only merges into a bucket's last event. Concurrent sessions would split each other into 0s events, so each session tracks its own event id in `~/.local/state/aw-watcher-claude-code/<session>.json` and extends it while heartbeats are under `AW_PULSETIME` (300s) apart.
- When the title or ticket first appears or changes, earlier events in the session are rewritten: title always, ticket only where it was null.
- Outside a git repo (e.g. `~/projects`) the session keeps its last project/branch/ticket.
- The script detaches immediately so hooks never block Claude.

## Install

1. Hooks in `~/.claude/settings.json` for `SessionStart`, `UserPromptSubmit`, `PostToolUse`, `Stop`:
   ```json
   { "type": "command", "command": "~/projects/aw-watcher-claude-code/aw-heartbeat.sh" }
   ```
2. Visualization — `%LOCALAPPDATA%\activitywatch\activitywatch\aw-server\aw-server.toml`:
   ```toml
   [server.custom_static]
   aw-watcher-claude-code = '\\wsl.localhost\<distro>\home\<user>\path\to\aw-watcher-claude-code\visualization'
   ```
   Restart aw-server (quit + relaunch aw-qt), then Activity → Edit view → add "Custom visualization" named `aw-watcher-claude-code`.

## Config

| Env | Default |
|---|---|
| `AW_CURL` | `curl.exe` |
| `AW_URL` | `http://localhost:5600/api/0` |
| `AW_PULSETIME` | `300` |
