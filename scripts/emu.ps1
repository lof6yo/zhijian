param(
    [ValidateSet('list', 'start', 'stop')]
    [string]$Action = 'list',
    [string]$Name = 'puraxview',
    [int]$Port = 15000
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')
Set-Location (Split-Path -Parent $PSScriptRoot)

switch ($Action) {
    'list' {
        & devecocli emulator list
    }
    'start' {
        & devecocli emulator start $Name --hdcport $Port
        $deadline = (Get-Date).AddSeconds(120)
        do {
            Start-Sleep -Seconds 3
            $devices = & devecocli device list --format json 2>$null
            if ($LASTEXITCODE -eq 0 -and $devices -match '127\.0\.0\.1') {
                Write-Host "Emulator ready: $Name"
                & devecocli device list
                exit 0
            }
        } while ((Get-Date) -lt $deadline)
        throw "Emulator $Name did not appear in hdc within 120s"
    }
    'stop' {
        & devecocli emulator stop $Name
    }
}
