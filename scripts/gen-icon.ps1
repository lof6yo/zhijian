Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# 纸见 (ZhiJian) 应用图标生成器
#
# 母版是 design/my-icon.png（1024×1024，白色图形 + 蓝色马赛克底）。本脚本不重绘
# 任何线条，只把它拆成 HarmonyOS 分层图标要求的两层：
#
#   foreground.png  1024×1024，**透明** PNG，只有白色图形（带正确的抗锯齿 alpha）。
#   background.png  1024×1024，**不透明**，马赛克底（图形原来盖住的那块补回去）。
#   startIcon.png   216×216，两层合成后的小图（部分系统位置只读这一张）。
#
# 为什么必须拆成两层，而不是整张图直接用：
#   分层图标在桌面、解锁、设置里会被按不同尺寸重采样，前景层还有轻微视差。
#   图形和底色烤在同一张 PNG 里，任何一次重采样都会把白色边缘与蓝底混出一圈灰；
#   分成「透明前景 + 不透明背景」之后，白永远在白层、蓝永远在蓝层，边缘才干净。
#   这也是 HarmonyOS 图标资源的硬结构，不是可选项。
#
# 背景层为什么可以是马赛克而不是纯色：
#   「背景层建议纯色」是设计建议，不是资源校验项——它只是一张普通 PNG。
#   这里的花纹是用户指定的设计，保留。但**图形底下那一块必须补成底色**：
#   若留白，前景层在某些缩放档位比背景层小一圈时会露出一道白边。
#
# ---------------------------------------------------------------------------
# 抠图方法论：反解 alpha，不猜
# ---------------------------------------------------------------------------
# 这里踩过两次坑，都是「靠猜」导致的，记下来避免重犯：
#
#   坑 1：按亮度硬阈值切白色。切完之后，图形边缘那一圈**抗锯齿过渡像素**
#   （实测 716 px，亮度落在 150–200 之间）既不算前景也不算纯底色，被原样留在
#   背景层里。它们比底色亮得多，于是背景上出现一圈灰白描边（实测那圈是
#   #526FA0），图标边缘看着像糊了一层。
#
#   坑 2：给过渡像素估一个半透明 alpha。要正确合成半透明，必须知道「这一像素
#   底下原本是什么底色」；底色被图形盖住，只能靠邻域推测，推测差几个色阶就会
#   在深色底上显出一圈灰。
#
# 正确的路子是：**底色不是猜的，是确定已知的。** 母版是 3×3 纯色马赛克，每个
# 像素属于哪一格可以算出来，每格的颜色可以从该格的可见部分投票得到。于是：
#
#   1. 先重建底板 bg（每格填该格的纯色）。
#   2. 逐像素反解 alpha = (源 - bg) / (白 - bg)，这是解混合方程，不是估计。
#   3. 用「合成回来 == 母版」做端到端验证——这一步能抓住任何一处抠错。
#
# 于是抗锯齿边被完整保留在白层的 alpha 里，背景层没有任何残留亮边。
#
# ---------------------------------------------------------------------------
# 依赖说明（改脚本前先读）
#   本机是 CLT-only，**没有 .NET SDK、没有 csc**，PowerShell 7 的 Add-Type 无法
#   引用 System.Drawing（CS1069：找不到 System.Drawing.Common）。所以像素处理
#   全部走 `Add-Type -AssemblyName System.Drawing` + LockBits 读写 byte[]，
#   不用内联 C#。纯 PS 每趟 1M 像素约 2.3 s，整脚本约 6 s——在这台机器上能跑。
# ---------------------------------------------------------------------------

$SRC = Join-Path (Split-Path $PSScriptRoot -Parent) 'design\my-icon.png'
$N = 1024

# 马赛克网格：实测格宽 = 1024/3 ≈ 341.33，边界落在半格偏移处
# （y=100 一行上的分界在 x=170 / 512 / 853）。
$CELL = $N / 3.0
$CELL_OFFSET = $CELL / 2.0

# 「这一像素属于图形（而不是底色）」的判定：亮度 >= 150。
# 实测三种格色的亮度是 87.7 / 122.7 / 56.5，白色 255，所以 150 落在两者之间
# 且离两边都远。用它一次性圈住「白色 + 抗锯齿过渡带」，见文件头坑 1。
$GLYPH_LUM_MIN = 150

# 色板投票的门槛。母版是纯色马赛克，真实格色各有 7 万像素以上，混色只有几十。
# 门槛取 2000 就能把真实格色与「格边界过渡色」「抗锯齿混色」彻底分开。
$PALETTE_MIN_VOTES = 2000

$root = Split-Path $PSScriptRoot -Parent
$appMedia = Join-Path $root 'AppScope\resources\base\media'
$entryMedia = Join-Path $root 'entry\src\main\resources\base\media'
$designDir = Join-Path $root 'design\icon'
foreach ($d in @($appMedia, $entryMedia, $designDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
if (-not (Test-Path $SRC)) { Write-Error "母版不存在: $SRC"; exit 1 }

$sw = [Diagnostics.Stopwatch]::StartNew()

# --- 读母版 ----------------------------------------------------------------
$srcBmp = [System.Drawing.Bitmap]::FromFile($SRC)
if ($srcBmp.Width -ne $N -or $srcBmp.Height -ne $N) {
    Write-Error "母版必须是 ${N}x${N}，实际 $($srcBmp.Width)x$($srcBmp.Height)"; exit 1
}
$W = $srcBmp.Width; $H = $srcBmp.Height
$rect = New-Object System.Drawing.Rectangle(0, 0, $W, $H)
$srcData = $srcBmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$stride = $srcData.Stride
$src = New-Object 'byte[]' ($stride * $H)
[System.Runtime.InteropServices.Marshal]::Copy($srcData.Scan0, $src, 0, $src.Length)
$srcBmp.UnlockBits($srcData)
$srcBmp.Dispose()
Write-Host "read master in $($sw.ElapsedMilliseconds) ms  (${W}x${H}, stride $stride)"

# --- 1) 图形范围 + 亮度缓存 ------------------------------------------------
# $lum[$i] 缓存每像素亮度，后面要用好几趟。
$lum = New-Object 'single[]' ($W * $H)
$glyphL = $W; $glyphT = $H; $glyphR = -1; $glyphB = -1
$glyphPx = 0
for ($y = 0; $y -lt $H; $y++) {
    $row = $y * $stride
    $mrow = $y * $W
    for ($x = 0; $x -lt $W; $x++) {
        $o = $row + $x * 4
        $l = ([int]$src[$o] + [int]$src[$o + 1] + [int]$src[$o + 2]) / 3.0
        $lum[$mrow + $x] = [single]$l
        if ($l -ge $GLYPH_LUM_MIN) {
            $glyphPx++
            if ($x -lt $glyphL) { $glyphL = $x }
            if ($x -gt $glyphR) { $glyphR = $x }
            if ($y -lt $glyphT) { $glyphT = $y }
            if ($y -gt $glyphB) { $glyphB = $y }
        }
    }
}
Write-Host "luminance cached in $($sw.ElapsedMilliseconds) ms  glyph px=$glyphPx"
if ($glyphR -lt 0) { Write-Error "母版里没有找到白色图形（阈值 $GLYPH_LUM_MIN 太高？）"; exit 1 }
Write-Host "glyph extent: x=$glyphL..$glyphR  y=$glyphT..$glyphB"

# --- 2) 色板：整张图里票数够高的颜色 ---------------------------------------
$paletteHist = @{}
for ($y = 0; $y -lt $H; $y += 3) {
    $row = $y * $stride
    for ($x = 0; $x -lt $W; $x += 3) {
        $o = $row + $x * 4
        if ($lum[$y * $W + $x] -ge $GLYPH_LUM_MIN) { continue }
        $k = ([int]$src[$o + 2] -shl 16) -bor ([int]$src[$o + 1] -shl 8) -bor [int]$src[$o]
        if ($paletteHist.ContainsKey($k)) { $paletteHist[$k]++ } else { $paletteHist[$k] = 1 }
    }
}
$palette = @($paletteHist.GetEnumerator() | Where-Object { $_.Value -ge $PALETTE_MIN_VOTES } | Sort-Object Value -Descending | ForEach-Object { $_.Key })
Write-Host "palette: $($palette.Count) colours"
foreach ($p in $palette) {
    $pr = ($p -shr 16) -band 0xFF; $pg = ($p -shr 8) -band 0xFF; $pb = $p -band 0xFF
    Write-Host ("  #{0:X2}{1:X2}{2:X2}  lum={3,7:N2}  {4} votes" -f $pr, $pg, $pb, (($pr + $pg + $pb) / 3.0), $paletteHist[$p])
}
if ($palette.Count -lt 1) { Write-Error '色板为空：母版不是纯色马赛克？'; exit 1 }

# --- 3) 每格底色 -----------------------------------------------------------
# 只用色板里的颜色投票。被图形盖住大半的格子会投不出票，这时用格心附近的像素
# 映射到最近的色板色兜底——绝不允许出现色板之外的颜色。
$cellColor = @{}
for ($cy = -1; $cy -le 3; $cy++) {
    for ($cx = -1; $cx -le 3; $cx++) {
        $x0 = [int][math]::Floor($cx * $CELL - $CELL_OFFSET)
        $x1 = [int][math]::Floor(($cx + 1) * $CELL - $CELL_OFFSET) - 1
        $y0 = [int][math]::Floor($cy * $CELL - $CELL_OFFSET)
        $y1 = [int][math]::Floor(($cy + 1) * $CELL - $CELL_OFFSET) - 1
        if ($x1 -lt 0 -or $y1 -lt 0 -or $x0 -ge $W -or $y0 -ge $H) { continue }
        if ($x0 -lt 0) { $x0 = 0 }; if ($y0 -lt 0) { $y0 = 0 }
        if ($x1 -ge $W) { $x1 = $W - 1 }; if ($y1 -ge $H) { $y1 = $H - 1 }

        $votes = @{}
        for ($y = $y0; $y -le $y1; $y += 6) {
            $row = $y * $stride
            for ($x = $x0; $x -le $x1; $x += 6) {
                if ($lum[$y * $W + $x] -ge $GLYPH_LUM_MIN) { continue }
                $o = $row + $x * 4
                $k = ([int]$src[$o + 2] -shl 16) -bor ([int]$src[$o + 1] -shl 8) -bor [int]$src[$o]
                if (-not $paletteHist.ContainsKey($k) -or $paletteHist[$k] -lt $PALETTE_MIN_VOTES) { continue }
                if ($votes.ContainsKey($k)) { $votes[$k]++ } else { $votes[$k] = 1 }
            }
        }
        if ($votes.Count -gt 0) {
            $cellColor["$cx,$cy"] = ($votes.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
        } else {
            $px = [int](($x0 + $x1) / 2); $py = [int](($y0 + $y1) / 2)
            if ($px -lt 0) { $px = 0 }; if ($px -ge $W) { $px = $W - 1 }
            if ($py -lt 0) { $py = 0 }; if ($py -ge $H) { $py = $H - 1 }
            $o = $py * $stride + $px * 4
            $r = [int]$src[$o + 2]; $g = [int]$src[$o + 1]; $b = [int]$src[$o]
            $best = $palette[0]; $bestD = [double]::MaxValue
            foreach ($p in $palette) {
                $d = [math]::Pow($r - (($p -shr 16) -band 0xFF), 2) + [math]::Pow($g - (($p -shr 8) -band 0xFF), 2) + [math]::Pow($b - ($p -band 0xFF), 2)
                if ($d -lt $bestD) { $bestD = $d; $best = $p }
            }
            $cellColor["$cx,$cy"] = $best
        }
    }
}
Write-Host "cell colours: $($cellColor.Count) cells"
$cellColor.GetEnumerator() | Sort-Object Name | ForEach-Object {
    $v = $_.Value
    Write-Host ("  cell {0,-5} #{1:X2}{2:X2}{3:X2}" -f $_.Name, (($v -shr 16) -band 0xFF), (($v -shr 8) -band 0xFF), ($v -band 0xFF))
}

# --- 4) 背景 = 母版 + 图形区域按格填色 -------------------------------------
$bg = New-Object 'byte[]' $src.Length
[Array]::Copy($src, $bg, $src.Length)
for ($y = $glyphT; $y -le $glyphB; $y++) {
    $cy = [int][math]::Floor(($y + $CELL_OFFSET) / $CELL)
    $row = $y * $stride
    $mrow = $y * $W
    for ($x = $glyphL; $x -le $glyphR; $x++) {
        if ($lum[$mrow + $x] -lt $GLYPH_LUM_MIN) { continue }
        $cx = [int][math]::Floor(($x + $CELL_OFFSET) / $CELL)
        $k = $cellColor["$cx,$cy"]
        if ($null -eq $k) { $k = $palette[0] }
        $o = $row + $x * 4
        $bg[$o] = [byte]($k -band 0xFF)
        $bg[$o + 1] = [byte](($k -shr 8) -band 0xFF)
        $bg[$o + 2] = [byte](($k -shr 16) -band 0xFF)
    }
}
Write-Host "background built in $($sw.ElapsedMilliseconds) ms"

# --- 5) 前景 = 反解 alpha 得到的纯白 ---------------------------------------
# 解混合方程：src = a*255 + (1-a)*bg  →  a = (src - bg) / (255 - bg)
# 对 RGB 三通道各解一次再取均值，比只看亮度稳（亮度会把色度误差平均掉）。
# 结果 clamp 到 0..1：低于 0 是噪声（源比底色还暗，说明该处不是图形），
# 高于 1 是白色本体。
$fg = New-Object 'byte[]' $src.Length
$maxA = 0; $partial = 0
for ($y = 0; $y -lt $H; $y++) {
    $row = $y * $stride
    $mrow = $y * $W
    for ($x = 0; $x -lt $W; $x++) {
        $o = $row + $x * 4
        $sr = [double]$src[$o + 2]; $sg = [double]$src[$o + 1]; $sb = [double]$src[$o]
        $br = [double]$bg[$o + 2]; $bgc = [double]$bg[$o + 1]; $bb = [double]$bg[$o]

        # bg 已经是"纯底色"，源像素若与它几乎相同，直接判为完全透明。
        $dr = $sr - $br; $dg = $sg - $bgc; $db = $sb - $bb
        if ([math]::Abs($dr) -le 1.5 -and [math]::Abs($dg) -le 1.5 -and [math]::Abs($db) -le 1.5) {
            $fg[$o] = 0; $fg[$o + 1] = 0; $fg[$o + 2] = 0; $fg[$o + 3] = 0
            continue
        }

        $ar = if (255 - $br -gt 0.5) { $dr / (255 - $br) } else { 0 }
        $ag = if (255 - $bgc -gt 0.5) { $dg / (255 - $bgc) } else { 0 }
        $ab = if (255 - $bb -gt 0.5) { $db / (255 - $bb) } else { 0 }
        $a = ($ar + $ag + $ab) / 3.0
        if ($a -lt 0) { $a = 0 }
        if ($a -gt 1) { $a = 1 }
        $ai = [int][math]::Round($a * 255)
        if ($ai -eq 0) {
            $fg[$o] = 0; $fg[$o + 1] = 0; $fg[$o + 2] = 0; $fg[$o + 3] = 0
        } else {
            # 颜色恒为白：alpha 已经把「有多少白」表达完了。
            $fg[$o] = 255; $fg[$o + 1] = 255; $fg[$o + 2] = 255; $fg[$o + 3] = [byte]$ai
            if ($ai -eq 255) { $maxA++ } else { $partial++ }
        }
    }
}
Write-Host "foreground solved in $($sw.ElapsedMilliseconds) ms  fully-opaque=$maxA partial-alpha=$partial"

# --- 6) 合成 + 缩放 + 落盘 -------------------------------------------------
function New-BitmapFromBuffer {
    param([byte[]]$buf, [int]$w, [int]$h, [int]$strideBytes)
    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $r = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $d = $bmp.LockBits($r, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    [System.Runtime.InteropServices.Marshal]::Copy($buf, 0, $d.Scan0, $strideBytes * $h)
    $bmp.UnlockBits($d)
    return $bmp
}

function Resize-Bitmap {
    param([System.Drawing.Bitmap]$srcBmp, [int]$px)
    $dst = New-Object System.Drawing.Bitmap($px, $px, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($dst)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.DrawImage($srcBmp, (New-Object System.Drawing.Rectangle(0, 0, $px, $px)), 0, 0, $srcBmp.Width, $srcBmp.Height, [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    return $dst
}

$fgBmp = New-BitmapFromBuffer -buf $fg -w $W -h $H -strideBytes $stride
$bgBmp = New-BitmapFromBuffer -buf $bg -w $W -h $H -strideBytes $stride

$comp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$cg = [System.Drawing.Graphics]::FromImage($comp)
$cg.Clear([System.Drawing.Color]::Transparent)
$cg.DrawImage($bgBmp, 0, 0)
$cg.DrawImage($fgBmp, 0, 0)
$cg.Dispose()

$start216 = Resize-Bitmap -srcBmp $comp -px 216
$preview48 = Resize-Bitmap -srcBmp $comp -px 48

foreach ($dir in @($appMedia, $entryMedia)) {
    $fgBmp.Save((Join-Path $dir 'foreground.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    $bgBmp.Save((Join-Path $dir 'background.png'), [System.Drawing.Imaging.ImageFormat]::Png)
}
$start216.Save((Join-Path $entryMedia 'startIcon.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$start216.Save((Join-Path $designDir 'preview-216.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$preview48.Save((Join-Path $designDir 'preview-48.png'), [System.Drawing.Imaging.ImageFormat]::Png)
Write-Host "files written in $($sw.ElapsedMilliseconds) ms"

# --- 7) 契约检查 -----------------------------------------------------------
$errors = New-Object 'System.Collections.Generic.List[string]'
$report = New-Object 'System.Collections.Generic.List[string]'

# 7a) 端到端重建：合成结果必须还原母版。
# 这是最有说服力的一条——它同时验证了补底与 alpha 两件事，任何一处抠错都会命中。
$maxErr = 0; $sumErr = 0.0; $badPx = 0; $n = 0
for ($y = 0; $y -lt $H; $y += 3) {
    $row = $y * $stride
    for ($x = 0; $x -lt $W; $x += 3) {
        $o = $row + $x * 4
        $n++
        foreach ($ch in @(0, 1, 2)) {
            $d = [math]::Abs([int]$src[$o + $ch] - [int]$bg[$o + $ch])
            $a = [double]$fg[$o + 3] / 255.0
            # 合成：alpha 混合
            $cv = if ($a -ge 0.999) { 255 } else { [int][math]::Round(255 * $a + [int]$bg[$o + $ch] * (1 - $a)) }
            $e = [math]::Abs([int]$src[$o + $ch] - $cv)
            if ($e -gt $maxErr) { $maxErr = $e }
            $sumErr += $e
            if ($e -gt 12) { $badPx++ }
        }
    }
}
$meanErr = [math]::Round($sumErr / ([double]$n * 3), 2)
$report.Add("Rebuild vs master: max channel error=$maxErr  mean=$meanErr  samples over 12=$badPx / $($n*3)")
if ($maxErr -gt 40 -or $meanErr -gt 2.0) {
    $errors.Add("composite does not reproduce the master (max=$maxErr mean=$meanErr) — the alpha solve is wrong")
}

# 7b) 几何：安全区与占比
$gw = $glyphR - $glyphL + 1
$gh = $glyphB - $glyphT + 1
$report.Add("Glyph box x=$glyphL..$glyphR y=$glyphT..$glyphB = ${gw}x${gh}  ($([math]::Round($gw*100.0/$W,1))% x $([math]::Round($gh*100.0/$H,1))%)")
$report.Add("  margins L=$glyphL T=$glyphT R=$($W-1-$glyphR) B=$($H-1-$glyphB)")
$limit = [int][math]::Floor($W * 0.17)
if ($glyphL -lt $limit -or $glyphT -lt $limit -or ($W - 1 - $glyphR) -lt $limit -or ($H - 1 - $glyphB) -lt $limit) {
    $errors.Add("glyph enters the safe margin (min $limit px) — the system mask will clip it")
}
if ($gw -lt $W * 0.4 -or $gh -lt $H * 0.4) {
    $errors.Add("glyph is smaller than 40% of the canvas — it will look lost inside the icon")
}

# 7c) 前景四角全透明；图形实体全不透明
$corners = @( @(0, 0), @(($W - 1), 0), @(0, ($H - 1)), @(($W - 1), ($H - 1)) )
foreach ($p in $corners) {
    if ($fg[$($p[1]) * $stride + $($p[0]) * 4 + 3] -ne 0) { $errors.Add("foreground corner ($($p[0]),$($p[1])) is not transparent") }
}
$probeX = [int](($glyphL + $glyphR) / 2)
if ($fg[($glyphT + 10) * $stride + $probeX * 4 + 3] -ne 255) { $errors.Add('foreground is not opaque on the glyph body') }

# 7d) 背景全不透明，且不含色板之外的颜色
$bgNonOpaque = 0
for ($y = 0; $y -lt $H; $y += 16) {
    for ($x = 0; $x -lt $W; $x += 16) {
        if ($bg[$y * $stride + $x * 4 + 3] -ne 255) { $bgNonOpaque++ }
    }
}
if ($bgNonOpaque -gt 0) { $errors.Add("background has $bgNonOpaque non-opaque samples — it must be fully opaque") }

$known = @{}
foreach ($p in $palette) { $known[$p] = $true }
$strayColours = @{}
for ($y = 0; $y -lt $H; $y += 3) {
    $row = $y * $stride
    for ($x = 0; $x -lt $W; $x += 3) {
        $o = $row + $x * 4
        if ($lum[$y * $W + $x] -ge 250) { continue }  # 白色图形本体不参与
        $k = ([int]$bg[$o + 2] -shl 16) -bor ([int]$bg[$o + 1] -shl 8) -bor [int]$bg[$o]
        if ($strayColours.ContainsKey($k)) { $strayColours[$k]++ } else { $strayColours[$k] = 1 }
    }
}
$strayBig = @($strayColours.GetEnumerator() | Where-Object { -not $known.ContainsKey($_.Key) -and $_.Value -gt 200 } | Sort-Object Value -Descending)
$report.Add("Background colours outside the palette (>200 samples): $($strayBig.Count)")
foreach ($s in ($strayBig | Select-Object -First 5)) {
    $report.Add(("  stray #{0:X2}{1:X2}{2:X2}  {3} samples" -f (($s.Key -shr 16) -band 0xFF), (($s.Key -shr 8) -band 0xFF), ($s.Key -band 0xFF), $s.Value))
    $errors.Add(("background contains a non-palette colour #{0:X2}{1:X2}{2:X2} ({3} samples) — a blend leaked in" -f (($s.Key -shr 16) -band 0xFF), (($s.Key -shr 8) -band 0xFF), ($s.Key -band 0xFF), $s.Value))
}

# 7e) 48 px 下的可读性
$p48 = [System.Drawing.Bitmap]::FromFile((Join-Path $designDir 'preview-48.png'))
$ink = 0
for ($y = 0; $y -lt 48; $y++) {
    for ($x = 0; $x -lt 48; $x++) {
        $c = $p48.GetPixel($x, $y)
        if ($c.R -gt 170 -and $c.G -gt 170 -and $c.B -gt 170) { $ink++ }
    }
}
$p48.Dispose()
$cov = [math]::Round($ink / 2304.0, 4)
$report.Add("preview-48 white coverage: $ink / 2304 = $cov")
if ($cov -lt 0.08 -or $cov -gt 0.35) {
    $errors.Add("48px white coverage $cov is outside 0.08-0.35 — the glyph will not read when small")
}

# --- 8) 输出 ---------------------------------------------------------------
$fgBmp.Dispose(); $bgBmp.Dispose(); $comp.Dispose(); $start216.Dispose(); $preview48.Dispose()

Write-Host ''
Write-Host '=== Generated files ==='
Get-ChildItem $appMedia, $entryMedia -Filter *.png | ForEach-Object {
    $i = [System.Drawing.Image]::FromFile($_.FullName)
    '{0,-60} {1}x{2}  {3,8} bytes' -f $_.FullName.Replace($root, ''), $i.Width, $i.Height, $_.Length
    $i.Dispose()
}
Get-ChildItem $designDir -Filter preview-*.png | ForEach-Object {
    $i = [System.Drawing.Image]::FromFile($_.FullName)
    '{0,-60} {1}x{2}  {3,8} bytes' -f $_.FullName.Replace($root, ''), $i.Width, $i.Height, $_.Length
    $i.Dispose()
}

Write-Host ''
Write-Host '=== Report ==='
$report | ForEach-Object { Write-Host $_ }

if ($errors.Count -gt 0) {
    Write-Host ''
    Write-Host '=== ERRORS ==='
    $errors | ForEach-Object { Write-Error $_ }
    exit 1
}
Write-Host ''
Write-Host "icon layers OK in $($sw.ElapsedMilliseconds) ms"
