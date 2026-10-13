@echo off
rem Publica una versión nueva de Valora en GitHub. Todos los PC con Valora la
rem descargan solos la próxima vez que miren (al abrirse y cada 30 minutos).
rem Uso: PUBLICAR.bat "qué ha cambiado"
setlocal
cd /d "%~dp0"
set "MSG=%~1"
if "%MSG%"=="" set "MSG=Actualización de Valora"

call "%~dp0COMPILAR.bat" || exit /b 1

git add -A || exit /b 1
git diff --cached --quiet && (
  echo [AVISO] No hay cambios que publicar.
  exit /b 0
)
git commit -m "%MSG%" || exit /b 1
git push origin main || exit /b 1
echo.
echo [OK] Publicado. Los PC con Valora se actualizarán solos.
