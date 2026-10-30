Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# 纸见 (ZhiJian) 应用图标生成器
#
# 母版是 design/icon.png（1024×1024，米色等高线底板上的深青 # 字形）。本脚本不
# 重绘任何线条，只从它派生系统需要的两个资源：
#
#   app_icon.png    1024×1024，不透明 PNG。AppScope 与 entry 各一份。
#   startIcon.png   216×216，启动窗口图标（部分系统位置只读这一张）。
#
# ---------------------------------------------------------------------------
# 为什么是单层图标，不是 layered_image
# ---------------------------------------------------------------------------
# 这里曾经把母版拆成「透明前景 + 不透明背景」两层（HarmonyOS 的分层图标）。那条路
# 走不通，而且不是因为参数没调好，所以记下来避免重走：
#
#   分层要求把字形从底板里抠出来，而这张母版的底板在字形底下**不可见**。能抠出来的
#   前提是「重建底板，再逐像素解混合」，但合成回原图的约束是
#
#       a ≥ k,   k = max_c |src_c − plate_c| / headroom
#
#   这是个硬下界：只要底板在某个像素不等于 src，那里就必然有前景墨。底板是重建的、
#   天生带误差，于是极光的蓝色雾斑整片漏进前景层（实测前景 PNG 783 KB，铺到中灰上
#   看得见蓝云）。放大 alpha 的增益会把误差放大三倍；调阈值只能两边都伤——收紧就把
#   玻璃本体也切掉，放松就漏雾斑。
#
# 单层图标没有这个问题：整张 PNG 就是最终像素，系统用它的圆角遮罩裁剪。代价只是
# 没有分层视差——而图标在 48–216px 下看不出视差，抠图却会实实在在把边缘弄脏。
#
# 上一版母版（3×3 纯色马赛克 + 纯白字形）可以拆，因为底板逐像素确定已知，
# a = (src−bg)/(255−bg) 是解出来的而不是猜的。换母版时先问一句「底板在字形底下
# 是否已知」，未知就走单层。
#
# ---------------------------------------------------------------------------
# 依赖说明（改脚本前先读）
# ---------------------------------------------------------------------------
#   本机是 CLT-only，**没有 .NET SDK、没有 csc**，PowerShell 7 的 Add-Type 无法
#   引用 System.Drawing（CS1069：找不到 System.Drawing.Common）。所以像素处理
#   全部走 `Add-Type -AssemblyName System.Drawing` + LockBits 读写 byte[]。
#
#   一个 PowerShell 陷阱：变量名**大小写不敏感**。曾经用 `$N = 1024` 当画布尺寸，
#   被循环计数器 `$n` 覆盖，后面 New-Bitmap($N,$N) 就建出 4×4 的位图。画布尺寸
#   一律叫 $SIDE，循环计数不叫 $n。
# ---------------------------------------------------------------------------

$root = Split-Path $PSScriptRoot -Parent
$SRC = Join-Path $root 'design\icon.png'
$SIDE = 1024
$START_PX = 216

$appMedia = Join-Path $root 'AppScope\resources\base\media'
$entryMedia = Join-Path $root 'entry\src\main\resources\base\media'
$designDir = Join-Path $root 'design\icon'
foreach ($d in @($appMedia, $entryMedia, $designDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
if (-not (Test-Path $SRC)) { Write-Error "母版不存在: $SRC"; exit 1 }

$sw = [Diagnostics.Stopwatch]::StartNew()

$src = [System.Drawing.Bitmap]::FromFile($SRC)
if ($src.Width -ne $SIDE -or $src.Height -ne $SIDE) {
    Write-Error "母版必须是 $($SIDE)x$($SIDE)，实际 $($src.Width)x$($src.Height)"; exit 1
}

# 母版必须不透明。系统会用它做整块图标底，任何透明像素都会透出桌面。
$rect = New-Object System.Drawing.Rectangle(0, 0, $SIDE, $SIDE)
$bd = $src.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$stride = $bd.Stride
$buf = New-Object 'byte[]' ($stride * $SIDE)
[System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $buf, 0, $buf.Length)
$src.UnlockBits($bd)
$minAlpha = 255; $alphaBad = 0
for ($y = 0; $y -lt $SIDE; $y += 3) {
    $row = $y * $stride
    for ($x = 0; $x -lt $SIDE; $x += 3) {
        $av = $buf[$row + $x * 4 + 3]
        if ($av -lt $minAlpha) { $minAlpha = $av }
        if ($av -ne 255) { $alphaBad++ }
    }
}
if ($alphaBad -gt 0) { Write-Error "母版有透明像素（min alpha=$minAlpha，$alphaBad 个采样）——图标底必须不透明"; exit 1 }
Write-Host "master ${SIDE}x$SIDE opaque, checked in $($sw.ElapsedMilliseconds) ms"

# 两份 app_icon.png。entry 的副本优先于 AppScope，所以两处都要写：
# 只写一处时，另一处仍渲染旧图标，而两边文件名相同，看起来像「改了没生效」。
foreach ($dir in @($appMedia, $entryMedia)) {
    $src.Save((Join-Path $dir 'app_icon.png'), [System.Drawing.Imaging.ImageFormat]::Png)
}

function Resize-Bitmap {
    param([System.Drawing.Bitmap]$srcBmp, [int]$px)
    $dst = New-Object System.Drawing.Bitmap($px, $px, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($dst)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.DrawImage($srcBmp, (New-Object System.Drawing.Rectangle(0, 0, $px, $px)), 0, 0, $srcBmp.Width, $srcBmp.Height, [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    return $dst
}

$start = Resize-Bitmap -srcBmp $src -px $START_PX
$start.Save((Join-Path $entryMedia 'startIcon.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$start.Save((Join-Path $designDir 'preview-216.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$start.Dispose()

$p48 = Resize-Bitmap -srcBmp $src -px 48
$p48.Save((Join-Path $designDir 'preview-48.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$p48.Dispose()
Write-Host "files written in $($sw.ElapsedMilliseconds) ms"

# --- 契约检查 --------------------------------------------------------------
# 这里只查「资源是否可用」，不查「图标好不好看」——那是设计判断，脚本没有发言权。
$errors = New-Object 'System.Collections.Generic.List[string]'
$report = New-Object 'System.Collections.Generic.List[string]'

foreach ($dir in @($appMedia, $entryMedia)) {
    $p = Join-Path $dir 'app_icon.png'
    if (-not (Test-Path $p)) { $errors.Add("missing $p"); continue }
    $im = [System.Drawing.Bitmap]::FromFile($p)
    if ($im.Width -ne $SIDE -or $im.Height -ne $SIDE) { $errors.Add("$p is $($im.Width)x$($im.Height), expected ${SIDE}x$SIDE") }
    if ($im.PixelFormat -ne [System.Drawing.Imaging.PixelFormat]::Format32bppArgb) { $report.Add("$p format: $($im.PixelFormat)") }
    $im.Dispose()
}

# 引用一致性：两个清单都必须指向 app_icon，且不能残留 layered_image
foreach ($pair in @(@((Join-Path $root 'AppScope\app.json5'), 'app.json5'), @((Join-Path $root 'entry\src\main\module.json5'), 'module.json5'))) {
    $text = [System.IO.File]::ReadAllText($pair[0])
    if ($text -match 'layered_image') { $errors.Add("$($pair[1]) still references layered_image") }
    if ($text -notmatch '\$media:app_icon') { $errors.Add("$($pair[1]) does not reference \$media:app_icon") }
}
if (-not (Test-Path (Join-Path $entryMedia 'startIcon.png'))) { $errors.Add('missing startIcon.png') }

# 48px 下的可读性。图标最小出现在通知栏与设置列表里，那里读不出来就等于没有。
#
# 判据不能是「与底板不同的像素」：当前母版的底板本身带等高线，那条线一路画到画布
# 边缘，于是整张画布都被框成「字形」（实测 bbox 1023×1023，对比度算出 NaN）。也
# 不能用画布第一个像素当底板——那里正好压着一条等高线。
#
# 底板取**明度的众数**：底色占绝大多数像素，纹理只占少数。字形判据是「与底板明度
# 相差超过一半的、到底色对面那一端的距离」，浅底要相当深的墨才算，深底要相当亮的墨
# 才算，纹理因为不够远而被排除在外。判据取绝对值，两种方向同一条公式。
$hist = New-Object 'int[]' 256
for ($y = 0; $y -lt $SIDE; $y += 4) {
    $row = $y * $stride
    for ($x = 0; $x -lt $SIDE; $x += 4) {
        $i = $row + $x * 4
        $hist[[int](0.299 * $buf[$i + 2] + 0.587 * $buf[$i + 1] + 0.114 * $buf[$i])]++
    }
}
$modeBin = 0
for ($b = 1; $b -lt 256; $b++) { if ($hist[$b] -gt $hist[$modeBin]) { $modeBin = $b } }
$plateLum = [double]$modeBin
$th = 0.5 * [math]::Max($plateLum, 255 - $plateLum)

$gx0 = $SIDE; $gx1 = -1; $gy0 = $SIDE; $gy1 = -1
$ink = 0
for ($y = 0; $y -lt $SIDE; $y += 2) {
    $row = $y * $stride
    for ($x = 0; $x -lt $SIDE; $x += 2) {
        $i = $row + $x * 4
        $l = 0.299 * $buf[$i + 2] + 0.587 * $buf[$i + 1] + 0.114 * $buf[$i]
        if ([math]::Abs($l - $plateLum) -gt $th) {
            $ink++
            if ($x -lt $gx0) { $gx0 = $x }; if ($x -gt $gx1) { $gx1 = $x }
            if ($y -lt $gy0) { $gy0 = $y }; if ($y -gt $gy1) { $gy1 = $y }
        }
    }
}
$report.Add("plate luminance $plateLum, ink threshold $([math]::Round($th,1))")
if ($gx1 -lt 0) {
    $errors.Add('cannot locate the glyph on the master — no pixel is far enough from the plate luminance')
} else {
    $sampled = ($SIDE / 2) * ($SIDE / 2)
    $report.Add("glyph box x $gx0..$gx1  y $gy0..$gy1  ($($gx1 - $gx0 + 1)x$($gy1 - $gy0 + 1)), coverage $([math]::Round(100.0 * $ink / $sampled, 2))%")

    # 遮罩安全线：系统会裁掉四角，主体落在线外就会被切。
    $safe = [int]($SIDE * 0.17)
    $mLeft = $gx0
    $mTop = $gy0
    $mRight = $SIDE - 1 - $gx1
    $mBottom = $SIDE - 1 - $gy1
    $margins = @($mLeft, $mTop, $mRight, $mBottom)
    $report.Add("margins L/T/R/B $($margins -join ' / ') px, mask safe line $safe px")
    if (($margins | Measure-Object -Minimum).Minimum -lt $safe) {
        $errors.Add("glyph crosses the 17% mask-safe line (margins $($margins -join '/') vs $safe)")
    }
}

$p48 = [System.Drawing.Bitmap]::FromFile((Join-Path $designDir 'preview-48.png'))
$inSum = 0.0; $inCnt = 0; $outSum = 0.0; $outCnt = 0
$scale = 48.0 / $SIDE
$bx0 = $gx0 * $scale; $bx1 = ($gx1 + 1) * $scale
$by0 = $gy0 * $scale; $by1 = ($gy1 + 1) * $scale
for ($y = 0; $y -lt 48; $y++) {
    for ($x = 0; $x -lt 48; $x++) {
        $c = $p48.GetPixel($x, $y)
        $l = 0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B
        if ($x -ge $bx0 -and $x -lt $bx1 -and $y -ge $by0 -and $y -lt $by1) { $inSum += $l; $inCnt++ }
        else { $outSum += $l; $outCnt++ }
    }
}
$p48.Dispose()
$contrast = [math]::Round([math]::Abs($inSum / $inCnt - $outSum / $outCnt), 1)
$report.Add("preview-48 contrast (glyph area vs corners): $contrast levels")
if ($contrast -lt 10) { $errors.Add("48px contrast $contrast is too low — the glyph will not read when small") }

$src.Dispose()

Write-Host ''
Write-Host '=== Generated files ==='
Get-ChildItem $appMedia, $entryMedia -Filter *.png | ForEach-Object {
    $im = [System.Drawing.Image]::FromFile($_.FullName)
    '{0,-58} {1}x{2}  {3,8} bytes' -f $_.FullName.Replace($root, ''), $im.Width, $im.Height, $_.Length
    $im.Dispose()
}
Get-ChildItem $designDir -Filter preview-*.png | ForEach-Object {
    $im = [System.Drawing.Image]::FromFile($_.FullName)
    '{0,-58} {1}x{2}  {3,8} bytes' -f $_.FullName.Replace($root, ''), $im.Width, $im.Height, $_.Length
    $im.Dispose()
}

Write-Host ''
Write-Host '=== Report ==='
$report | ForEach-Object { Write-Host $_ }

if ($errors.Count -gt 0) {
    Write-Host ''
    Write-Host '=== ERRORS ==='
    $errors | ForEach-Object { Write-Host "  - $_" }
    exit 1
}
Write-Host ''
Write-Host "icon OK in $($sw.ElapsedMilliseconds) ms"
