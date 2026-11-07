# Ping/pong smoke test

Proves the whole loop in about a minute: dispatch from a Cowork chat → headless CC on the machine →
PROGRESS sent by CC itself → DONE sent by the runner → both arrive in the chat with the right code.

`PING.txt` holds a token. CC reads it, sends one PROGRESS naming the token, writes `PONG.txt` with
the same token, and exits with a one-line summary.

## Run it (Windows, from a Cowork chat with the PowerShell tool)

1. Find the chat's session id: the `session_…` segment of its URL.
2. Dispatch:

```powershell
& "$env:APPDATA\codeboss\dispatch.ps1" `
    -ProjectDir 'E:\projects\CodeBoss2\tests\pingpong' `
    -SupervisorSession 'session_XXXXXXXXXXXXXXXXXXXXXXXXXX' `
    -MaxTurns 8 `
    -Prompt 'CodeBoss2 ping/pong test. Do these steps in order: (1) Read PING.txt in the current directory; call its content TOKEN. (2) Send exactly ONE PROGRESS update using the exact command format given in your system prompt, with the message text: read PING.txt, token is TOKEN (substitute the real token). Note whether the command printed ok true. (3) Create PONG.txt in the current directory containing exactly TOKEN. (4) Finish with a one-line final summary of the form: PONG TOKEN written; progress send result was <ok or the error>.'
```

3. Expect in the chat, within ~1 minute:

```
[<code>]: PROGRESS: read PING.txt, token is PING-7c1e
[<code>]: DONE: pingpong | 4 turns | cost=0.18 | 0.3min - PONG PING-7c1e written; progress send result was ok ({'ok':true}).
```

4. Verify on disk: `PONG.txt` matches `PING.txt`; `.codeboss/ops/runner-*.log` ends with
   `Delivered to session_… (attempt 1)`.

## Result 2026-11-06 (falcon77, Windows, claude 2.1.319)

Both messages delivered on attempt 1, ~3 s after send; CC run 4 turns / 0.3 min. The single quotes
in `{'ok':true}` are the runner's sanitizer swapping `"` for `'` before the native-arg send.
