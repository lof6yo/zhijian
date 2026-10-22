param(
    [string]$Name = 'screen',
    [string]$Device = '127.0.0.1:15000'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'env.ps1')
Set-Location $root

$dir = Join-Path $root 'screenshots'
New-Item -ItemType Directory -Force $dir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$path = Join-Path $dir "$Name-$stamp.png"

try {
    & devecocli ui screenshot --device $Device --path $path
    if ($LASTEXITCODE -ne 0) { throw 'devecocli ui screenshot failed' }
} catch {
    $hdc = Join-Path $env:DEVECO_CLI_CLT_PATH 'sdk\default\openharmony\toolchains\hdc.exe'
    $remote = '/data/local/tmp/hmstart-shot.jpeg'
    & $hdc -t $Device shell snapshot_display -f $remote
    $path = [IO.Path]::ChangeExtension($path, '.jpeg')
    & $hdc -t $Device file recv $remote $path
}

if (Test-Path $path) {
    Write-Host "Screenshot: $path"
} else {
    throw 'Screenshot failed'
}
