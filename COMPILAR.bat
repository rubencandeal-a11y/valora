@echo off
rem Genera dist\InstalarValora.exe a partir de Valora.ps1 y src\.
rem Uso: doble clic. Solo necesita el .NET Framework que trae Windows.
setlocal
cd /d "%~dp0"
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" (
  echo [ERROR] No encuentro csc.exe en %CSC%
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "src\crear-icono.ps1" || exit /b 1
if not exist dist mkdir dist
"%CSC%" -nologo -codepage:65001 -target:winexe -out:dist\InstalarValora.exe ^
  -win32manifest:src\app.manifest -win32icon:src\valora.ico ^
  -resource:Valora.ps1,Valora.ps1 -resource:src\valora.ico,valora.ico ^
  -r:System.Windows.Forms.dll -r:System.Drawing.dll src\Instalador.cs || exit /b 1
echo [OK] dist\InstalarValora.exe
