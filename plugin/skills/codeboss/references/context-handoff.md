# Context Handoff Protocol

How to checkpoint a CodeBoss session and continue in a fresh Cowork chat when your context gets heavy.

## When

- Many tool calls / long transcript; you notice yourself forgetting earlier decisions.
- Before starting a new long run when you want a clean slate.

## Never hand off mid-run

If an async run is in flight (no DONE/ERROR yet), do not hand off: the new chat has no code to
verify the result and a **different session id**, so CC's message would go to this chat. Wait for the
run to finish, or tell the user the code that is live and that you must wait.

## Steps

1. **Write `<ProjectDir>/.codeboss/SESSION_HANDOFF.md`** (PowerShell `Set-Content` on Windows; on
   macOS, a short `-Sync` dispatch telling CC to write the file verbatim works on both platforms):

   ```markdown
   # CodeBoss Session Handoff
   Generated: <date>
   Previous supervisor session: session_...

   ## Project State
   What is built, what works, what does not.

   ## Active CC Session ID
   Content of .codeboss/ops/SESSION_ID, if the next task should -Continue it.

   ## Immediate Next Task
   Exactly what to do first.

   ## Key Decisions
   Architecture choices, constraints, preferences.

   ## Known Issues
   ```

2. **Tell the user**: "Context is getting heavy. I've written a handoff; please start a new Cowork
   chat and say: `CodeBoss: read <path> and continue`." Or create a one-shot scheduled task
   (`create_trigger` with `run_once_at` a minute out, `requires_local_device: true`) whose prompt is
   that sentence; it starts a fresh cloud session with the computer attached.

3. **In the new chat**: read the handoff, run the bootstrap check, note the **new** `session_…` id,
   summarize to the user, execute the next task. Any dispatch from here on uses the new id.

## Security code continuity

Codes are chat-scoped. After a handoff, previous codes are expired; in-flight runs from the old chat
(there should be none) report to the old chat.
