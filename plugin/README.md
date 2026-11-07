# CodeBoss2 plugin

Orchestrates Claude Code headless from Cowork. Cowork acts as the supervisor: it dispatches a task
to Claude Code running on your own machine, then goes idle. Claude Code reports PROGRESS, QUESTION,
DONE or ERROR straight back into the supervising Cowork chat using Anthropic's session ingress
(`claude -p "[code]: ..." --cloud <session-id>`, authenticated by your machine's claude.ai login).
No UI automation: nothing is typed into any window, and the chat can be on any device.

## Setup

1. Install Claude Code on the machine and log in: `claude auth login` (`claude auth status` must show
   `authMethod: claude.ai`).
2. Install the host scripts once:
   - Windows: `powershell -ExecutionPolicy Bypass -File skills\codeboss\scripts\windows\Install-CodeBoss.ps1`
     and have a Windows MCP connector with a PowerShell tool connected to Cowork.
   - macOS: `python3 skills/codeboss/scripts/macos/codeboss-host.py --install`, then restart Claude Desktop.
3. In a Cowork chat, say for example: "CodeBoss: add dark mode to the CSS in C:\projects\site".

See `CONNECTORS.md` for the host bridges and `skills/codeboss/references/` for the protocol,
boundaries, handoffs and troubleshooting. Source and tests: https://github.com/lrh-tourbillon/CodeBoss2
