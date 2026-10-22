Add-Type -AssemblyName System.Drawing

# 纸见 (ZhiJian) layered app icon.
# HarmonyOS UX spec requires:
#   foreground.png  1024x1024 transparent PNG, the mark itself
#   background.png  1024x1024 *pure solid* colour (no gradient, no graphics)
#   no self-applied rounded corners, no self-applied inner padding
#
# The mark is a sheet with a dog-eared corner and three text lines, drawn as a
# monoline so it stays crisp at 20 px. It is scaled about the *canvas centre*.
# The mask-safe ceiling is 1.44 — the outer fold point sits 327.8 px from the
# centre at scale 1.0, so 327.8 * 1.44 ≈ 472 plus a half-stroke ≈ 24 → 496,
# just inside the 512 px launcher mask circle. 1.296 is that ceiling minus 10%,
# which reads better next to the system icons.

$DESIGN = 1024.0
$SCALE = 1.296         # 1.44 - 10%

# $size is the real canvas edge in px. The design canvas is always 1024, so the
# centre/scale transform must be computed from $size, not from $DESIGN —
# hard-coding 512 silently draws the 216 px start icon completely off-canvas.
function Add-Mark([System.Drawing.Graphics]$g, [System.Drawing.Color]$ink, [double]$size) {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $k = $size / $DESIGN * $SCALE
    # Translate the canvas centre to the origin, scale, translate back.
    $g.TranslateTransform($size / 2, $size / 2)
    $g.ScaleTransform($k, $k)
    $g.TranslateTransform(-$DESIGN / 2, -$DESIGN / 2)

    $pen = New-Object System.Drawing.Pen $ink, 34.0
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen2 = New-Object System.Drawing.Pen $ink, 27.0
    $pen2.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $pen2.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen2.EndCap = [System.Drawing.Drawing2D.LineCap]::Round

    # Sheet: rounded on three corners, folded on the top-right.
    $r = 46.0
    $l = 300.0; $t = 262.0; $rt = 724.0; $b = 762.0
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc($l, $t, $r * 2, $r * 2, 180, 90)
    $p.AddLine(346, $t, 644, $t)
    $p.AddLine(644, $t, $rt, 342)
    $p.AddLine($rt, 342, $rt, $b - $r)
    $p.AddArc($rt - $r * 2, $b - $r * 2, $r * 2, $r * 2, 0, 90)
    $p.AddLine(678, $b, 346, $b)
    $p.AddArc($l, $b - $r * 2, $r * 2, $r * 2, 90, 90)
    $p.AddLine($l, $b - $r, $l, $t + $r)
    $p.CloseFigure()
    $g.DrawPath($pen, $p)

    # Fold crease: what makes this read as paper rather than a generic document.
    $g.DrawLine($pen2, 644, 262, 644, 342)
    $g.DrawLine($pen2, 644, 342, 724, 342)

    # Text lines, last one short.
    $g.DrawLine($pen2, 372, 438, 600, 438)
    $g.DrawLine($pen2, 372, 512, 652, 512)
    $g.DrawLine($pen2, 372, 586, 500, 586)

    $p.Dispose(); $pen.Dispose(); $pen2.Dispose()
    $g.ResetTransform()
}

function Save-Png([System.Drawing.Bitmap]$bmp, [string]$path) {
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

$root = 'D:\HMProjects\HMStart'
$media = Join-Path $root 'AppScope\resources\base\media'
$entryMedia = Join-Path $root 'entry\src\main\resources\base\media'
$brand = [System.Drawing.Color]::FromArgb(255, 10, 89, 247)
$white = [System.Drawing.Color]::White

# foreground: transparent canvas, white mark
$fg = New-Object System.Drawing.Bitmap(1024, 1024, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($fg)
$g.Clear([System.Drawing.Color]::Transparent)
Add-Mark $g $white 1024.0
$g.Dispose()
Save-Png $fg (Join-Path $media 'foreground.png')

# background: solid brand colour only
$bg = New-Object System.Drawing.Bitmap(1024, 1024, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bg)
$g.Clear($brand)
$g.Dispose()
Save-Png $bg (Join-Path $media 'background.png')

# start window icon: brand mark on the white start window
$si = New-Object System.Drawing.Bitmap(216, 216, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($si)
$g.Clear([System.Drawing.Color]::Transparent)
Add-Mark $g $brand 216.0
$g.Dispose()
Save-Png $si (Join-Path $entryMedia 'startIcon.png')

# The module-level layered icon overrides AppScope; keep them identical or the
# launcher keeps showing the placeholder.
Copy-Item (Join-Path $media 'foreground.png') (Join-Path $entryMedia 'foreground.png') -Force
Copy-Item (Join-Path $media 'background.png') (Join-Path $entryMedia 'background.png') -Force

Get-ChildItem $media, $entryMedia -Filter *.png | ForEach-Object {
    $i = [System.Drawing.Image]::FromFile($_.FullName)
    "{0,-16} {1}x{2}  {3} bytes" -f $_.Name, $i.Width, $i.Height, $_.Length
    $i.Dispose()
}
