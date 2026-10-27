Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies 'System.Drawing' -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

// Turns the authored artwork into HarmonyOS' two icon layers.
//
// HarmonyOS UX spec (why each step exists):
//   foreground.png  1024x1024, TRANSPARENT png, the mark only
//   background.png  1024x1024, ONE flat colour, no alpha at all
//   no self-applied rounded corners, no self-applied inner padding
// The authored artwork is a glass glyph on a dark plate; a background layer may
// not carry a gradient, so the glyph is keyed out and its volume (glow + contact
// shadow) is rebuilt on the transparent layer over a flat plate colour.
public static class IconGen
{
    const int N = 1024;

    static Bitmap Load32(string path)
    {
        using (var src = new Bitmap(path))
        {
            if (src.Width != N || src.Height != N)
                throw new ArgumentException("master must be " + N + "x" + N + ", got " + src.Width + "x" + src.Height);
            var b = new Bitmap(N, N, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(b))
            {
                g.CompositingMode = CompositingMode.SourceCopy;
                g.DrawImage(src, 0, 0, N, N);
            }
            return b;
        }
    }

    // The generator ships the glyph a few degrees off vertical. Undo it about the
    // canvas centre; the mark is inset far enough that the clipped corners only
    // ever lose plate, never ink.
    static Bitmap Level(Bitmap src, double degrees)
    {
        if (Math.Abs(degrees) < 0.01) return src;
        var b = new Bitmap(N, N, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(b))
        {
            g.Clear(Color.Transparent);
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.TranslateTransform(N / 2f, N / 2f);
            g.RotateTransform((float)degrees);
            g.TranslateTransform(-N / 2f, -N / 2f);
            g.DrawImage(src, 0, 0);
        }
        src.Dispose();
        return b;
    }

    static byte[] ReadRgb(Bitmap bmp, out byte[] rgb)
    {
        var d = bmp.LockBits(new Rectangle(0, 0, N, N), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        var px = new byte[N * N * 4];
        Marshal.Copy(d.Scan0, px, 0, px.Length);
        bmp.UnlockBits(d);
        rgb = px;
        return px;
    }

    // Key on the red channel: the plate is deep navy (R<=40), the glass is pale
    // (R>=140), and the halo between them becomes soft alpha — which is exactly
    // the spill we want to keep. Big flat areas of the counter stay transparent.
    static float[] Key(byte[] px)
    {
        var a = new float[N * N];
        for (int i = 0; i < N * N; i++)
        {
            int r = px[i * 4 + 2];
            float v = (r - 40f) / (130f - 40f);
            a[i] = v < 0 ? 0 : (v > 1 ? 1 : v);
        }
        // Morphological close (max then min, r=2): fills the pinholes the glass'
        // own dark specks punch into the bars, without touching the 130px counter.
        a = Morph(a, true, 2);
        a = Morph(a, false, 2);
        return a;
    }

    // separable box blur; three passes read as a serviceable gaussian
    static float[] BoxBlur(float[] src, int radius, int passes)
    {
        var a = (float[])src.Clone();
        var tmp = new float[N * N];
        for (int p = 0; p < passes; p++)
        {
            int r = Math.Max(1, radius);
            for (int y = 0; y < N; y++)
            {
                int row = y * N;
                double sum = 0; int cnt = 0;
                for (int x = 0; x <= r && x < N; x++) { sum += a[row + x]; cnt++; }
                for (int x = 0; x < N; x++)
                {
                    tmp[row + x] = (float)(sum / cnt);
                    int add = x + r + 1, rem = x - r;
                    if (add < N) { sum += a[row + add]; cnt++; }
                    if (rem >= 0) { sum -= a[row + rem]; cnt--; }
                }
            }
            for (int x = 0; x < N; x++)
            {
                double sum = 0; int cnt = 0;
                for (int y = 0; y <= r && y < N; y++) { sum += tmp[y * N + x]; cnt++; }
                for (int y = 0; y < N; y++)
                {
                    a[y * N + x] = (float)(sum / cnt);
                    int add = y + r + 1, rem = y - r;
                    if (add < N) { sum += tmp[add * N + x]; cnt++; }
                    if (rem >= 0) { sum -= tmp[rem * N + x]; cnt--; }
                }
            }
        }
        return a;
    }

    static float[] Morph(float[] src, bool dilate, int r)
    {
        var dst = new float[N * N];
        for (int y = 0; y < N; y++)
            for (int x = 0; x < N; x++)
            {
                float v = dilate ? 0f : 1f;
                for (int dy = -r; dy <= r; dy++)
                    for (int dx = -r; dx <= r; dx++)
                    {
                        int yy = y + dy, xx = x + dx;
                        if (yy < 0 || yy >= N || xx < 0 || xx >= N) continue;
                        float s = src[yy * N + xx];
                        if (dilate) { if (s > v) v = s; } else { if (s < v) v = s; }
                    }
                dst[y * N + x] = v;
            }
        return dst;
    }

    static void Bounds(float[] a, out int x0, out int y0, out int x1, out int y1)
    {
        x0 = N; y0 = N; x1 = -1; y1 = -1;
        for (int y = 0; y < N; y++)
            for (int x = 0; x < N; x++)
                if (a[y * N + x] > 0.5f)
                {
                    if (x < x0) x0 = x; if (x > x1) x1 = x;
                    if (y < y0) y0 = y; if (y > y1) y1 = y;
                }
        if (x1 < 0) throw new ArgumentException("no mark found: the key threshold and the artwork disagree");
    }

    // scale = the mark's long axis as a fraction of the canvas; squareFit maps
    // the bounds onto a SQUARE of that size, so the top/bottom and left/right
    // margins are identical instead of inheriting the glyph's own aspect.
    static Matrix Fit(int x0, int y0, int x1, int y1, int size, double scale, bool squareFit)
    {
        int w = x1 - x0 + 1, h = y1 - y0 + 1;
        double side = size * scale;
        double kx = squareFit ? side / w : side / Math.Max(w, h);
        double ky = squareFit ? side / h : side / Math.Max(w, h);
        var m = new Matrix();
        m.Scale((float)kx, (float)ky);
        // row-vector matrices: Append applies the scale first, then the translate
        m.Translate((float)(size / 2.0 - (x0 + w / 2.0) * kx), (float)(size / 2.0 - (y0 + h / 2.0) * ky), MatrixOrder.Append);
        return m;
    }

    static Bitmap FlatAlpha(float[] alpha, Color rgb)
    {
        var b = new Bitmap(N, N, PixelFormat.Format32bppArgb);
        var d = b.LockBits(new Rectangle(0, 0, N, N), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        var px = new byte[N * N * 4];
        for (int i = 0; i < N * N; i++)
        {
            px[i * 4 + 0] = rgb.B;
            px[i * 4 + 1] = rgb.G;
            px[i * 4 + 2] = rgb.R;
            px[i * 4 + 3] = (byte)Math.Max(0, Math.Min(255, (int)(alpha[i] * 255f)));
        }
        Marshal.Copy(px, 0, d.Scan0, px.Length);
        b.UnlockBits(d);
        return b;
    }

    // foreground: transparent, mark + its light only
    public static Bitmap Foreground(string masterPath, double tilt, double scale, bool squareFit, int shadowDy,
                                    int shadowBlur, double shadowAlpha, int glowBlur, double glowAlpha)
    {
        var upright = Level(Load32(masterPath), tilt);
        byte[] px;
        ReadRgb(upright, out px);
        var a = Key(px);
        int x0, y0, x1, y1;
        Bounds(a, out x0, out y0, out x1, out y1);

        var art = new Bitmap(N, N, PixelFormat.Format32bppArgb);
        var ad = art.LockBits(new Rectangle(0, 0, N, N), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        var ap = new byte[N * N * 4];
        for (int i = 0; i < N * N; i++)
        {
            ap[i * 4 + 0] = px[i * 4 + 0];
            ap[i * 4 + 1] = px[i * 4 + 1];
            ap[i * 4 + 2] = px[i * 4 + 2];
            ap[i * 4 + 3] = (byte)Math.Max(0, Math.Min(255, (int)(a[i] * 255f)));
        }
        Marshal.Copy(ap, 0, ad.Scan0, ap.Length);
        art.UnlockBits(ad);
        upright.Dispose();

        // contact shadow: the silhouette blurred and pushed down
        var shadowBlurArr = BoxBlur(a, shadowBlur, 3);
        var shadowVals = new float[N * N];
        for (int y = 0; y < N; y++)
            for (int x = 0; x < N; x++)
            {
                int sy = y - shadowDy;
                shadowVals[y * N + x] = (sy >= 0 && sy < N) ? shadowBlurArr[sy * N + x] * (float)shadowAlpha : 0f;
            }
        var shadow = FlatAlpha(shadowVals, Color.FromArgb(0, 12, 40));

        // light spill around the glass
        var glowVals = BoxBlur(a, glowBlur, 2);
        for (int i = 0; i < N * N; i++) glowVals[i] *= (float)glowAlpha;
        var glow = FlatAlpha(glowVals, Color.FromArgb(203, 230, 255));

        var mat = Fit(x0, y0, x1, y1, N, scale, squareFit);
        var fg = new Bitmap(N, N, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(fg))
        {
            g.Clear(Color.Transparent);
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.CompositingQuality = CompositingQuality.HighQuality;
            g.Transform = mat;
            g.DrawImage(glow, 0, 0, N, N);
            g.DrawImage(shadow, 0, 0, N, N);
            g.DrawImage(art, 0, 0, N, N);
        }
        art.Dispose(); shadow.Dispose(); glow.Dispose(); mat.Dispose();
        return fg;
    }

    public static Bitmap Solid(Color colour)
    {
        var b = new Bitmap(N, N, PixelFormat.Format24bppRgb);
        using (var g = Graphics.FromImage(b)) g.Clear(colour);
        return b;
    }

    // start window icon: the silhouette in one ink on the white start window
    public static Bitmap StartIcon(string masterPath, double tilt, double scale, bool squareFit, Color ink, int size)
    {
        var upright = Level(Load32(masterPath), tilt);
        byte[] px;
        ReadRgb(upright, out px);
        var a = Key(px);
        upright.Dispose();
        int x0, y0, x1, y1;
        Bounds(a, out x0, out y0, out x1, out y1);

        var mono = FlatAlpha(a, ink);
        var mat = Fit(x0, y0, x1, y1, N, scale, squareFit);
        var b = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(b))
        {
            g.Clear(Color.Transparent);
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            using (var m = mat.Clone())
            using (var frame = new Matrix((float)(size / (double)N), 0, 0, (float)(size / (double)N), 0, 0))
            {
                // fit into 1024 space first, then scale the canvas down to `size`
                m.Multiply(frame, MatrixOrder.Append);
                g.Transform = m;
            }
            g.DrawImage(mono, 0, 0, N, N);
        }
        mono.Dispose(); mat.Dispose();
        return b;
    }
}
'@

# ---------------------------------------------------------------------------
# 纸见 (ZhiJian) layered app icon pipeline.
#
# The mark is authored outside this script (an image model, prompted for a glass
# glyph on a FLAT plate) and kept at design/icon/app-icon-master.png. This
# script only adapts it to the HarmonyOS layering contract, so re-running it on
# the same master is deterministic.
#
# The plate can't be reused as the background layer (it carries a glow and the
# spec's background must be one flat colour with no alpha), so the glyph is
# keyed out, its volume rebuilt on the transparent layer, and the plate replaced
# by its own average ink.
#
# Scale is the mark's long axis as a fraction of the canvas, measured from its
# alpha bounds and centred on the canvas — this is what keeps the top/bottom and
# left/right margins equal instead of inheriting the generator's crop.
# ---------------------------------------------------------------------------

$MASTER = Join-Path $PSScriptRoot '..\design\icon\app-icon-master.png'
$TILT = -6.0         # deg; the artwork comes out rotated clockwise, upright it
$SCALE = 0.66        # mark long axis / canvas (leaves ~17% margin all round)
$SQUARE = $true      # fit the bounds to a square so horizontal and vertical margins match
$PLATE = [System.Drawing.Color]::FromArgb(255, 11, 79, 168)  # #0B4FA8, a mid royal blue: the master's plate is near-black, one notch too heavy on a home screen
$START_SCALE = 0.58

$root = Split-Path $PSScriptRoot -Parent
$appMedia = Join-Path $root 'AppScope\resources\base\media'
$entryMedia = Join-Path $root 'entry\src\main\resources\base\media'

$master = (Resolve-Path $MASTER).Path

$fg = [IconGen]::Foreground($master, $TILT, $SCALE, $SQUARE, 14, 10, 0.45, 16, 0.30)
$bg = [IconGen]::Solid($PLATE)
$start = [IconGen]::StartIcon($master, $TILT, $START_SCALE, $SQUARE, $PLATE, 216)

foreach ($dir in @($appMedia, $entryMedia)) {
    $fg.Save((Join-Path $dir 'foreground.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    $bg.Save((Join-Path $dir 'background.png'), [System.Drawing.Imaging.ImageFormat]::Png)
}
$start.Save((Join-Path $entryMedia 'startIcon.png'), [System.Drawing.Imaging.ImageFormat]::Png)

# --- contract checks: fail loudly rather than shipping a broken icon pack ----
$errors = @()
foreach ($dir in @($appMedia, $entryMedia)) {
    $f = [System.Drawing.Bitmap]::FromFile((Join-Path $dir 'foreground.png'))
    $b = [System.Drawing.Bitmap]::FromFile((Join-Path $dir 'background.png'))
    if ($f.Width -ne 1024 -or $f.Height -ne 1024) { $errors += "$dir foreground is not 1024x1024" }
    if ($f.GetPixel(0, 0).A -ne 0 -or $f.GetPixel(1023, 1023).A -ne 0) { $errors += "$dir foreground has opaque corners" }
    if ($f.GetPixel(512, 512).A -ne 0) { $errors += "$dir foreground centre is not transparent (the glyph counter must read through)" }
    if ($b.PixelFormat.ToString() -notmatch '24bpp|32bpp') { $errors += "$dir background has an unexpected format" }
    $first = $b.GetPixel(0, 0)
    foreach ($p in @(@(1023, 0), @(0, 1023), @(1023, 1023), @(512, 8), @(8, 512))) {
        $c = $b.GetPixel($p[0], $p[1])
        if ($c.ToArgb() -ne $first.ToArgb()) { $errors += "$dir background is not a single flat colour" }
    }
    if ($first.A -ne 255) { $errors += "$dir background is not fully opaque" }
    $f.Dispose(); $b.Dispose()
}

Get-ChildItem $appMedia, $entryMedia -Filter *.png | ForEach-Object {
    $i = [System.Drawing.Image]::FromFile($_.FullName)
    "{0,-46} {1}x{2}  {3} bytes" -f $_.FullName.Replace($root, ''), $i.Width, $i.Height, $_.Length
    $i.Dispose()
}

$fg.Dispose(); $bg.Dispose(); $start.Dispose()

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error $_ }
    exit 1
}
Write-Output 'icon layers OK'


