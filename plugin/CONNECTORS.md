# Connectors

CodeBoss2 needs exactly one thing from the host machine: a way for the Cowork supervisor to run the
`dispatch` script on it. Everything else (CC's report-back) goes through the machine's own `claude`
CLI and Anthropic's session ingress, with no connector involved.

Cowork's built-in `device_bash` is a Linux VM on the machine and cannot launch `claude` on the host,
so a host-shell bridge is required on both platforms.

## Windows: Windows MCP connector (`~~windows-os`)

Any Windows MCP connector that exposes a **PowerShell** tool. CodeBoss2 uses it for:

- running `dispatch.ps1` (sync and async) and `Install-CodeBoss.ps1`
- reading `.codeboss\ops\` logs and `last-message-*.txt` when something needs checking
- `Get-ScheduledTask` for `CodeBoss-*` runs

In SKILL.md, `~~windows-os` means whichever Windows MCP connector the user has installed.

## macOS: `codeboss-host` connector

Bundled: `skills/codeboss/scripts/macos/codeboss-host.py`, a small stdio MCP server (Python 3
standard library only) that Claude Desktop launches on the host. It exposes scoped tools, never a
general shell:

| Tool | Purpose |
|---|---|
| `codeboss_dispatch` | Run `dispatch.sh` (async with `supervisor_session`, or sync) |
| `codeboss_status` | Health check: scripts installed, `claude` found, claude.ai login state |
| `codeboss_read_ops` | Tail the latest runner log / show `last-message-*.txt` |

One-time setup (quit Claude Desktop first):

```bash
python3 /path/to/plugin/skills/codeboss/scripts/macos/codeboss-host.py --install
```

Then open Claude Desktop and run `codeboss_status` from Cowork; expect `claude auth: claude.ai`.
`--uninstall` reverses the config change; `--status` prints the health check.

No Accessibility permission is needed anymore: CodeBoss2 does not type into any window.

## What is no longer needed (v1)

- Windows UI Automation scripts (`Send-ClaudeMessage.ps1`, `Get-ClaudePanel.ps1`, `Inspect-ClaudeTree.ps1`)
- macOS `send-claude-message.sh` and the Accessibility permission for Claude Desktop
- Desktop mode (the in-UI Code tab)
- Any requirement that a Cowork chat be on screen with an empty composer
