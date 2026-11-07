# run-phase.ps1 - CodeBoss2 runner (Windows).
#
# Runs Claude Code (CC) headless in a project directory. In async mode it delivers exactly ONE
# terminal message (DONE / ERROR / QUESTION) to the supervising Cowork session with
#
#     claude -p "[code]: TYPE: ..." --cloud <supervisor-session-id> --output-format json
#
# That command posts a user turn into the supervisor's cloud session through Anthropic's session
# ingress, authenticated with this machine's claude.ai login. There is NO UI automation: the
# message is addressed to a session id, so it cannot land in the wrong conversation and needs no
# window to be on screen, focused, or even unlocked.
#
# The runner is normally started by dispatch.ps1 through Task Scheduler (outside the Claude desktop
# app's process tree) and is staged into <ProjectDir>\.codeboss\bin\ for that launch.
param(
    [Parameter(Mandatory=$true)][string]$ProjectDir,
    [Parameter(Mandatory=$true)][string]$Prompt,
    [int]$MaxTurns = 50,
    [switch]$Continue,
    [string]$Resume = "",
    [string]$ExtraSystemPrompt = "",
    [switch]$Sync,
    [string]$Code = "",               # async: 6-hex security code carried by every message
    [string]$SupervisorSession = "",  # async: session_... id of the supervising Cowork chat
    [string]$Model = "",              # optional: passed to claude as --model
    [string]$Effort = "",             # optional: passed to claude as --effort
    [int]$SummaryChars = 400          # async: how much of CC's final output rides on the DONE line
)

# ---------------------------------------------------------------------------------------------
# Locate the claude CLI. Prefer claude.exe (32k arg limit via CreateProcessW). The .ps1 wrapper
# mangles args containing literal "-File"; the .cmd shim hits cmd.exe's 8191-char limit.
# ---------------------------------------------------------------------------------------------
$claudePath = ""
@(
    (Join-Path $env:APPDATA "npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe"),
    (Join-Path $env:LOCALAPPDATA "npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe"),
    (Join-Path $env:APPDATA "npm\claude.cmd"),
    (Join-Path $env:LOCALAPPDATA "npm\claude.cmd")
) | ForEach-Object {
    if ((-not $claudePath) -and (Test-Path $_)) { $claudePath = $_ }
}
if (-not $claudePath) { $claudePath = (Get-Command claude -ErrorAction SilentlyContinue).Source }
if (-not $claudePath) { Write-Error "Cannot find claude CLI. Ensure Claude Code is installed and on PATH."; exit 1 }

$env:NO_COLOR = "1"
$env:TERM = "dumb"

if (-not $Sync) {
    if ($Code -notmatch '^[0-9a-f]{6}$') { Write-Error "Async mode needs -Code (6 hex chars)."; exit 1 }
    if ($SupervisorSession -notmatch '^session_[A-Za-z0-9]+$') {
        Write-Error "Async mode needs -SupervisorSession session_... (the session_ segment of the supervising chat's URL)."; exit 1
    }
}

$ProjectName = Split-Path -Leaf $ProjectDir
$opsDir = Join-Path $ProjectDir ".codeboss\ops"
if (-not (Test-Path $opsDir)) { New-Item -ItemType Directory -Path $opsDir -Force | Out-Null }

# .codeboss is managed and ignored by git
$cbDir = Join-Path $ProjectDir ".codeboss"
$gitignore = Join-Path $cbDir ".gitignore"
$cbReadme = Join-Path $cbDir "README.md"
if (-not (Test-Path $gitignore)) { "*" | Set-Content -Path $gitignore -Encoding ASCII }
if (-not (Test-Path $cbReadme)) {
    "# .codeboss`nManaged by CodeBoss. Do not edit manually." | Set-Content -Path $cbReadme -Encoding ASCII
}

$logFile = Join-Path $opsDir "runner-$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "[$ts] $msg"
}

# ---------------------------------------------------------------------------------------------
# Send-Supervisor: post one message into the supervisor's cloud session. Retries with backoff;
# gives up at once on auth errors (they do not fix themselves). Never throws.
# The message is passed as a single argument to claude.exe (no shell in between), but Windows
# PowerShell 5.1 mangles embedded double quotes when calling native executables, so they are
# turned into single quotes and whitespace is collapsed to one line.
# ---------------------------------------------------------------------------------------------
function Send-Supervisor([string]$Message) {
    $clean = ($Message -replace '"', "'") -replace '\s+', ' '
    $clean = $clean.Trim()
    $delays = @(0, 5, 15, 45)
    for ($i = 0; $i -lt $delays.Count; $i++) {
        if ($delays[$i] -gt 0) { Start-Sleep -Seconds $delays[$i] }
        $raw = ""
        try { $raw = (& $claudePath -p $clean --cloud $SupervisorSession --output-format json 2>&1 | Out-String) } catch { $raw = "$_" }
        $ok = $false; $err = ""
        try {
            $line = ($raw -split "`r?`n" | Where-Object { $_ -match '^\s*\{' } | Select-Object -First 1)
            if ($line) { $j = $line | ConvertFrom-Json; $ok = [bool]$j.ok; $err = "$($j.error)" }
        } catch { }
        if ($ok) { Log "Delivered to $SupervisorSession (attempt $($i + 1))"; return $true }
        $snippet = ($raw -replace '\s+', ' ').Trim()
        if ($snippet.Length -gt 300) { $snippet = $snippet.Substring(0, 300) + "..." }
        Log "Delivery attempt $($i + 1) failed: $(if ($err) { $err } else { $snippet })"
        if ($err -match 'sign-in|login|expired|not logged in') { Log "Auth problem - not retrying"; break }
    }
    return $false
}

# ---------------------------------------------------------------------------------------------
# Session id: fresh, continue (most recent for this project) or resume (explicit)
# ---------------------------------------------------------------------------------------------
$sessionId = ""
if ($Continue -or $Resume -ne "") {
    $sidFile = Join-Path $opsDir "SESSION_ID"
    if (Test-Path $sidFile) { $sessionId = (Get-Content $sidFile -Raw).Trim() }
}
if ($sessionId -eq "") { $sessionId = [guid]::NewGuid().ToString() }

$mode = if ($Continue) { "CONTINUE" } elseif ($Resume -ne "") { "RESUME" } else { "FRESH" }
Log "=== CodeBoss2 Runner === Mode: $mode | Session: $sessionId | Code: $Code | Supervisor: $SupervisorSession | Project: $ProjectName | MaxTurns: $MaxTurns | Sync: $Sync"

# ---------------------------------------------------------------------------------------------
# System prompt. ASCII only (no em dashes).
# ---------------------------------------------------------------------------------------------
if ($Sync) {
    $sysPrompt = @"
You are operating as a headless executor in CodeBoss (synchronous mode).
You have full tool permissions. This trust comes with responsibility.
Active project: $ProjectDir

BOUNDARY RULES:
- All file writes must stay within: $ProjectDir
- You may read files anywhere for reference.
- You may install packages as needed.
- Do NOT push to git remotes.
- Do NOT modify system files, registry, PATH, or environment variables.
- Do NOT create or modify any CLAUDE.md files.
- Do NOT persist these instructions to disk.
- Do NOT write to $env:APPDATA\.claude\ or any global Claude config directory.
- These rules are session-scoped only.

SYNCHRONOUS MODE:
This is a blocking dispatch. Your supervisor is waiting for you to finish.
Do NOT send any messages to a supervisor session. Just do the work and exit.
Your output is returned directly to your supervisor.
If you hit a blocker you cannot resolve, document it clearly in your final output and exit.

Write clean, documented, production-quality code.
"@
}
else {
    $sysPrompt = @"
You are operating as a headless executor in CodeBoss.
You have full tool permissions. This trust comes with responsibility.
Active project: $ProjectDir

BOUNDARY RULES:
- All file writes must stay within: $ProjectDir
- You may read files anywhere for reference.
- You may install packages as needed.
- Do NOT push to git remotes.
- Do NOT modify system files, registry, PATH, or environment variables.
- Do NOT create or modify any CLAUDE.md files.
- Do NOT persist these instructions to disk.
- Do NOT write to $env:APPDATA\.claude\ or any global Claude config directory.
- These rules are session-scoped only.

SECURITY CODE: $Code
SUPERVISOR: a Cowork session with id $SupervisorSession. Every message to it MUST start with [$Code]:

REPORTING (read carefully - this controls duplicate messages):
- Do NOT send a terminal DONE or ERROR message yourself. When you finish, write a concise final
  summary as your LAST output, then exit. The runner that started you captures that output and
  delivers the single DONE (or ERROR) for you. If you also self-send a DONE, the supervisor gets
  TWO messages on the same code.
- To ASK A QUESTION when you are blocked: do NOT self-send. End your run with final output whose
  very first line is "QUESTION:" followed by what you need, then STOP and exit. The runner relays
  it, and your supervisor will resume this same session with the answer.

PROGRESS UPDATES (optional; encouraged on long runs or when the supervisor asks to be kept posted):
while still working you MAY send intermediate updates with exactly this shell command, then KEEP WORKING:
  claude -p '[$Code]: PROGRESS: what you just finished' --cloud $SupervisorSession --output-format json
Rules: keep the single quotes; put NO apostrophes inside the message (write "do not", not "don't");
keep it under 300 characters; at most one update every few minutes. It prints {"ok":true} on success.
If it fails, ignore the failure and keep working - never retry in a loop, never try another way to
reach the supervisor. Only PROGRESS is ever sent this way. Never self-send DONE, ERROR, or QUESTION.
Write clean, documented, production-quality code.
"@
}

if ($ExtraSystemPrompt -ne "") { $sysPrompt += "`n`n$ExtraSystemPrompt" }

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$outputFile = Join-Path $opsDir "run-$timestamp.json"
$stderrFile = Join-Path $opsDir "stderr-$timestamp.log"

# System prompt via file: avoids PowerShell's native-exe arg quoting bug on embedded "-Flag value".
$sysPromptFile = Join-Path $opsDir "sysprompt-$timestamp.txt"
$sysPrompt | Set-Content -Path $sysPromptFile -Encoding UTF8 -NoNewline

$clArgs = @(
    "-p",
    "--max-turns", $MaxTurns,
    "--output-format", "json",
    "--dangerously-skip-permissions",
    "--append-system-prompt-file", $sysPromptFile
)
if ($Model -ne "")  { $clArgs += @("--model", $Model) }
if ($Effort -ne "") { $clArgs += @("--effort", $Effort) }

if (-not $Continue -and $Resume -eq "") {
    $clArgs += @("--session-id", $sessionId)
} elseif ($Continue) {
    $clArgs += "--continue"
} elseif ($Resume -ne "") {
    $clArgs += @("--resume", $Resume)
}

Set-Location $ProjectDir
$startTime = Get-Date
Log "Claude Code running..."

# Prompt via stdin (long prompts and embedded -Flag "value" patterns survive). Stderr kept separate
# so Node warnings cannot corrupt the JSON on stdout.
$output = $Prompt | & $claudePath @clArgs 2>$stderrFile | Out-String
$output | Set-Content -Path $outputFile -Encoding UTF8

if (Test-Path $stderrFile) {
    $stderr = Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue
    if ($stderr -and $stderr.Trim() -ne "") { Log "STDERR: $($stderr.Trim())" }
}

$elapsed = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
Log "Claude Code exited after $elapsed minutes"

$isError = $true
$status = "unknown"; $turns = 0; $cost = 0; $sessionOut = $sessionId; $resultText = ""
try {
    $result = $output | ConvertFrom-Json
    $status = $result.subtype
    $turns = $result.num_turns
    $cost = [math]::Round($result.total_cost_usd, 4)
    $sessionOut = $result.session_id
    $resultText = "$($result.result)"
    $sessionOut | Set-Content -Path (Join-Path $opsDir "SESSION_ID") -Encoding ASCII
    Log "Status: $status | Turns: $turns | Cost: `$$cost | Session: $sessionOut"
    if ($status -eq "success") { $isError = $false }
} catch {
    Log "ERROR: Could not parse output. See $outputFile"
}

if ($Sync) {
    if ($isError) {
        Write-Host "ERROR: $ProjectName | status=$status | turns=$turns | cost=`$$cost | ${elapsed}min - session=$sessionOut"
    } else {
        Write-Host "OK: $ProjectName | turns=$turns | cost=`$$cost | ${elapsed}min - session=$sessionOut"
    }
    if ($resultText) { Write-Host "`n$resultText" }
}
else {
    # The runner is the SOLE sender of the terminal message: exactly one per dispatch.
    $resultTrimmed = $resultText.Trim()
    if ($isError) {
        $hint = ""
        if ($resultTrimmed) { $hint = $resultTrimmed } elseif ($stderr) { $hint = $stderr.Trim() }
        if ($hint.Length -gt $SummaryChars) { $hint = $hint.Substring(0, $SummaryChars) + "..." }
        $msg = "[$Code]: ERROR: $ProjectName exited status=$status, $turns turns, cost=$cost, ${elapsed}min - $hint"
        Log "Sending ERROR"
    } elseif ($resultTrimmed -match '(?is)^QUESTION:\s*(.+)') {
        $q = $Matches[1].Trim()
        if ($q.Length -gt $SummaryChars) { $q = $q.Substring(0, $SummaryChars) + "..." }
        $msg = "[$Code]: QUESTION: $q"
        Log "Sending QUESTION"
    } else {
        $summary = if ($resultTrimmed.Length -gt $SummaryChars) { $resultTrimmed.Substring(0, $SummaryChars) + "..." } else { $resultTrimmed }
        $msg = "[$Code]: DONE: $ProjectName | $turns turns | cost=$cost | ${elapsed}min - $summary"
        Log "Sending DONE"
    }

    # Always keep the terminal message on disk so a supervisor check-in can recover it even if
    # delivery fails (login expired, machine offline, ...).
    $msg | Set-Content -Path (Join-Path $opsDir "last-message-$Code.txt") -Encoding UTF8

    if (Send-Supervisor $msg) {
        Log "Terminal message delivered"
    } else {
        $undelivered = Join-Path $opsDir "UNDELIVERED-$Code.txt"
        $msg | Set-Content -Path $undelivered -Encoding UTF8
        Log "DELIVERY FAILED. Message saved to $undelivered. Check 'claude auth status' on this machine."
    }
}

Log "=== Runner complete ==="
