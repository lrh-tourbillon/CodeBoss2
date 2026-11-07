# Install-CodeBoss.ps1 - deploys the CodeBoss2 Windows scripts to %APPDATA%\codeboss and removes
# the v1 UI-automation scripts if they are still there. Run from any PowerShell; idempotent.
#
#   powershell -ExecutionPolicy Bypass -File <plugin>\skills\codeboss\scripts\windows\Install-CodeBoss.ps1
#
# Then check: & "$env:APPDATA\codeboss\dispatch.ps1" -ProjectDir <dir> -Prompt "say hi" -Sync -MaxTurns 2
param(
    [string]$Source = $PSScriptRoot
)

$dest = Join-Path $env:APPDATA "codeboss"
New-Item -ItemType Directory -Path $dest -Force | Out-Null

foreach ($n in 'dispatch.ps1', 'run-phase.ps1') {
    $src = Join-Path $Source $n
    if (-not (Test-Path $src)) { Write-Error "Missing $src"; exit 1 }
    Copy-Item $src (Join-Path $dest $n) -Force
}

# v1 leftovers: the UI-automation pipe is gone in CodeBoss2.
foreach ($n in 'Send-ClaudeMessage.ps1', 'Get-ClaudePanel.ps1', 'Inspect-ClaudeTree.ps1') {
    Remove-Item (Join-Path $dest $n) -Force -ErrorAction SilentlyContinue
}

Write-Host "CodeBoss2 scripts installed to $dest"

# Report the state of the report-back channel: this machine's claude.ai login.
$claude = (Get-Command claude -ErrorAction SilentlyContinue).Source
if ($claude) {
    try {
        $auth = (& $claude auth status 2>$null | Out-String | ConvertFrom-Json)
        if ($auth.loggedIn -and $auth.authMethod -eq 'claude.ai') {
            Write-Host "claude CLI: logged in to claude.ai as $($auth.email) (expires $($auth.loginExpiresAt))"
        } else {
            Write-Warning "claude CLI is not logged in to claude.ai (loggedIn=$($auth.loggedIn), authMethod=$($auth.authMethod)). Run: claude auth login"
        }
    } catch { Write-Warning "Could not read 'claude auth status'." }
} else {
    Write-Warning "claude CLI not found on PATH. Install with: npm install -g @anthropic-ai/claude-code"
}
