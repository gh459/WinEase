#Requires -Version 5.1
<#
.SYNOPSIS
    Builds src\WinEase.Launcher\app.ico from assets\branding\winease-icon.png.
.DESCRIPTION
    Makes the flat dark-grey background around the rounded tile transparent (flood fill from the four
    corners), crops to the tile, and writes an .ico with 16/20/24/32/40/48/64/128/256 px frames
    (BMP frames, the 256 px frame PNG-compressed). When the source PNG does not exist yet, -Placeholder
    draws a plain rounded tile with "WE" so the launcher still builds; replace it once the artwork is in.
.PARAMETER Source
    Source PNG (default assets\branding\winease-icon.png, 2048x2048).
.PARAMETER Destination
    Output .ico (default src\WinEase.Launcher\app.ico).
.PARAMETER Placeholder
    Draw a placeholder instead of reading -Source.
.EXAMPLE
    .\tools\New-WinEaseIcon.ps1
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$Destination,
    [switch]$Placeholder
)
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Source) { $Source = Join-Path -Path $repoRoot -ChildPath 'assets\branding\winease-icon.png' }
if (-not $Destination) { $Destination = Join-Path -Path $repoRoot -ChildPath 'src\WinEase.Launcher\app.ico' }

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;

public static class WinEaseIconBuilder
{
    public static readonly int[] Sizes = new int[] { 16, 20, 24, 32, 40, 48, 64, 128, 256 };

    // Clears every pixel connected to a corner whose colour is within 'tolerance' of that corner.
    public static Bitmap RemoveBackground(Bitmap src, int tolerance)
    {
        int w = src.Width, h = src.Height;
        Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(bmp)) { g.DrawImage(src, 0, 0, w, h); }
        BitmapData d = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        byte[] px = new byte[d.Stride * h];
        System.Runtime.InteropServices.Marshal.Copy(d.Scan0, px, 0, px.Length);
        bool[] seen = new bool[w * h];
        int[][] corners = new int[][] { new int[] { 0, 0 }, new int[] { w - 1, 0 }, new int[] { 0, h - 1 }, new int[] { w - 1, h - 1 } };
        foreach (int[] c in corners)
        {
            int o = c[1] * d.Stride + c[0] * 4;
            int b0 = px[o], g0 = px[o + 1], r0 = px[o + 2];
            Stack<int> st = new Stack<int>();
            st.Push(c[1] * w + c[0]);
            while (st.Count > 0)
            {
                int idx = st.Pop();
                if (seen[idx]) continue;
                int x = idx % w, y = idx / w;
                int p = y * d.Stride + x * 4;
                if (Math.Abs(px[p] - b0) > tolerance || Math.Abs(px[p + 1] - g0) > tolerance || Math.Abs(px[p + 2] - r0) > tolerance) continue;
                seen[idx] = true;
                px[p] = 0; px[p + 1] = 0; px[p + 2] = 0; px[p + 3] = 0;
                if (x > 0) st.Push(idx - 1);
                if (x < w - 1) st.Push(idx + 1);
                if (y > 0) st.Push(idx - w);
                if (y < h - 1) st.Push(idx + w);
            }
        }
        System.Runtime.InteropServices.Marshal.Copy(px, 0, d.Scan0, px.Length);
        bmp.UnlockBits(d);
        return bmp;
    }

    // Square crop around the non-transparent pixels with a small margin.
    public static Bitmap CropToContent(Bitmap src)
    {
        int w = src.Width, h = src.Height, minX = w, minY = h, maxX = -1, maxY = -1;
        BitmapData d = src.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        byte[] px = new byte[d.Stride * h];
        System.Runtime.InteropServices.Marshal.Copy(d.Scan0, px, 0, px.Length);
        src.UnlockBits(d);
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                if (px[y * d.Stride + x * 4 + 3] > 8)
                {
                    if (x < minX) minX = x; if (x > maxX) maxX = x;
                    if (y < minY) minY = y; if (y > maxY) maxY = y;
                }
        if (maxX < 0) return src;
        int side = Math.Max(maxX - minX + 1, maxY - minY + 1);
        int margin = Math.Max(1, side / 64);
        int full = side + margin * 2;
        Bitmap bmp = new Bitmap(full, full, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(bmp))
        {
            g.Clear(Color.Transparent);
            int cx = (minX + maxX + 1) / 2, cy = (minY + maxY + 1) / 2;
            g.DrawImage(src, new Rectangle(0, 0, full, full), new Rectangle(cx - full / 2, cy - full / 2, full, full), GraphicsUnit.Pixel);
        }
        return bmp;
    }

    public static Bitmap Resize(Bitmap src, int size)
    {
        Bitmap bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(bmp))
        {
            g.Clear(Color.Transparent);
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.SmoothingMode = SmoothingMode.HighQuality;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.CompositingQuality = CompositingQuality.HighQuality;
            g.DrawImage(src, new Rectangle(0, 0, size, size), new Rectangle(0, 0, src.Width, src.Height), GraphicsUnit.Pixel);
        }
        return bmp;
    }

    public static Bitmap DrawPlaceholder()
    {
        Bitmap bmp = new Bitmap(512, 512, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(bmp))
        {
            g.Clear(Color.Transparent);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            using (GraphicsPath path = new GraphicsPath())
            {
                int r = 96, s = 480, o = 16;
                path.AddArc(o, o, r, r, 180, 90);
                path.AddArc(o + s - r, o, r, r, 270, 90);
                path.AddArc(o + s - r, o + s - r, r, r, 0, 90);
                path.AddArc(o, o + s - r, r, r, 90, 90);
                path.CloseFigure();
                using (Brush b = new LinearGradientBrush(new Rectangle(0, 0, 512, 512), Color.FromArgb(0, 120, 212), Color.FromArgb(0, 70, 140), 55f))
                    g.FillPath(b, path);
            }
            using (Font f = new Font("Segoe UI", 190f, FontStyle.Bold, GraphicsUnit.Pixel))
            using (StringFormat sf = new StringFormat())
            {
                sf.Alignment = StringAlignment.Center; sf.LineAlignment = StringAlignment.Center;
                g.DrawString("WE", f, Brushes.White, new RectangleF(0, 0, 512, 512), sf);
            }
        }
        return bmp;
    }

    static byte[] PngBytes(Bitmap bmp)
    {
        using (MemoryStream ms = new MemoryStream()) { bmp.Save(ms, ImageFormat.Png); return ms.ToArray(); }
    }

    // BMP (DIB) frame: BITMAPINFOHEADER with doubled height, bottom-up BGRA pixels, 1-bit AND mask (all 0).
    static byte[] DibBytes(Bitmap bmp)
    {
        int s = bmp.Width;
        BitmapData d = bmp.LockBits(new Rectangle(0, 0, s, s), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        byte[] px = new byte[d.Stride * s];
        System.Runtime.InteropServices.Marshal.Copy(d.Scan0, px, 0, px.Length);
        bmp.UnlockBits(d);
        int maskStride = ((s + 31) / 32) * 4;
        using (MemoryStream ms = new MemoryStream())
        using (BinaryWriter w = new BinaryWriter(ms))
        {
            w.Write(40); w.Write(s); w.Write(s * 2); w.Write((short)1); w.Write((short)32);
            w.Write(0); w.Write(s * s * 4 + maskStride * s); w.Write(0); w.Write(0); w.Write(0); w.Write(0);
            for (int y = s - 1; y >= 0; y--) w.Write(px, y * d.Stride, s * 4);
            w.Write(new byte[maskStride * s]);
            return ms.ToArray();
        }
    }

    public static void WriteIco(Bitmap master, string path)
    {
        List<byte[]> frames = new List<byte[]>();
        foreach (int size in Sizes)
        {
            using (Bitmap b = Resize(master, size))
                frames.Add(size >= 256 ? PngBytes(b) : DibBytes(b));
        }
        using (FileStream fs = File.Create(path))
        using (BinaryWriter w = new BinaryWriter(fs))
        {
            w.Write((short)0); w.Write((short)1); w.Write((short)Sizes.Length);
            int offset = 6 + 16 * Sizes.Length;
            for (int i = 0; i < Sizes.Length; i++)
            {
                int s = Sizes[i];
                w.Write((byte)(s >= 256 ? 0 : s)); w.Write((byte)(s >= 256 ? 0 : s));
                w.Write((byte)0); w.Write((byte)0); w.Write((short)1); w.Write((short)32);
                w.Write(frames[i].Length); w.Write(offset);
                offset += frames[i].Length;
            }
            foreach (byte[] f in frames) w.Write(f);
        }
    }
}
'@

$destDir = Split-Path -Parent $Destination
if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

if ($Placeholder) {
    Write-Host 'Drawing the placeholder icon (artwork not supplied).'
    $master = [WinEaseIconBuilder]::DrawPlaceholder()
}
else {
    if (-not (Test-Path -LiteralPath $Source)) { throw "Source image not found: $Source (use -Placeholder until the artwork is added)" }
    $loaded = New-Object System.Drawing.Bitmap -ArgumentList $Source
    try {
        $clear = [WinEaseIconBuilder]::RemoveBackground($loaded, 14)
        $master = [WinEaseIconBuilder]::CropToContent($clear)
    }
    finally { $loaded.Dispose() }
}
try { [WinEaseIconBuilder]::WriteIco($master, $Destination) }
finally { $master.Dispose() }
Write-Host "Wrote $Destination"
