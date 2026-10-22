param(
    [switch]$Clean,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')
Set-Location (Split-Path -Parent $PSScriptRoot)

if ($Clean) {
    & devecocli build clean
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

& devecocli build @Args
exit $LASTEXITCODE
