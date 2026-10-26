param(
    [switch]$Clean,
    [switch]$Release,
    [switch]$Sign,
    [switch]$Timestamp,
    [switch]$Purge,
    [string]$Product = 'default',
    # Abort when the build log has not grown for this many seconds.
    #
    # Measured on this machine: a healthy `hvigorw --no-daemon` prints its first
    # line at ~16 s (JVM + task-graph setup) and then a line every 1–2 s; the
    # whole incremental build is 12–19 s. So 45 s of total silence is already
    # three times the worst healthy gap — there is nothing to wait for beyond
    # that, and the earlier 120 s default meant one silent hang cost two minutes
    # before the retry even started.
    [int]$StallSec = 45,
    # Absolute ceiling, for a genuinely slow first build on a cold cache.
    [int]$TimeoutSec = 900
)

# Build the entry HAP and publish it into `dist/`.
#
# Usage:
#   scripts\dist.ps1                # debug build -> dist\zhijian-1.0.0-unsigned.hap
#   scripts\dist.ps1 -Release       # release build -> dist\zhijian-1.0.0-release-unsigned.hap
#   scripts\dist.ps1 -Clean         # clean first (slow, use when the build looks stale)
#   scripts\dist.ps1 -Sign          # also emit a locally debug-signed copy (emulator only)
#   scripts\dist.ps1 -Timestamp     # additionally keep a dated copy
#   scripts\dist.ps1 -Purge         # delete previously published HAPs first
#   scripts\dist.ps1 -StallSec 90   # how long "no output" may last (default 45)
#
# The published name comes from `AppScope/app.json5`, not from hvigor: the
# build's own output is `entry-default-unsigned.hap` in both debug and release,
# which says nothing about what it is or which version it holds.
#
# Two failure modes this script exists to catch:
# - `devecocli build` can finish entirely UP-TO-DATE, leaving the previous HAP
#   on disk at an older mtime. Publishing that silently ships the old app.
# - hvigor can exit 0 while packaging failed, or leave a truncated file.
# So the artifact is picked as the newest `*-unsigned.hap`, its mtime is checked
# against the newest source file under `entry/src` / `AppScope`, and it is opened
# as a zip to prove `module.json` is there before anything is copied into `dist/`.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'env.ps1')
Set-Location $root

$mode = if ($Release) { 'release' } else { 'debug' }
$module = 'entry'
$outputDir = Join-Path $root "$module\build\$Product\outputs\$Product"
$distDir = Join-Path $root 'dist'

# ---- identity: name the published file after the app, not after hvigor -------
# `entry-default-debug-unsigned.hap` says nothing about what it is or which
# version it holds. Read both from AppScope/app.json5 so the name follows a
# version bump without editing this script.
$appJson = Get-Content (Join-Path $root 'AppScope\app.json5') -Raw
$versionMatch = [regex]::Match($appJson, '"versionName"\s*:\s*"([^"]+)"')
$version = if ($versionMatch.Success) { $versionMatch.Groups[1].Value } else { '0.0.0' }
$suffix = if ($Release) { "$mode-unsigned" } else { 'unsigned' }
$publishedName = "zhijian-$version-$suffix.hap"

function Fail([string]$message) {
    Write-Host ''
    Write-Host "FAILED: $message" -ForegroundColor Red
    exit 1
}

# ---- build ------------------------------------------------------------------
# The direct `hvigorw --no-daemon` call is the **primary** path, not a fallback.
# `devecocli build` goes through the hvigor daemon, and twice on this machine a
# daemon left over from an earlier session kept holding the build directory: the
# build printed a dozen task lines and then sat at 2 % CPU indefinitely, which
# reads as "compiling 2 MB takes ten minutes". It does not — a full release
# build here is ~80 s and an incremental one ~20 s, and `--no-daemon` gets there
# on its own by starting a fresh process every run.
#
# Two independent limits guard it:
#   $StallSec   — no new output for this long. This is the one that matters:
#                 a healthy build prints a task line every second or two, so a
#                 two-minute silence is a deadlock, not slow work. Catching it
#                 here turns a ten-minute hang into a two-minute retry.
#   $TimeoutSec — absolute ceiling, for a genuinely cold first build.
# On a trip the hvigor `node` processes are killed and the other build route is
# tried once. In practice the retry only runs when `--no-daemon` itself failed
# (an ohpm sync that never happened, a corrupted hvigor cache) — that is where
# the CLI earns its keep, because it repairs both.
$buildLog = Join-Path $env:TEMP 'zhijian-dist-build.log'
$buildErr = "$buildLog.err"

function KillHvigorTree {
    # Only processes whose command line mentions hvigor or the DevEco CLI —
    # killing every node.exe would take out the MCP servers and the editor.
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            ($_.CommandLine -match 'hvigor' -or $_.CommandLine -match 'deveco-cli')
        } |
        ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { }
        }
}

function Show-Tail([string]$path, [int]$lines) {
    if ((Test-Path $path) -and (Get-Item $path).Length -gt 0) {
        Get-Content $path -Tail $lines | ForEach-Object { Write-Host "    $_" }
    }
}

# Returns 'ok' / 'stalled' / 'timeout' / 'failed'.
function Invoke-Timed([string]$label, [string]$command) {
    Remove-Item $buildLog, $buildErr -Force -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList '-NoProfile', '-Command', $command `
        -WorkingDirectory $root -PassThru -NoNewWindow `
        -RedirectStandardOutput $buildLog -RedirectStandardError $buildErr
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lastSize = 0
    $lastGrowth = [TimeSpan]::Zero
    $state = 'ok'
    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 400
        if (Test-Path $buildLog) {
            $size = (Get-Item $buildLog).Length
            if ($size -ne $lastSize) {
                $lastSize = $size
                $lastGrowth = $sw.Elapsed
            }
        }
        if (($sw.Elapsed - $lastGrowth).TotalSeconds -ge $StallSec) { $state = 'stalled'; break }
        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) { $state = 'timeout'; break }
    }
    if ($state -ne 'ok') {
        # `Process.Kill(bool)` only exists on .NET Core 3+; the child here is
        # Windows PowerShell 5.1, so the parameterless overload is the one that
        # works there. Either way `KillHvigorTree` below removes the actual
        # build processes, which is what matters for a deadlock.
        try { $proc.Kill() } catch { }
        KillHvigorTree
        $why = if ($state -eq 'stalled') { "no output for ${StallSec}s" } else { "exceeded ${TimeoutSec}s" }
        Write-Host "  $label $why; killed hvigor" -ForegroundColor Yellow
        # Show how far it got. A stall before the first task line (hvigor prints
        # its first line at ~16 s) is a different fault from a stall in the
        # middle of CompileArkTS, and only the log can tell them apart.
        if (Test-Path $buildLog) {
            $lineCount = @(Get-Content $buildLog).Count
            Write-Host "    ($lineCount line(s) of output before the stall)" -ForegroundColor DarkGray
        }
        return $state
    }
    $out = if (Test-Path $buildLog) { Get-Content $buildLog -Raw } else { '' }
    if ($proc.ExitCode -ne 0) {
        Write-Host "  $label exited $($proc.ExitCode)" -ForegroundColor Yellow
        Show-Tail $buildLog 40
        Show-Tail $buildErr 20
        return 'failed'
    }
    if ($out -notmatch 'BUILD SUCCESSFUL') {
        Show-Tail $buildLog 40
        return 'failed'
    }
    # Keep the console readable: one line per phase instead of ~150 task lines.
    $out -split "`r?`n" |
        Where-Object { $_ -match 'BUILD SUCCESSFUL|WARN: .*ArkTS:ERROR|Finished :entry:default@(CompileArkTS|PackageHap)' } |
        ForEach-Object { Write-Host "  $($_.Trim())" }
    return 'ok'
}

$startedAt = Get-Date
Write-Host "Building $module ($mode, product=$Product) ..." -ForegroundColor Cyan
if ($Clean) {
    Write-Host '  clean ...'
    Remove-Item (Join-Path $root "$module\build") -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $root 'build') -Recurse -Force -ErrorAction SilentlyContinue
}

# Reap daemons left behind by earlier `devecocli build` / `devecocli run` calls
# *before* starting. They are the ones that deadlock: a daemon started hours ago
# keeps the build directory locked, and the next build blocks on it forever.
# Cheap and safe — they are only a cache, and `--no-daemon` will not reuse them.
$stale = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'hvigor' })
if ($stale.Count -gt 0) {
    Write-Host "  reaping $($stale.Count) hvigor daemon(s) from earlier runs" -ForegroundColor DarkGray
    KillHvigorTree
    Start-Sleep -Milliseconds 800
}

# `hvigorw --no-daemon` is the primary path, not the fallback: the daemon is
# what hangs, and this route starts a fresh process every time. It is also
# faster than it sounds — 80 s cold, 12–19 s incremental.
$hvigor = Join-Path $env:DEVECO_CLI_CLT_PATH 'bin\hvigorw.bat'
$cli = "`$env:PATH = '$($env:PATH -replace "'", "''")'; " +
    "`$env:DEVECO_CLI_CLT_PATH = '$env:DEVECO_CLI_CLT_PATH'; " +
    "`$env:DEVECO_SDK_HOME = '$env:DEVECO_SDK_HOME'; " +
    "`$env:OHOS_HDC_SERVER_PORT = '$env:OHOS_HDC_SERVER_PORT'; "
$hvigorCmd = $cli + "& '$hvigor' --mode module -p module=$module@$Product " +
    "-p product=$Product -p buildMode=$mode assembleHap --no-daemon"

# The `--no-daemon` route is retried **once** before falling back to the CLI.
# The stall that prompted this is intermittent, and the same command that went
# silent for two minutes ran in 17 s immediately afterwards on an unchanged
# tree. A retry therefore costs at most one `$StallSec` and usually recovers the
# whole build; `devecocli build` is ~6× slower (114 s vs 17 s measured), so it
# must not be the first response to a one-off silence.
$result = Invoke-Timed 'hvigorw' $hvigorCmd
if ($result -ne 'ok') {
    Write-Host '  retrying hvigorw --no-daemon once ...' -ForegroundColor Yellow
    $result = Invoke-Timed 'hvigorw' $hvigorCmd
}

if ($result -ne 'ok') {
    # Only reached when `--no-daemon` failed twice: an ohpm sync that never ran,
    # a corrupted hvigor cache. The CLI is the slower route but it repairs both.
    Write-Host '  retrying through devecocli build ...' -ForegroundColor Yellow
    $result = Invoke-Timed 'devecocli build' (
        $cli + "devecocli build --product $Product --build-mode $mode")
}
if ($result -ne 'ok') { Fail "Build failed (see $buildLog)" }

# ---- verify the artifact is the one this build wrote ------------------------
# hvigor's file name does **not** encode the build mode: both debug and release
# land in `entry-default-unsigned.hap`. Deriving the name from `$mode` therefore
# pointed at a file that never exists. Take the newest `*-unsigned.hap` instead.
$candidates = @()
if (Test-Path $outputDir) {
    $candidates = @(Get-ChildItem $outputDir -Filter '*-unsigned.hap' -File |
        Sort-Object LastWriteTime -Descending)
}
if ($candidates.Count -eq 0) {
    Fail "Build reported success but produced no *-unsigned.hap in $outputDir"
}
$artifact = $candidates[0].FullName
$item = $candidates[0]

# Staleness is measured against **the newest source file**, not against this
# run's start time. Comparing with the start time looks equivalent but is wrong:
# a second run with nothing edited is entirely UP-TO-DATE, hvigor writes no new
# HAP, and the existing one is legitimately current — failing there would make
# the script unusable for the most common case (publish what I just verified).
# What must fail is the opposite: sources changed, build did nothing, and the
# old HAP would ship.
$sourceRoots = @(
    (Join-Path $root 'entry\src'),
    (Join-Path $root 'AppScope')
)
$newestSource = [DateTime]::MinValue
foreach ($dir in $sourceRoots) {
    if (-not (Test-Path $dir)) { continue }
    $latest = Get-ChildItem $dir -Recurse -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($latest -and $latest.LastWriteTime -gt $newestSource) {
        $newestSource = $latest.LastWriteTime
    }
}
foreach ($file in @('build-profile.json5', 'oh-package.json5')) {
    $path = Join-Path $root $file
    if (-not (Test-Path $path)) { continue }
    $t = (Get-Item $path).LastWriteTime
    if ($t -gt $newestSource) { $newestSource = $t }
}
# One second of slack for filesystem timestamp granularity.
if ($item.LastWriteTime -lt $newestSource.AddSeconds(-1)) {
    $stale = "Artifact {0:HH:mm:ss} is older than the newest source {1:HH:mm:ss}" -f `
        $item.LastWriteTime, $newestSource
    Fail "$stale. hvigor reported success without repackaging; rerun with -Clean."
}
if ($item.Length -lt 100KB) {
    Fail "Artifact is only $([Math]::Round($item.Length / 1KB)) KB; that is not a packaged HAP."
}
# A HAP is a zip. Checking for module.json catches a truncated/corrupt package
# that still has a plausible size and mtime.
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($artifact)
    try {
        $hasManifest = ($zip.Entries | Where-Object { $_.FullName -eq 'module.json' }).Count -gt 0
    } finally {
        $zip.Dispose()
    }
} catch {
    Fail "Artifact is not a readable archive: $($_.Exception.Message)"
}
if (-not $hasManifest) { Fail 'Artifact has no module.json; the package is incomplete.' }

# ---- publish ----------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $distDir | Out-Null
if ($Purge) {
    Get-ChildItem $distDir -Filter 'zhijian-*.hap' -File | ForEach-Object {
        Remove-Item $_.FullName -Force
        Write-Host "  removed old $($_.Name)"
    }
}

$published = Join-Path $distDir $publishedName
Copy-Item $artifact $published -Force
Write-Host "Published $publishedName" -ForegroundColor Green

if ($Timestamp) {
    $stamp = $startedAt.ToString('yyyyMMdd-HHmm')
    $datedName = "zhijian-$version-$suffix-$stamp.hap"
    Copy-Item $artifact (Join-Path $distDir $datedName) -Force
    Write-Host "Dated copy  $datedName"
}

# ---- optional local debug signing ------------------------------------------
# Only the OpenHarmony local debug chain from `signing/`, so the result installs
# on the emulator and nowhere else. Never hand this file to a user as a release.
if ($Sign) {
    $sdk = Join-Path $env:DEVECO_CLI_CLT_PATH 'sdk\default\openharmony'
    $lib = Join-Path $sdk 'toolchains\lib'
    $chain = Join-Path $root 'signing\app-chain.cer'
    $profile = Join-Path $root 'signing\hmstart-debug.p7b'
    $keystore = Join-Path $lib 'OpenHarmony.p12'
    $signTool = Join-Path $lib 'hap-sign-tool.jar'
    foreach ($f in @($chain, $profile, $keystore, $signTool)) {
        if (-not (Test-Path $f)) { Fail "Missing signing input: $f" }
    }
    $java = (Get-Command java -ErrorAction SilentlyContinue).Source
    if (-not $java) { Fail 'java not found on PATH; needed for hap-sign-tool.jar' }

    $signedName = "zhijian-$version-$mode-signed.hap"
    $signed = Join-Path $distDir $signedName
    Write-Host "Signing (local debug chain) -> $signedName"
    & $java -jar $signTool sign-app `
        -mode localSign `
        -keyAlias 'openharmony application release' `
        -keyPwd 123456 `
        -appCertFile $chain `
        -profileFile $profile `
        -profileSigned 1 `
        -inFile $artifact `
        -signAlg SHA256withECDSA `
        -keystoreFile $keystore `
        -keystorePwd 123456 `
        -outFile $signed `
        -compatibleVersion 26 `
        -signCode 1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $signed)) { Fail 'HAP signing failed' }
    Write-Host "Published $signedName (emulator only)" -ForegroundColor Green
}

# ---- summary ----------------------------------------------------------------
$elapsed = ((Get-Date) - $startedAt).TotalSeconds
$sizeMb = [Math]::Round((Get-Item $published).Length / 1MB, 2)
Write-Host ''
Write-Host "  version  $version"
Write-Host "  mode     $mode / product $Product"
Write-Host "  output   $published"
Write-Host "  size     $sizeMb MB"
Write-Host "  elapsed  $([Math]::Round($elapsed))s"
