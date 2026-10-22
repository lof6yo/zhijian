$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'env.ps1')
Set-Location $root

$script:failures = 0
$rows = New-Object System.Collections.Generic.List[object]

function Add-Check {
    param(
        [string]$Name,
        [bool]$Ok,
        [string]$Detail
    )
    $status = if ($Ok) { 'OK' } else { 'FAIL' }
    if (-not $Ok) { $script:failures++ }
    $rows.Add([pscustomobject]@{ Status = $status; Check = $Name; Detail = $Detail })
}

# Environment
Add-Check 'OHOS_HDC_SERVER_PORT' ($env:OHOS_HDC_SERVER_PORT -eq '18710') "value=$($env:OHOS_HDC_SERVER_PORT) (expected 18710; WSL owns 8710)"
Add-Check 'DEVECO_CLI_CLT_PATH' (Test-Path $env:DEVECO_CLI_CLT_PATH) $env:DEVECO_CLI_CLT_PATH
Add-Check 'DEVECO_SDK_HOME' (Test-Path $env:DEVECO_SDK_HOME) $env:DEVECO_SDK_HOME

# Commands
foreach ($cmd in @('node', 'npm', 'java', 'devecocli', 'harmonyos-mcp')) {
    $c = Get-Command $cmd -ErrorAction SilentlyContinue
    Add-Check "command:$cmd" ($null -ne $c) $(if ($c) { $c.Source } else { 'not found on PATH' })
}
$hdc = Join-Path $env:DEVECO_CLI_CLT_PATH 'sdk\default\openharmony\toolchains\hdc.exe'
$hvigorw = Join-Path $env:DEVECO_CLI_CLT_PATH 'bin\hvigorw.bat'
$emulator = Join-Path $env:DEVECO_CLI_CLT_PATH 'emulator\Emulator.exe'
foreach ($pair in @(@('hdc', $hdc), @('hvigorw', $hvigorw), @('Emulator', $emulator))) {
    Add-Check "tool:$($pair[0])" (Test-Path $pair[1]) $pair[1]
}

# Project files
foreach ($rel in @('build-profile.json5', 'oh-package.json5', 'AppScope\app.json5', 'entry\src\main\module.json5', 'entry\src\main\ets\pages\Index.ets')) {
    Add-Check "project:$rel" (Test-Path (Join-Path $root $rel)) $rel
}

# MCP config
$configPath = Join-Path $root '.opencode\opencode.json'
if (Test-Path $configPath) {
    try {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
        $servers = $cfg.mcp.servers
        $names = @()
        if ($servers) { $names = $servers.PSObject.Properties.Name }
        Add-Check 'mcp.config' ($names.Count -ge 3) ("servers=" + ($names -join ', '))
    } catch {
        Add-Check 'mcp.config' $false $_.Exception.Message
    }
} else {
    Add-Check 'mcp.config' $false 'missing .opencode\opencode.json'
}
foreach ($wrapper in @('scripts\mcp-deveco.cmd', 'scripts\mcp-harmonyos.cmd')) {
    Add-Check "mcp:$wrapper" (Test-Path (Join-Path $root $wrapper)) $wrapper
}

# Signing
foreach ($rel in @('signing\app-chain.cer', 'signing\hmstart-debug.p7b')) {
    Add-Check "signing:$rel" (Test-Path (Join-Path $root $rel)) $rel
}
$profileText = Get-Content (Join-Path $root 'build-profile.json5') -Raw
$hasSigning = $profileText -notmatch '"signingConfigs"\s*:\s*\[\s*\]'
Add-Check 'signing:build-profile' $true $(if ($hasSigning) { 'signingConfigs configured' } else { 'empty by design; scripts/run.ps1 uses local sign-and-install fallback' })

# Device
$targets = & $hdc list targets 2>&1
$hasDevice = $targets -match '127\.0\.0\.1:15000'
Add-Check 'device:hdc' $hasDevice $(if ($hasDevice) { '127.0.0.1:15000 connected' } else { 'no target; start emulator puraxview' })

# Build output
$unsigned = Join-Path $root 'entry\build\default\outputs\default\entry-default-unsigned.hap'
Add-Check 'build:artifact' (Test-Path $unsigned) $(if (Test-Path $unsigned) { $unsigned } else { 'run scripts\build.ps1' })

$rows | Format-Table -AutoSize -Wrap
Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "$($script:failures) check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed.' -ForegroundColor Green
exit 0
