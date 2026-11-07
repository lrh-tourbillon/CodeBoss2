# Build-Plugin.ps1 - package plugin/ as dist/codeboss.plugin (a zip with the plugin files at the
# archive root, which is what Cowork installs). Run from anywhere:
#   powershell -ExecutionPolicy Bypass -File E:\projects\CodeBoss2\Build-Plugin.ps1
# macOS/Linux equivalent:
#   (cd plugin && zip -r ../dist/codeboss.plugin . -x "*.DS_Store" -x "*__pycache__*")
$root = $PSScriptRoot
$manifest = Get-Content (Join-Path $root 'plugin\.claude-plugin\plugin.json') -Raw | ConvertFrom-Json
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$zip = Join-Path $dist "$($manifest.name).zip"
$out = Join-Path $dist "$($manifest.name).plugin"
Remove-Item $zip, $out -Force -ErrorAction SilentlyContinue
# Compress-Archive on the folder's *contents* keeps .claude-plugin/ at the archive root.
Compress-Archive -Path (Join-Path $root 'plugin\*') -DestinationPath $zip -CompressionLevel Optimal
Move-Item $zip $out -Force
Write-Host "Built $out (v$($manifest.version), $([math]::Round((Get-Item $out).Length / 1KB)) KB)"
