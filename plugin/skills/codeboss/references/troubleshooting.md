# Troubleshooting

Short, because the channel is simple: one authenticated CLI command. Almost every failure is one of
these.

## Nothing arrived after a dispatch

Check in this order (PowerShell on Windows, `codeboss_read_ops` on macOS):

1. `<ProjectDir>/.codeboss/ops/runner-*.log` (newest). It tells you whether CC ran, how it exited,
   and every delivery attempt with the error text.
2. `last-message-<code>.txt` — the terminal message is written here **before** delivery. Read it and
   handle it as if it had arrived.
3. `UNDELIVERED-<code>.txt` — present only if all retries failed. Cause is in the runner log.
4. Windows: `Get-ScheduledTask -TaskName 'CodeBoss-<project>-<code>'`. `Running` = CC still working.
   `Ready` with no runner log = the scheduled launch never ran; unregister it and re-dispatch with
   `-InProcess`.

## `{"ok":false,"error":"Cloud sessions need a claude.ai sign-in..."}` or `"Session expired"`

The machine's CLI login lapsed. User runs `claude auth login` in a terminal. `dispatch` refuses to
launch when it can see this coming (`Auth=` preflight) and warns 48 h ahead of expiry.

## `Session not found` from the send

Wrong `-SupervisorSession`. It must be the `session_…` segment of the **supervising chat's** URL.
After a context handoff the id changes; old runs keep reporting to the old chat.

## A PROGRESS arrived with a stale code

CC was resumed with `-Continue` and reused the code from an earlier run it still remembers. Ignore
the message, tell the user. The runner's terminal message always carries the current code.

## CC's PROGRESS send fails but DONE arrives

Harmless. CC is told to ignore a failed PROGRESS and keep working. Common cause: an apostrophe in
the message broke the single quotes. The runner's DONE is sent from a separate process with the
message passed as an argument, so it is immune.

## Double messages on one code

Should not happen in CodeBoss2: CC is told never to self-send DONE/ERROR/QUESTION. If it does
anyway, the second message on an expired code is ignored per the Step 4 table.

## Scheduled task runs but CC dies within minutes (Windows)

Check that the launcher really was Task Scheduler (`Launcher=TaskScheduler:` on the Dispatched
line). `InProcess` runs live under the Claude desktop app's process tree, which kills long-running
children.

## The MSIX `%APPDATA%` split (Windows)

The desktop app's tool shell sees a virtualized `%APPDATA%`; a scheduled task sees the physical one.
Symptoms: `Install-CodeBoss.ps1` says it installed but old files still show, or deletes "succeed"
without effect. CodeBoss2 sidesteps it by staging the runner into `<ProjectDir>\.codeboss\bin\` at
every dispatch, so the scheduled launch always runs the copy the tool shell installed.

## Sync dispatch times out

The PowerShell tool has a hard timeout. Keep sync tasks under ~60 s / MaxTurns ≤ 15, or go async.

## Encoding

System prompts are ASCII only (no em dashes). Prompts travel to CC on stdin as UTF-8. Messages to the
supervisor have `"` swapped for `'` and whitespace collapsed before sending (PowerShell 5.1 native-arg
quoting).
