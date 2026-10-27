param(
    [switch]$SkipBuild,
    [switch]$NoLaunch,
    [string]$Device = '127.0.0.1:15000',
    [int]$StallSec = 45
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
    # 这一段是**唯一**会让这个脚本「卡住」的地方，两个坑都在这里：
    #
    # 1. **`devecocli build` 会起 hvigor 常驻守护进程。** 上一次被超时打断的构建
    #    会留下一个仍握着构建目录的 `node`，下一次构建就静静坐着、一行输出都没有
    #    （实测：两次都停在 ~2 % CPU，杀掉那两个进程后同一命令 17 s 跑完）。
    #    所以先把**本次启动之前**的 hvigor node 清掉。只清命令行里带 `hvigor` 的，
    #    绝不 `Stop-Process node` 全杀——MCP 服务也是 node。
    # 2. **`devecocli build` 比 `hvigorw --no-daemon` 慢一个数量级**（114 s vs 17 s，
    #    见 AGENTS.md）。这里直接走 no-daemon 路径，和 `scripts\dist.ps1` 一致。
    #
    # 顺带加一个看门狗：45 s 没有新输出就判定为死锁，杀掉重试一次。
    $started = Get-Date
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
        Where-Object { $_.CommandLine -match 'hvigor' -and $_.CreationDate -lt $started.AddSeconds(-5) } |
        ForEach-Object {
            Write-Host "  reaping stale hvigor node $($_.ProcessId) ($($_.CreationDate))"
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }

    # 只杀 `$proc.Id` 不够：`hvigorw.bat` 是 cmd 包装器，真正的 hvigor 是它派生出来的
    # `node`。杀掉包装器，node 仍然握着构建目录——下一次构建照样安静地坐着
    # （实测：连续两次 45 s 静默，两次都留下 2 个 node）。所以按「本次尝试开始时间
    # 之后启动的 hvigor node」整棵摘掉；只匹配命令行里带 `hvigor` 的，绝不 `node` 全杀，
    # MCP 服务也是 node。
    function KillHvigorTree([datetime]$since) {
        Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
            Where-Object { $_.CommandLine -match 'hvigor' -and $_.CreationDate -ge $since.AddSeconds(-2) } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { } }
    }

    $hvigor = Join-Path $env:DEVECO_CLI_CLT_PATH 'bin\hvigorw.bat'
    $args_ = @('--mode', 'module', '-p', 'module=entry@default', '-p', 'product=default',
        'assembleHap', '--no-daemon')
    $log = Join-Path $env:TEMP 'hmstart-build.log'
    Remove-Item $log, "$log.err" -ErrorAction SilentlyContinue

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        Write-Host "Building entry (attempt $attempt) ..."
        $attemptStart = Get-Date
        $proc = Start-Process -FilePath $hvigor -ArgumentList $args_ -WorkingDirectory $root `
            -NoNewWindow -PassThru -RedirectStandardOutput $log -RedirectStandardError "$log.err"
        $lastSize = -1
        $lastChange = Get-Date
        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 700
            $size = if (Test-Path $log) { (Get-Item $log).Length } else { 0 }
            if ($size -ne $lastSize) {
                $lastSize = $size
                $lastChange = Get-Date
            } elseif (((Get-Date) - $lastChange).TotalSeconds -ge $StallSec) {
                Write-Warning "no build output for ${StallSec}s (lines so far: $((Get-Content $log -ErrorAction SilentlyContinue | Measure-Object -Line).Lines)) - treating as deadlock"
                try { $proc.Kill() } catch { }
                KillHvigorTree $attemptStart
                break
            }
        }
        $proc.WaitForExit()
        if ($proc.ExitCode -eq 0) { break }
        if ($attempt -eq 2) {
            if (Test-Path $log) { Get-Content $log -Tail 20 }
            throw "Build failed (exit $($proc.ExitCode))"
        }
        Write-Warning "build exited $($proc.ExitCode); retrying once"
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
