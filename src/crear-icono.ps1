# Genera valora.ico (256, 48, 32 y 16 px): cuadrado redondeado oscuro con una "V" blanca.
param([string]$Salida = (Join-Path $PSScriptRoot 'valora.ico'))
Add-Type -AssemblyName System.Drawing

function New-Png([int]$tam) {
    $bmp = New-Object System.Drawing.Bitmap($tam, $tam)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([System.Drawing.Color]::Transparent)

    $r = [Math]::Max(2, [int]($tam * 0.22))
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $w = $tam - 1
    $path.AddArc(0, 0, $r * 2, $r * 2, 180, 90)
    $path.AddArc($w - $r * 2, 0, $r * 2, $r * 2, 270, 90)
    $path.AddArc($w - $r * 2, $w - $r * 2, $r * 2, $r * 2, 0, 90)
    $path.AddArc(0, $w - $r * 2, $r * 2, $r * 2, 90, 90)
    $path.CloseFigure()
    $fondo = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.Point(0, 0)), (New-Object System.Drawing.Point($tam, $tam)),
        [System.Drawing.Color]::FromArgb(255, 46, 125, 90), [System.Drawing.Color]::FromArgb(255, 18, 60, 44))
    $g.FillPath($fondo, $path)

    $fuente = New-Object System.Drawing.Font('Segoe UI', [single]($tam * 0.62), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $formato = New-Object System.Drawing.StringFormat
    $formato.Alignment = 'Center'; $formato.LineAlignment = 'Center'
    $rect = New-Object System.Drawing.RectangleF(0, ($tam * 0.03), $tam, $tam)
    $g.DrawString('V', $fuente, [System.Drawing.Brushes]::White, $rect, $formato)
    $g.Dispose()

    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return ,$ms.ToArray()
}

$tamanos = 256, 48, 32, 16
$pngs = @(); foreach ($t in $tamanos) { $pngs += ,(New-Png $t) }

$out = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($out)
$bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$tamanos.Count)
$offset = 6 + 16 * $tamanos.Count
for ($i = 0; $i -lt $tamanos.Count; $i++) {
    $t = $tamanos[$i]; $d = $pngs[$i]
    $bw.Write([byte]($t % 256)); $bw.Write([byte]($t % 256))
    $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([UInt16]1); $bw.Write([UInt16]32)
    $bw.Write([UInt32]$d.Length); $bw.Write([UInt32]$offset)
    $offset += $d.Length
}
foreach ($d in $pngs) { $bw.Write($d) }
$bw.Flush()
[System.IO.File]::WriteAllBytes($Salida, $out.ToArray())
"Icono creado: $Salida"
