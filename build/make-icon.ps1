param([string]$Out = (Join-Path $PSScriptRoot 'hub.ico'))
# Dibuja el logo "Hexagono" (igual que en la UI) y arma un .ico con varios tamanos (PNG dentro del ICO)
Add-Type -AssemblyName System.Drawing

function New-Frame([int]$size) {
    $bmp = New-Object Drawing.Bitmap($size, $size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([Drawing.Color]::Transparent)
    $k = $size / 64.0
    $orange = [Drawing.Color]::FromArgb(255, 255, 168, 38)

    # fondo: cuadro redondeado oscuro
    $r = 14 * $k; $d = 2 * $r
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $d, $d, 180, 90); $path.AddArc($size - $d - 1, 0, $d, $d, 270, 90)
    $path.AddArc($size - $d - 1, $size - $d - 1, $d, $d, 0, 90); $path.AddArc(0, $size - $d - 1, $d, $d, 90, 90)
    $path.CloseFigure()
    $g.FillPath((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 20, 23, 28))), $path)

    $w = [single]([math]::Max(1.2, 3.6 * $k))
    $pen = New-Object Drawing.Pen($orange, $w)
    $pen.LineJoin = 'Round'; $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    # hexagono (mismo trazado que el SVG, reducido para que respire dentro del cuadro)
    $c = 32 * $k; $s = 0.78
    function P($x, $y) { New-Object Drawing.PointF([single]($c + ($x - 32) * $k * $s), [single]($c + ($y - 32) * $k * $s)) }
    $hex = @((P 32 4), (P 56 18), (P 56 46), (P 32 60), (P 8 46), (P 8 18))
    $g.DrawPolygon($pen, [Drawing.PointF[]]$hex)
    $rad = 8 * $k * $s
    $g.DrawEllipse($pen, [single]($c - $rad), [single]($c - $rad), [single](2 * $rad), [single](2 * $rad))
    foreach ($seg in @(@(32, 13, 32, 24), @(32, 40, 32, 51), @(13, 32, 24, 32), @(40, 32, 51, 32))) {
        $a = P $seg[0] $seg[1]; $b = P $seg[2] $seg[3]
        $g.DrawLine($pen, $a, $b)
    }
    $g.Dispose()
    $ms = New-Object IO.MemoryStream
    $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return , $ms.ToArray()
}

$sizes = 16, 24, 32, 48, 64, 128, 256
$frames = foreach ($sz in $sizes) { , (New-Frame $sz) }
$fs = [IO.File]::Create($Out)
$bw = New-Object IO.BinaryWriter($fs)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $sz = $sizes[$i]; $len = $frames[$i].Length
    $dim = if ($sz -ge 256) { 0 } else { $sz }
    $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$len); $bw.Write([uint32]$offset)
    $offset += $len
}
foreach ($f in $frames) { $bw.Write($f) }
$bw.Close(); $fs.Close()
"icono: $Out ($((Get-Item $Out).Length) bytes, tamanos: $($sizes -join ','))"
