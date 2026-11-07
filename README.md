# CodeBoss2

Orchestrates Claude Code (CC) headless from Cowork. Cowork is the supervisor; CC runs on your machine
and **reports back into the supervising chat through Anthropic's own session ingress**:

```
claude -p "[code]: DONE: ..." --cloud <supervisor-session-id>
```

That one command, run on your machine with your claude.ai login, posts a user turn into the Cowork
session that dispatched the work. No UI automation, no pasting into a composer, no window that has to
be open, focused or unlocked. The supervisor can be Cowork on the web, the desktop app, or your phone.

CodeBoss2 replaces CodeBoss v1's UI-automation "pipe" (Windows UI Automation / macOS Accessibility).
Everything else that worked in v1 stays: Task Scheduler launch on Windows, security codes, sync and
async dispatch, planning rounds, session continue/resume, handoffs.

## How it works

```
 Cowork chat (cloud session, id = session_…)
   │  PowerShell tool / codeboss-host connector
   ▼
 dispatch.ps1 / dispatch.sh  ── auth preflight, security code, Task Scheduler (Win) or nohup (mac)
   │
   ▼
 run-phase.ps1 / run-phase.sh ── runs:  claude -p --output-format json --dangerously-skip-permissions …
   │        │
   │        └─ CC may send:  claude -p '[code]: PROGRESS: …' --cloud session_…      (optional, live)
   │
   └─ after CC exits, the runner sends exactly one:
        claude -p '[code]: DONE | ERROR | QUESTION …' --cloud session_…
                                      │
                                      ▼
                     arrives in the Cowork chat as a user turn; the supervisor verifies [code] and acts
```

Verified end to end on 2026-11-06 (`tests/pingpong`): PROGRESS from inside headless CC and DONE from
the runner both delivered on the first attempt, ~3 s after send.

## Requirements

Both platforms:
- Cowork (any surface; Cowork chats are cloud sessions)
- Claude Code installed on the machine (`npm install -g @anthropic-ai/claude-code`) and **logged in to
  claude.ai** (`claude auth status` → `loggedIn: true, authMethod: claude.ai`). The login is the
  report-back channel; `dispatch` checks it and warns 48 h before it expires.

Windows: a Windows MCP connector with a PowerShell tool (see `plugin/CONNECTORS.md`).
macOS: the bundled `codeboss-host` connector (`codeboss-host.py --install`, once).

## Install

Windows:
```powershell
git clone https://github.com/lrh-tourbillon/CodeBoss2 E:\projects\CodeBoss2
powershell -ExecutionPolicy Bypass -File E:\projects\CodeBoss2\plugin\skills\codeboss\scripts\windows\Install-CodeBoss.ps1
```

macOS:
```bash
git clone https://github.com/lrh-tourbillon/CodeBoss2 ~/projects/CodeBoss2
python3 ~/projects/CodeBoss2/plugin/skills/codeboss/scripts/macos/codeboss-host.py --install
```

Then add the `plugin/` folder as a Cowork plugin (the skill is `codeboss`).

## Usage

In a Cowork chat: "CodeBoss: build a REST API in C:\projects\myapp". The supervisor finds its own
`session_…` id, dispatches, and goes idle; CC's PROGRESS / QUESTION / DONE arrive in the chat.

Try it first with the ping/pong test: `tests/pingpong/README.md`.

## Project layout

```
plugin/
  .claude-plugin/plugin.json
  CONNECTORS.md
  skills/codeboss/
    SKILL.md                          supervisor instructions
    references/                       calling-claude-code, boundary-rules, context-handoff, troubleshooting
    scripts/windows/                  dispatch.ps1, run-phase.ps1, Install-CodeBoss.ps1
    scripts/macos/                    dispatch.sh, run-phase.sh, codeboss-host.py
tests/pingpong/                       end-to-end smoke test
```

Each dispatched project gets a git-ignored `.codeboss/ops/` with runner logs, raw CC JSON, the last
terminal message per code, and `SESSION_ID`.

## Security model

- Every async dispatch mints a 6-hex code; every message from that run is `[code]: TYPE: …`.
- Messages arrive in the chat **as the user**, so the code is the only thing that distinguishes them
  from the user's own messages. The supervisor acts only on a live, matching code.
- CC runs with `--dangerously-skip-permissions` inside the project directory, bounded by its system
  prompt (`references/boundary-rules.md`).
- The report-back channel is your claude.ai login on your own machine. Nothing is stored in the cloud.

## Why not a cloud executor?

We tested every in-platform channel from an unattended cloud Claude Code session back to a Cowork
supervisor (scheduled-task "doorbells", the CLI from inside the container, native remote subagents).
None is both reliable and push-based today; see the CodeBoss2 project notes. The local design is
push both ways and already proven, so it ships first. A cloud mode (executor writes a Project doc,
supervisor polls with its own check-ins) is a possible later addition.

## License

MIT
