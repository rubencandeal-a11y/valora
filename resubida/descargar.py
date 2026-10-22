"""Descarga todos los vídeos y shorts de un canal de YouTube con sus metadatos.

Por cada vídeo guarda en descargas/<fecha> - <titulo> [<id>]/:
  - el vídeo en la mejor calidad disponible (mp4)
  - <id>.info.json con título, descripción, tags, fecha... (sirve para volver a subirlo)
  - la miniatura (jpg) y la descripción (.description)

Además guarda playlists.json con qué vídeos hay en cada lista del canal
(las listas mensuales), para poder rehacerlas al volver a subir.

Los vídeos ya descargados se apuntan en archivo.txt y no se vuelven a bajar,
así que se puede cortar y relanzar cuando se quiera: sigue por donde iba.

Si YouTube bloquea por exceso de peticiones ("confirm you're not a bot") el script
para en el acto en vez de seguir insistiendo, que solo alarga el bloqueo.
Con --seguir espera y vuelve a intentarlo solo, hasta terminar.

Uso:
    python descargar.py                          # canal por defecto
    python descargar.py --seguir                 # si bloquea, espera 2 h y sigue
    python descargar.py --cookies chrome         # usa la sesión de YouTube del navegador
    python descargar.py --playlists              # vuelve a leer las playlists
    python descargar.py --canal https://www.youtube.com/@otrocanal
"""
import argparse
import json
import shutil
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

import yt_dlp

CANAL_POR_DEFECTO = "https://www.youtube.com/@maravilladoestoydeti"
BASE = Path(__file__).resolve().parent
DESTINO = BASE / "descargas"
RUTA_ARCHIVO = BASE / "archivo.txt"
RUTA_LOG = BASE / "descarga.log"

SEÑALES_DE_BLOQUEO = ("not a bot", "HTTP Error 429", "rate-limited", "rate limited")


class Bloqueado(Exception):
    pass


def log(mensaje: str) -> None:
    linea = f"{datetime.now():%Y-%m-%d %H:%M:%S} {mensaje}"
    print(linea, flush=True)
    with RUTA_LOG.open("a", encoding="utf-8") as f:
        f.write(linea + "\n")


class Registro:
    """Logger para yt-dlp: escribe lo importante y corta en cuanto YouTube bloquea."""

    def debug(self, msg: str) -> None:
        if msg.startswith("[download] Destination") or "has already been recorded" in msg:
            return
        if msg.startswith("[download]") and "%" in msg:
            return  # barra de progreso: demasiado ruido para el log
        print(msg, flush=True)

    def info(self, msg: str) -> None:
        print(msg, flush=True)

    def warning(self, msg: str) -> None:
        if any(s in msg for s in SEÑALES_DE_BLOQUEO):
            raise Bloqueado(msg)
        print(f"AVISO: {msg}", flush=True)

    def error(self, msg: str) -> None:
        if any(s in msg for s in SEÑALES_DE_BLOQUEO):
            raise Bloqueado(msg)
        log(msg)


def runtimes_js() -> dict:
    """YouTube necesita un intérprete de JavaScript para sacar todas las calidades."""
    disponibles = {}
    for nombre in ("deno", "node", "bun"):
        ruta = shutil.which(nombre)
        if ruta:
            disponibles[nombre] = {"path": ruta}
    return disponibles


def opciones_base(args) -> dict:
    opciones = {
        "logger": Registro(),
        "js_runtimes": runtimes_js(),
        "remote_components": ["ejs:github"],
        # Pausas para no parecer un robot: entre peticiones y entre vídeos
        "sleep_interval_requests": 1,
        "sleep_interval": 5,
        "max_sleep_interval": 15,
        "retries": 10,
        "fragment_retries": 10,
    }
    if args.cookies:
        opciones["cookiesfrombrowser"] = (args.cookies,)
    return opciones


def guardar_playlists(canal: str, args) -> None:
    """Guarda el contenido de cada playlist del canal en playlists.json."""
    plano = dict(opciones_base(args), extract_flat=True, ignoreerrors=True)
    with yt_dlp.YoutubeDL(plano) as ydl:
        listas = ydl.extract_info(canal + "/playlists", download=False) or {}
        resultado = []
        for lista in listas.get("entries") or []:
            info = ydl.extract_info(lista["url"], download=False) or {}
            resultado.append({
                "titulo": lista.get("title"),
                "id": info.get("id"),
                "descripcion": info.get("description"),
                "videos": [e["id"] for e in info.get("entries") or [] if e],
            })
    (BASE / "playlists.json").write_text(
        json.dumps(resultado, ensure_ascii=False, indent=2), encoding="utf-8")
    log(f"playlists.json: {len(resultado)} listas")


def descargar(canal: str, args, al_avanzar=None) -> int:
    """Descarga una URL (canal, playlist o vídeo). Devuelve el código de yt-dlp.

    al_avanzar(porcentaje, texto): para enseñar en qué va, si se pasa.
    """
    opciones = dict(
        opciones_base(args),
        format="bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo+bestaudio/best",
        merge_output_format="mp4",
        paths={"home": str(DESTINO)},
        outtmpl="%(upload_date>%Y-%m-%d)s - %(title).80B [%(id)s]/%(id)s.%(ext)s",
        download_archive=str(RUTA_ARCHIVO),
        writeinfojson=True,
        writethumbnail=True,
        writedescription=True,
        postprocessors=[{"key": "FFmpegThumbnailsConvertor", "format": "jpg"}],
        ignoreerrors=True,
    )
    if al_avanzar:
        # yt-dlp baja vídeo y audio por separado y luego los junta: cada parte va de 0 a 100.
        def al_bajar(d):
            if d.get("status") == "downloading":
                total = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
                hecho = d.get("downloaded_bytes") or 0
                parte = "el audio" if d.get("info_dict", {}).get("vcodec") == "none" else "el vídeo"
                if total:
                    al_avanzar(100 * hecho / total,
                               f"Bajando {parte} de YouTube: {hecho / 1024 / 1024:.1f} de {total / 1024 / 1024:.1f} MB")
            elif d.get("status") == "finished":
                al_avanzar(100, "Juntando vídeo y audio")
        opciones["progress_hooks"] = [al_bajar]
    # La raíz del canal incluye todas las pestañas: Vídeos, Shorts y Directos
    with yt_dlp.YoutubeDL(opciones) as ydl:
        return ydl.download([canal])


def descargar_video(vid: str, cookies: str | None = None, al_avanzar=None) -> None:
    """Descarga un solo vídeo con las mismas opciones. Lanza Bloqueado si YouTube corta."""
    descargar(f"https://www.youtube.com/watch?v={vid}", argparse.Namespace(cookies=cookies), al_avanzar)


def contar_descargados() -> int:
    if not RUTA_ARCHIVO.exists():
        return 0
    return sum(1 for l in RUTA_ARCHIVO.read_text().splitlines() if l.strip())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--canal", default=CANAL_POR_DEFECTO)
    parser.add_argument("--cookies", metavar="NAVEGADOR",
                        help="chrome, edge o firefox: usa su sesión de YouTube")
    parser.add_argument("--seguir", action="store_true",
                        help="si YouTube bloquea, espera y vuelve a intentarlo hasta terminar")
    parser.add_argument("--espera", type=float, default=2, help="horas de espera tras un bloqueo (por defecto 2)")
    parser.add_argument("--playlists", action="store_true", help="vuelve a leer las playlists del canal")
    args = parser.parse_args()

    canal = args.canal.rstrip("/")
    DESTINO.mkdir(exist_ok=True)
    if not runtimes_js():
        log("AVISO: no hay deno ni node en el PATH; puede que falten calidades de vídeo")

    while True:
        antes = contar_descargados()
        try:
            if args.playlists or not (BASE / "playlists.json").exists():
                guardar_playlists(canal, args)
                args.playlists = False
            errores = descargar(canal, args)
        except Bloqueado as motivo:
            log(f"YouTube ha bloqueado: {str(motivo)[:120]}")
            log(f"Bajados en esta tanda: {contar_descargados() - antes}. Total: {contar_descargados()}.")
            if not args.seguir:
                log("Relanzar dentro de unas horas, o con --cookies chrome, o con --seguir.")
                return 3
            vuelta = datetime.now() + timedelta(hours=args.espera)
            log(f"Esperando hasta las {vuelta:%H:%M} para seguir...")
            time.sleep(args.espera * 3600)
            continue
        log(f"Terminado. Total descargados: {contar_descargados()}. Vídeos en: {DESTINO}")
        return 1 if errores else 0


if __name__ == "__main__":
    sys.exit(main())
