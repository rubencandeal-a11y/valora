# Copia el programa de resubida de YouTube (Documents\youtube) a la carpeta resubida\ de este
# repo, para que se publique con Valora y los PC en modo servidor lo bajen solos.
# Solo código y los listados públicos del canal: nada de credenciales, cola ni vídeos.
$origen = Join-Path $env:USERPROFILE 'Documents\youtube'
$destino = Join-Path $PSScriptRoot 'resubida'
if (-not (Test-Path (Join-Path $origen 'web.py'))) { Write-Host '[AVISO] No está Documents\youtube: no se copia la resubida.'; exit 0 }

if (Test-Path $destino) { Remove-Item $destino -Recurse -Force }
New-Item -ItemType Directory -Force $destino | Out-Null
foreach ($f in 'web.py', 'subir.py', 'descargar.py', 'editar.py', 'inventario.py', 'titulo.py', 'requirements.txt') {
    Copy-Item (Join-Path $origen $f) $destino
}
foreach ($d in 'templates', 'static', 'plantilla-entrada-salida') {
    Copy-Item (Join-Path $origen $d) (Join-Path $destino $d) -Recurse
}
# Listados del canal para empezar sin tener que leerlo entero (solo se usan si faltan)
$iniciales = Join-Path $destino 'datos-iniciales'
New-Item -ItemType Directory -Force $iniciales | Out-Null
foreach ($f in 'catalogo.json', 'playlists.json', 'fechas.json') {
    $ruta = Join-Path $origen $f
    if (Test-Path $ruta) { Copy-Item $ruta $iniciales }
}
Write-Host '[OK] resubida copiada'
