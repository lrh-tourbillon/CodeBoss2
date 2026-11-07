# Calling Claude Code

How Claude Code (CC) is invoked, the dispatch parameters, output files and session management.

**Platform note:** commands below use Windows PowerShell (`dispatch.ps1`, `-Flag`). On macOS the
supervisor calls the `codeboss-host` connector's `codeboss_dispatch` tool, whose arguments map
one-to-one (`project_dir`, `prompt`, `supervisor_session`, `max_turns`, `continue_session`,
`resume`, `extra_system_prompt`, `model`, `effort`, `sync`), and which runs `dispatch.sh` with the
matching `--flags`. Output files, session modes and MaxTurns guidance are identical.

## The two commands that matter

```powershell
# Supervisor -> CC: launch a run (dispatch.ps1 -> run-phase.ps1 -> claude)
claude -p --max-turns N --output-format json --dangerously-skip-permissions `
       --append-system-prompt-file <sysprompt> --session-id <guid>      # prompt arrives on stdin

# CC -> Supervisor: post a message into the supervising Cowork session (run on the user's machine)
claude -p "[code]: TYPE: message" --cloud <supervisor-session-id> --output-format json
#   -> {"ok":true,"session_id":"session_...","url":"https://claude.ai/code/session_..."}
```

The second command is the whole report-back channel. It is run by the runner (for the single
terminal DONE / ERROR / QUESTION) and may be run by CC itself (for PROGRESS). It needs the machine's
`claude` to be logged in to claude.ai (`claude auth status` -> `loggedIn: true, authMethod: claude.ai`).
It fails cleanly with `{"ok":false,"error":"..."}` otherwise; the runner then keeps the message in
`.codeboss\ops\UNDELIVERED-<code>.txt`.

## dispatch.ps1 parameters

| Parameter | Required | Description |
|---|---|---|
| `-ProjectDir` | yes | Directory CC works in (must exist) |
| `-Prompt` | yes | The task |
| `-SupervisorSession` | async | `session_…` id of the supervising Cowork chat |
| `-MaxTurns` | no (50) | Max agentic turns |
| `-Continue` | no | Resume the project's most recent CC session |
| `-Resume <id>` | no | Resume a specific session |
| `-ExtraSystemPrompt` | no | Appended to the built-in system prompt |
| `-Model` | no | `claude --model` (e.g. `claude-fable-5-1`, `opus[1m]`) |
| `-Effort` | no | `claude --effort` (`low`, `medium`, `high`, `xhigh`) |
| `-Sync` | no | Block and return output; no code, no supervisor |
| `-InProcess` | no | Async: `Start-Process` under this shell instead of Task Scheduler |
| `-SkipAuthCheck` | no | Skip the `claude auth status` preflight |

### Dispatched line

```
Dispatched [NEW|CONTINUE|RESUME]: Project=<name>, MaxTurns=<n>, Code=<6hex>, Supervisor=session_… | Auth=ok(expires <utc>) | Launcher=TaskScheduler:CodeBoss-<name>-<code>
```

`Auth=` may carry `WARNING: login expires in N h`. `Launcher=` may carry a `NOTE`/`WARNING` when the
scheduled task was slow to start or never ran (see troubleshooting.md).

## Session modes

- **Fresh** (default): new session id, saved to `.codeboss\ops\SESSION_ID`.
- **Continue** (`-Continue`): resumes the id in `SESSION_ID`. An async continue issues a **new
  security code**, and the resumed CC is told the new code in its (re-appended) system prompt. A
  PROGRESS carrying the old code is stale: ignore it and tell the user.
- **Resume** (`-Resume <id>`): a specific session.

## CC output JSON (`run-*.json`)

| Field | Description |
|---|---|
| `subtype` | `success`, `error_max_turns`, `error_during_tool_use`, … |
| `is_error` | bool |
| `num_turns` | agentic turns used |
| `result` | CC's final output text (the DONE summary is its first `-SummaryChars`, default 400) |
| `session_id` | save for resuming |
| `total_cost_usd` | cost |

## Output files (`<ProjectDir>\.codeboss\ops\`)

| File | Contents |
|---|---|
| `runner-<ts>.log` | Runner activity: timing, status, every delivery attempt and its result |
| `run-<ts>.json` | Raw CC JSON output |
| `stderr-<ts>.log` | CC stderr (Node warnings; usually empty) |
| `sysprompt-<ts>.txt` | The system prompt CC was given |
| `SESSION_ID` | Most recent CC session id |
| `last-message-<code>.txt` | The terminal message, written before delivery is attempted |
| `UNDELIVERED-<code>.txt` | Present only if delivery failed after retries |
| `..\bin\run-phase.ps1` | Windows: runner staged for the Task Scheduler launch (overwritten per dispatch) |

## MaxTurns guidance

| Task | MaxTurns |
|---|---|
| Quick / sync | 5–15 |
| Feature | 30–50 |
| Large refactor | 50–100 |
| Full build | 100+ |

On `error_max_turns`, continue with `-Continue`.

## Windows launcher: Task Scheduler

An async dispatch registers and starts the task `CodeBoss-<project>-<code>` (current user,
interactive, limited rights, 3-day limit, hidden window) and waits up to 15 s for the runner's log to
appear. The process tree is `claude.exe <- powershell.exe <- svchost (Schedule)`, outside the Claude
desktop app's tree, whose supervision kills long-running children. Finished tasks are swept at the
next dispatch. If registration fails, the dispatch falls back to `-InProcess` and says so.

Because the desktop app is MSIX-packaged, its tool shell sees a virtualized `%APPDATA%`. The
scheduled launch therefore runs the runner from `<ProjectDir>\.codeboss\bin\run-phase.ps1` (staged by
dispatch from whatever copy the tool shell sees) and keeps temp files under `<ProjectDir>\.codeboss\ops\`.

## Finding the claude CLI

Windows (runner and dispatch): `%APPDATA%\npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe`,
then `%LOCALAPPDATA%` equivalent, then the `.cmd` shims, then PATH. `claude.exe` is preferred (32k
argument limit; the `.ps1` wrapper and `.cmd` shim both mangle long or `-Flag`-shaped arguments).

macOS (`run-phase.sh`): PATH after prepending `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`,
`~/.npm-global/bin`, `$(npm config get prefix)/bin` (GUI-launched processes get a minimal PATH).
