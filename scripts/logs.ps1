param(
    [int]$Minutes = 5,
    [int]$Tail = 200,
    [switch]$Crash,
    [string]$Device = '127.0.0.1:15000'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')
Set-Location (Split-Path -Parent $PSScriptRoot)

if ($Crash) {
    & devecocli log --crash --bundle-name com.hmprojects.hmstart --device $Device
} else {
    & devecocli log --level E --from "${Minutes}m" --tail $Tail --device $Device
}
exit $LASTEXITCODE
