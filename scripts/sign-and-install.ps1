param(
    [switch]$SkipBuild,
    [switch]$NoLaunch,
    [string]$Device = '127.0.0.1:15000'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'env.ps1')

$sdk = Join-Path $env:DEVECO_CLI_CLT_PATH 'sdk\default\openharmony'
$hdc = Join-Path $sdk 'toolchains\hdc.exe'
$lib = Join-Path $sdk 'toolchains\lib'
$unsigned = Join-Path $root 'entry\build\default\outputs\default\entry-default-unsigned.hap'
$signed = Join-Path $root 'signing\hmstart-signed.hap'
$chain = Join-Path $root 'signing\app-chain.cer'
$profile = Join-Path $root 'signing\hmstart-debug.p7b'
$keystore = Join-Path $lib 'OpenHarmony.p12'
$signTool = Join-Path $lib 'hap-sign-tool.jar'
$bundle = 'com.hmprojects.hmstart'
$ability = 'EntryAbility'

foreach ($f in @($chain, $profile, $keystore, $signTool)) {
    if (-not (Test-Path $f)) { throw "Missing signing input: $f" }
}

if (-not $SkipBuild) {
    Push-Location $root
    try {
        & devecocli build
        if ($LASTEXITCODE -ne 0) { throw "Build failed (exit $LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
}

if (-not (Test-Path $unsigned)) { throw "Unsigned HAP not found: $unsigned" }

$java = (Get-Command java -ErrorAction SilentlyContinue).Source
if (-not $java) { throw 'java not found on PATH; install a JDK/JRE to run hap-sign-tool.jar' }

Write-Host "Signing $unsigned ..."
& $java -jar $signTool sign-app `
    -mode localSign `
    -keyAlias 'openharmony application release' `
    -keyPwd 123456 `
    -appCertFile $chain `
    -profileFile $profile `
    -profileSigned 1 `
    -inFile $unsigned `
    -signAlg SHA256withECDSA `
    -keystoreFile $keystore `
    -keystorePwd 123456 `
    -outFile $signed `
    -compatibleVersion 26 `
    -signCode 1
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $signed)) { throw 'HAP signing failed' }

$targets = & $hdc list targets 2>&1
if ($targets -notmatch [regex]::Escape($Device)) {
    throw "Device $Device not found. Start the emulator and check OHOS_HDC_SERVER_PORT. Targets:`n$targets"
}

Write-Host "Installing $signed ..."
& $hdc -t $Device install -r $signed
if ($LASTEXITCODE -ne 0) { throw "Install failed (exit $LASTEXITCODE)" }

if (-not $NoLaunch) {
    Write-Host "Launching $bundle/$ability ..."
    & $hdc -t $Device shell aa start -a $ability -b $bundle
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Launch failed. If the screen is locked, unlock the emulator and retry.'
    } else {
        Start-Sleep -Seconds 2
        & $hdc -t $Device shell aa dump -l | Select-String -Pattern $bundle -Context 0,4
    }
}

Write-Host "Done: $signed"
