# Valora

Valora es una ventana tipo chat para trabajar con fotos, documentos y carpetas usando Google Antigravity CLI (`agy`). Está pensada para tasaciones: adjuntas las fotos de un inmueble, preguntas y Valora responde, revisa carpetas o genera informes en la carpeta de trabajo.

## Instalar

1. Descarga [InstalarValora.exe](https://github.com/rubencandeal-a11y/valora/raw/main/dist/InstalarValora.exe).
2. Ábrelo y acepta el permiso de administrador. El instalador pone `agy` (y Node.js si se marca), la ventana de Valora y los accesos directos.
3. Al abrirse Valora por primera vez, pide iniciar sesión con una cuenta de Google. Se pega el código que da Google y listo.

Windows puede avisar de que el programa es de un editor desconocido: "Más información" y "Ejecutar de todas formas".

## Actualizaciones

No hace falta volver a instalar. Valora mira este repositorio al abrirse y cada 20 segundos; si hay una versión nueva, la descarga, comprueba que es válida y la aplica sola en cuanto no la estás usando, sin perder la conversación ni lo que estabas escribiendo. `agy` se actualiza una vez al día con `agy update`.

Para publicar una versión nueva desde el PC de desarrollo:

```
PUBLICAR.bat "qué ha cambiado"
```

## YouTube

Arriba a la izquierda hay un selector Valora / YouTube. En YouTube, Valora enseña el listado del canal para elegir vídeos (sueltos o por playlist) y volver a subirlos. No sube nada ella misma: habla con la web de resubida que corre en el PC de Rubén (proyecto `Documents\youtube`), que es donde están los vídeos y el permiso de YouTube.

La primera vez pide la dirección de esa web, el usuario y la contraseña. Guarda un token cifrado para el usuario de Windows que vale 30 días; la contraseña no se guarda.

## Qué guarda y dónde

| Qué | Dónde |
|---|---|
| Sesión de Google | Administrador de credenciales de Windows (`gemini:antigravity`). Se borra con "Cerrar sesión" o `cmdkey /delete:gemini:antigravity`. |
| Conversaciones de Valora | `%LOCALAPPDATA%\Valora\conversaciones` (se pueden borrar desde la barra lateral) |
| Ajustes | `%LOCALAPPDATA%\Valora\config.json` |
| Fotos adjuntas | `<carpeta de trabajo>\entrada` |

## Estructura

- `Valora.ps1`: la ventana (PowerShell + WPF). Es lo que se actualiza solo.
- `src\Instalador.cs`: el asistente de instalación, se compila con el `csc.exe` que trae Windows.
- `src\crear-icono.ps1`: genera `valora.ico`.
- `COMPILAR.bat`: genera `dist\InstalarValora.exe`.
- `PUBLICAR.bat`: compila, hace commit y sube a GitHub.
