param(
    [switch]$SkipBuild,
    [switch]$Uninstall,
    [string]$Device = '127.0.0.1:15000'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'env.ps1')
Set-Location $root

$profileText = Get-Content (Join-Path $root 'build-profile.json5') -Raw
$hasSigningConfig = $profileText -notmatch '"signingConfigs"\s*:\s*\[\s*\]'

if ($hasSigningConfig) {
    $runArgs = @('--device', $Device)
    if ($Uninstall) { $runArgs += '--uninstall' }
    if ($SkipBuild) { $runArgs += '--skip-build' }
    & devecocli run @runArgs
    exit $LASTEXITCODE
}

Write-Host 'No signingConfigs configured; using local debug signing fallback.'
if ($Uninstall) {
    $hdc = Join-Path $env:DEVECO_CLI_CLT_PATH 'sdk\default\openharmony\toolchains\hdc.exe'
    & $hdc -t $Device uninstall com.hmprojects.hmstart
}
& (Join-Path $PSScriptRoot 'sign-and-install.ps1') -SkipBuild:$SkipBuild -Device $Device
exit $LASTEXITCODE
