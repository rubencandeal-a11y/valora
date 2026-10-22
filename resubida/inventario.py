"""Genera INVENTARIO.md con todo lo que hay en el canal.

Lee la lista pública del canal (vídeos y shorts), la cruza con playlists.json y con
archivo.txt, y saca por cada vídeo cuándo se subió y en qué lista está.

La fecha de subida sale del info.json si el vídeo ya está descargado. Si no, se pide
a YouTube y se guarda en fechas.json para no volver a pedirla.

Uso:
    python inventario.py
"""
import json
import re
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime
from pathlib import Path

import yt_dlp

CANAL = "https://www.youtube.com/@maravilladoestoydeti"
BASE = Path(__file__).resolve().parent
RUTA_FECHAS = BASE / "fechas.json"


def listar(pestana: str) -> list[dict]:
    with yt_dlp.YoutubeDL({"extract_flat": True, "quiet": True}) as ydl:
        info = ydl.extract_info(f"{CANAL}/{pestana}", download=False) or {}
    return [e for e in info.get("entries") or [] if e]


def duracion(segundos) -> str:
    if not segundos:
        return ""
    m, s = divmod(int(segundos), 60)
    return f"{m}:{s:02d}"


def formato_fecha(yyyymmdd: str) -> str:
    return f"{yyyymmdd[:4]}-{yyyymmdd[4:6]}-{yyyymmdd[6:]}" if yyyymmdd else ""


def fechas_descargadas() -> dict[str, str]:
    """Fecha de subida de los vídeos ya descargados, leída de su info.json."""
    fechas = {}
    for ruta in (BASE / "descargas").glob("*/*.info.json"):
        try:
            info = json.loads(ruta.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if info.get("upload_date"):
            fechas[info["id"]] = info["upload_date"]
    return fechas


MESES = {m: i for i, m in enumerate(["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto",
                                     "septiembre", "octubre", "noviembre", "diciembre"], 1)}


def fecha_del_titulo(titulo: str) -> str:
    """Los vídeos se titulan con su fecha («21 de octubre de 2026»): sirve de fecha mientras
    no se tenga la real. Devuelve AAAAMMDD o cadena vacía."""
    encontrada = re.search(r"(\d{1,2}) de ([a-záéíóú]+) de (\d{4})", (titulo or "").lower())
    if not encontrada or encontrada.group(2) not in MESES:
        return ""
    return f"{encontrada.group(3)}{MESES[encontrada.group(2)]:02d}{int(encontrada.group(1)):02d}"


def pedir_fechas(ids: list[str], fechas: dict[str, str]) -> None:
    """Pide a YouTube la fecha de subida de los ids que faltan y la guarda en fechas.json."""
    opciones = {"quiet": True, "no_warnings": True, "skip_download": True, "ignoreerrors": True}

    def una(vid: str):
        with yt_dlp.YoutubeDL(opciones) as ydl:
            info = ydl.extract_info(f"https://www.youtube.com/watch?v={vid}",
                                    download=False, process=False) or {}
        return vid, info.get("upload_date")

    with ThreadPoolExecutor(max_workers=4) as pool:
        for n, (vid, fecha) in enumerate(pool.map(una, ids), 1):
            if fecha:
                fechas[vid] = fecha
            if n % 50 == 0 or n == len(ids):
                RUTA_FECHAS.write_text(json.dumps(fechas, indent=0), encoding="utf-8")
                print(f"  fechas: {n}/{len(ids)}")


def main() -> None:
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--pedir-fechas", action="store_true",
                        help="pide a YouTube la fecha de los vídeos aún no descargados "
                             "(muchas peticiones: puede provocar un bloqueo temporal)")
    generar(parser.parse_args().pedir_fechas)


def generar(pedir: bool = False) -> int:
    """Escribe INVENTARIO.md y catalogo.json (lo que usa la web). Devuelve el total de vídeos."""
    videos = [dict(e, tipo="Vídeo") for e in listar("videos")]
    shorts = [dict(e, tipo="Short") for e in listar("shorts")]
    todos = videos + shorts
    # YouTube a veces corta la lista de la pestaña Shorts: lo que ya estaba en el catálogo
    # anterior no se quita por no venir esta vez.
    vistos = {e["id"] for e in todos}
    anterior = json.loads((BASE / "catalogo.json").read_text(encoding="utf-8")) if (BASE / "catalogo.json").exists() else {}
    for v in anterior.get("videos", []):
        if v["id"] not in vistos:
            todos.append({"id": v["id"], "title": v["titulo"], "tipo": v["tipo"], "url": v["url"],
                          "view_count": v.get("vistas") or 0, "duration": None})

    ruta_listas = BASE / "playlists.json"
    listas = json.loads(ruta_listas.read_text(encoding="utf-8")) if ruta_listas.exists() else []
    listas_de = defaultdict(list)
    for lista in listas:
        for vid in lista["videos"]:
            listas_de[vid].append(lista["titulo"])

    ruta_archivo = BASE / "archivo.txt"
    descargados = set()
    if ruta_archivo.exists():
        descargados = {l.split()[-1] for l in ruta_archivo.read_text().splitlines() if l.strip()}

    fechas = json.loads(RUTA_FECHAS.read_text(encoding="utf-8")) if RUTA_FECHAS.exists() else {}
    fechas.update(fechas_descargadas())
    faltan = [e["id"] for e in todos if e["id"] not in fechas]
    if faltan and pedir:
        print(f"Pidiendo fecha de subida de {len(faltan)} vídeos...")
        pedir_fechas(faltan, fechas)
    RUTA_FECHAS.write_text(json.dumps(fechas, indent=0), encoding="utf-8")
    # Sin fecha real, la del título (solo para ordenar y enseñar; no se guarda en fechas.json)
    for e in todos:
        if e["id"] not in fechas and fecha_del_titulo(e.get("title")):
            fechas[e["id"]] = fecha_del_titulo(e["title"])

    todos.sort(key=lambda e: fechas.get(e["id"], ""), reverse=True)
    vistas = sum(e.get("view_count") or 0 for e in todos)
    sin_lista = [e for e in todos if e["id"] not in listas_de]
    sin_fecha = [e for e in todos if e["id"] not in fechas]

    out = [
        "# Inventario del canal Maravillado estoy de ti",
        "",
        f"Generado el {date.today():%Y-%m-%d} con `python inventario.py`. Canal: {CANAL}",
        "",
        "## Resumen",
        "",
        "| Dato | Valor |",
        "|------|-------|",
        f"| Total | {len(todos)} |",
        f"| Vídeos normales | {len(videos)} |",
        f"| Shorts | {len(shorts)} |",
        f"| Playlists | {len(listas)} |",
        f"| Sin playlist | {len(sin_lista)} |",
        f"| Sin fecha de subida | {len(sin_fecha)} |",
        f"| Vistas totales | {vistas:,} |".replace(",", "."),
        f"| Descargados | {len(descargados & {e['id'] for e in todos})} de {len(todos)} |",
        "",
        "## Playlists",
        "",
        "| Playlist | Vídeos | Vistas |",
        "|----------|--------|--------|",
    ]
    por_lista = defaultdict(list)
    for e in todos:
        for nombre in listas_de.get(e["id"], ["Sin playlist"]):
            por_lista[nombre].append(e)
    for nombre in [l["titulo"] for l in listas] + ["Sin playlist"]:
        grupo = por_lista.get(nombre)
        if grupo:
            out.append(f"| {nombre} | {len(grupo)} | {sum(e.get('view_count') or 0 for e in grupo)} |")

    out += [
        "",
        "## Todos los vídeos",
        "",
        "Del más reciente al más antiguo.",
        "",
        "| Subido | Título | Playlist | Tipo | Duración | Vistas | Descargado | Enlace |",
        "|--------|--------|----------|------|----------|--------|------------|--------|",
    ]
    for e in todos:
        lista = ", ".join(listas_de.get(e["id"], [])) or "Sin playlist"
        ok = "sí" if e["id"] in descargados else ""
        out.append(f"| {formato_fecha(fechas.get(e['id'], ''))} | {e['title']} | {lista} | "
                   f"{e['tipo']} | {duracion(e.get('duration'))} | {e.get('view_count') or 0} | "
                   f"{ok} | {e['url']} |")

    (BASE / "INVENTARIO.md").write_text("\n".join(out) + "\n", encoding="utf-8")

    catalogo = {
        "generado": f"{datetime.now():%Y-%m-%d %H:%M}",
        "playlists": [l["titulo"] for l in listas],
        "videos": [{
            "id": e["id"],
            "titulo": e["title"],
            "tipo": e["tipo"],
            "fecha": formato_fecha(fechas.get(e["id"], "")),
            "playlists": listas_de.get(e["id"], []),
            "duracion": duracion(e.get("duration")),
            "vistas": e.get("view_count") or 0,
            "url": e["url"],
        } for e in todos],
    }
    (BASE / "catalogo.json").write_text(json.dumps(catalogo, ensure_ascii=False), encoding="utf-8")
    print(f"INVENTARIO.md y catalogo.json: {len(todos)} vídeos, {len(sin_fecha)} sin fecha")
    return len(todos)


if __name__ == "__main__":
    main()
