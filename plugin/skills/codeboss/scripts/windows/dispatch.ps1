# dispatch.ps1 - CodeBoss2 entry point (Windows). Launches Claude Code via run-phase.ps1.
#
# ASYNC (default): the runner is started through Task Scheduler so Claude Code and everything it
# spawns live under the Schedule service - OUTSIDE the Claude desktop app's process tree, whose
# supervision silently kills long-running children (full-solution test runs died 20 s - 4 min in
# under the app's tree; completed under Task Scheduler). When the run ends, the runner reports to the
# supervising Cowork session with `claude -p "[code]: ..." --cloud <SupervisorSession>`. No UI
# automation anywhere. -InProcess restores a plain Start-Process launch under this shell.
#
# SYNC (-Sync): blocks until CC exits and returns its output here. No code, no supervisor needed.
# The Windows MCP PowerShell tool has a hard timeout, so keep sync tasks short.
#
# MSIX note: a process started from the desktop app's tool shell sees a VIRTUALIZED %APPDATA%
# (overlay under %LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\), while a Task Scheduler
# process sees the PHYSICAL one. So the scheduled launch stages the runner THIS shell can see into
# <ProjectDir>\.codeboss\bin\ and runs it from there, and temp files go under <ProjectDir>\.codeboss\ops\.
param(
    [Parameter(Mandatory=$true)][string]$ProjectDir,
    [Parameter(Mandatory=$true)][string]$Prompt,
    [string]$SupervisorSession = "",  # async: session_... of the supervising Cowork chat (the session_ segment of its URL)
    [int]$MaxTurns = 50,
    [switch]$Continue,
    [string]$Resume = "",
    [string]$ExtraSystemPrompt = "",
    [string]$Model = "",              # optional: claude --model (e.g. claude-fable-5-1, opus[1m])
    [string]$Effort = "",             # optional: claude --effort (low|medium|high|xhigh)
    [switch]$Sync,
    [switch]$InProcess,               # async only: Start-Process under THIS shell instead of Task Scheduler
    [switch]$SkipAuthCheck            # skip the `claude auth status` preflight
)

$scriptsDir = Join-Path $env:APPDATA "codeboss"
$runner = Join-Path $scriptsDir "run-phase.ps1"
if (-not (Test-Path $runner)) {
    Write-Error "CodeBoss2 scripts not found at $scriptsDir. Run Install-CodeBoss.ps1 from the plugin's scripts\windows folder."
    exit 1
}
if (-not (Test-Path $ProjectDir -PathType Container)) {
    Write-Error "ProjectDir does not exist: $ProjectDir"
    exit 1
}

$ProjectName = Split-Path -Leaf $ProjectDir

# ---------------------------------------------------------------------------------------------
# Auth preflight: the report-back channel is this machine's claude.ai login. Fail loudly here,
# in the supervisor's tool output, rather than hours later when the DONE cannot be delivered.
# ---------------------------------------------------------------------------------------------
$authNote = "Auth=skipped"
if (-not $SkipAuthCheck) {
    $claudeCmd = ""
    @(
        (Join-Path $env:APPDATA "npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe"),
        (Join-Path $env:LOCALAPPDATA "npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe"),
        (Join-Path $env:APPDATA "npm\claude.cmd"),
        (Join-Path $env:LOCALAPPDATA "npm\claude.cmd")
    ) | ForEach-Object { if ((-not $claudeCmd) -and (Test-Path $_)) { $claudeCmd = $_ } }
    if (-not $claudeCmd) { $claudeCmd = (Get-Command claude -ErrorAction SilentlyContinue).Source }
    if (-not $claudeCmd) { Write-Error "Cannot find the claude CLI on this machine."; exit 1 }
    try {
        $authRaw = (& $claudeCmd auth status 2>$null | Out-String)
        $auth = ($authRaw | ConvertFrom-Json)
    } catch { $auth = $null }
    if (-not $auth -or -not $auth.loggedIn) {
        Write-Error "The claude CLI on this machine is not logged in to claude.ai, so Claude Code could not report back. Open a terminal and run: claude auth login"
        exit 2
    }
    if ($auth.authMethod -ne "claude.ai") {
        Write-Error "The claude CLI is logged in with authMethod '$($auth.authMethod)'. Session messaging needs a claude.ai login (claude auth login)."
        exit 2
    }
    $expires = ""
    if ($auth.loginExpiresAt) {
        try {
            $exp = [datetime]::Parse($auth.loginExpiresAt).ToUniversalTime()
            $left = $exp - (Get-Date).ToUniversalTime()
            $expires = $exp.ToString("yyyy-MM-ddTHH:mmZ")
            if ($left.TotalHours -lt 48) { $expires += " WARNING: login expires in $([math]::Round($left.TotalHours,1)) h - run 'claude auth login' soon" }
        } catch { }
    }
    $authNote = "Auth=ok" + $(if ($expires) { "(expires $expires)" } else { "" })
}

if ($Sync) {
    # --- Synchronous: block until CC finishes, return output directly. No code, no supervisor. ---
    $runArgs = @{
        ProjectDir = $ProjectDir
        Prompt     = $Prompt
        MaxTurns   = $MaxTurns
        Sync       = $true
    }
    if ($Continue)                 { $runArgs.Continue = $true }
    if ($Resume -ne "")            { $runArgs.Resume = $Resume }
    if ($ExtraSystemPrompt -ne "") { $runArgs.ExtraSystemPrompt = $ExtraSystemPrompt }
    if ($Model -ne "")             { $runArgs.Model = $Model }
    if ($Effort -ne "")            { $runArgs.Effort = $Effort }
    & $runner @runArgs
    exit $LASTEXITCODE
}

# --- Async ---
if ($SupervisorSession -notmatch '^session_[A-Za-z0-9]+$') {
    Write-Error "Async dispatch needs -SupervisorSession session_... : the session_ segment of the supervising chat's URL (claude.ai/code/session_...)."
    exit 1
}

# 6-char hex security code: every message from this run carries it.
$Code = -join ((1..6) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })

# Project-local, unvirtualized working folders (see header).
$opsDir = Join-Path $ProjectDir ".codeboss\ops"
$binDir = Join-Path $ProjectDir ".codeboss\bin"
foreach ($d in @($opsDir, $binDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

$useScheduler = -not $InProcess
$runnerToUse  = $runner
$note = ""
if ($useScheduler) {
    try {
        Copy-Item $runner (Join-Path $binDir "run-phase.ps1") -Force
        $runnerToUse = Join-Path $binDir "run-phase.ps1"
    } catch {
        $note = " | WARNING: could not stage the runner into $binDir ($($_.Exception.Message)); launched in-process"
        $useScheduler = $false
        $runnerToUse  = $runner
    }
}

$ts = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$promptFile = Join-Path $opsDir ".prompt-temp-$ts.txt"
$Prompt | Set-Content -Path $promptFile -Encoding UTF8

$cmdParts = @(
    "`$p = Get-Content -Path '$promptFile' -Raw;"
    "& '$runnerToUse'"
    "-ProjectDir '$ProjectDir'"
    "-Prompt `$p"
    "-MaxTurns $MaxTurns"
    "-Code '$Code'"
    "-SupervisorSession '$SupervisorSession'"
)
if ($Continue)      { $cmdParts += "-Continue" }
if ($Resume -ne "") { $cmdParts += "-Resume '$Resume'" }
if ($Model -ne "")  { $cmdParts += "-Model '$Model'" }
if ($Effort -ne "") { $cmdParts += "-Effort '$Effort'" }
if ($ExtraSystemPrompt -ne "") {
    $sysFile = Join-Path $opsDir ".sysprompt-temp-$ts.txt"
    $ExtraSystemPrompt | Set-Content -Path $sysFile -Encoding UTF8
    $cmdParts += "-ExtraSystemPrompt (Get-Content -Path '$sysFile' -Raw)"
}
$cmdParts += "; Remove-Item -Path '$promptFile' -ErrorAction SilentlyContinue"
$argString = "-NoProfile -ExecutionPolicy Bypass -Command `"& { $($cmdParts -join ' ') }`""

$t0 = Get-Date
$launcher = ""
if ($useScheduler) {
    try {
        # Sweep finished CodeBoss-* tasks from earlier dispatches (State Ready = not running).
        Get-ScheduledTask -TaskName 'CodeBoss-*' -ErrorAction SilentlyContinue |
            Where-Object { $_.State -eq 'Ready' } |
            ForEach-Object { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue }

        $taskName  = "CodeBoss-$ProjectName-$Code"
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-WindowStyle Hidden $argString" -WorkingDirectory $ProjectDir
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
        $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Days 3) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        $launcher = "TaskScheduler:$taskName"
    } catch {
        $note = " | WARNING: Task Scheduler launch failed ($($_.Exception.Message)); launched in-process"
        $useScheduler = $false
    }
}
if (-not $useScheduler) {
    Start-Process powershell -WindowStyle Hidden -ArgumentList $argString
    $launcher = "InProcess"
}
else {
    # Confirm the runner started: its runner-*.log appears in <ProjectDir>\.codeboss\ops within seconds.
    $started = $false
    for ($i = 0; $i -lt 30 -and -not $started; $i++) {
        Start-Sleep -Milliseconds 500
        $started = [bool](Get-ChildItem $opsDir -Filter 'runner-*.log' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $t0 })
    }
    if (-not $started) {
        $tState = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
        $tInfo  = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
        $tResult = if ($tInfo) { '0x{0:X}' -f [uint32]$tInfo.LastTaskResult } else { '?' }
        if ($tState -eq 'Running') {
            $note = " | NOTE: task is Running but no runner log yet after 15 s (slow start) - check $opsDir\runner-*.log in a minute; do NOT unregister or re-dispatch"
        } else {
            $note = " | WARNING: task $launcher is '$tState' (LastTaskResult=$tResult) and no runner log appeared within 15 s - the scheduled launch did not run; Unregister-ScheduledTask it and re-dispatch with -InProcess"
        }
    }
}

$mode = if ($Continue) { "CONTINUE" } elseif ($Resume -ne "") { "RESUME" } else { "NEW" }
$modelNote = if ($Model -ne "" -or $Effort -ne "") { " | Model=$Model Effort=$Effort" } else { "" }
Write-Host "Dispatched [$mode]: Project=$ProjectName, MaxTurns=$MaxTurns, Code=$Code, Supervisor=$SupervisorSession | $authNote | Launcher=$launcher$modelNote$note"
