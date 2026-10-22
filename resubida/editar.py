"""Rehace un vídeo descargado con la entrada y la salida animadas antes de resubirlo.

Parte de la plantilla de HyperFrames de plantilla-entrada-salida/ (la edición del
11 de julio de 2026): copia la plantilla a edicion/auto/<id>/, pone el vídeo, la
fecha, el versículo y la cita de ese vídeo y la duración de su clip, y la renderiza
con la CLI de HyperFrames. El resultado queda junto al original como <id>.editado.mp4
y se reutiliza si ya existe.

Uso suelto: python editar.py <id>
"""
from __future__ import annotations

import html
import json
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

BASE = Path(__file__).resolve().parent
PLANTILLA = BASE / "plantilla-entrada-salida"
TRABAJO = BASE / "edicion" / "auto"
HYPERFRAMES = "hyperframes@0.8.161"

# La entrada dura 3,4 s y el clip empieza a verse a los 2,6 s; la salida se abre 0,76 s
# antes de que acabe el clip y dura 5 s; el sonido baja en el último 1,46 s del clip.
INICIO_CLIP = 2.6
SOLAPE_SALIDA = 0.76
DURACION_SALIDA = 5.0
BAJADA_SONIDO = 1.46

MESES = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto",
         "septiembre", "octubre", "noviembre", "diciembre"]
# Caracteres invisibles de dirección de texto que traen las descripciones copiadas de apps de la Biblia.
INVISIBLES = re.compile(r"[​-‏‪-‮⁦-⁩﻿]")
PATRON_CITA = re.compile(r"((?:[1-3]\s*)?[A-ZÁÉÍÓÚÑ][a-záéíóúüñ]+(?:\s+(?:de\s+)?[A-ZÁÉÍÓÚÑa-záéíóúüñ]+)?\s+\d+:\d+(?:[-–]\d+)?)")


class ErrorEdicion(RuntimeError):
    pass


def fecha_de(info: dict) -> str:
    """El título del vídeo ya es la fecha («11 de julio de 2026»); si no, la de subida."""
    titulo = (info.get("title") or "").strip()
    if re.fullmatch(r"\d{1,2} de [a-záéíóú]+ de \d{4}", titulo, re.I):
        return titulo
    f = info.get("upload_date") or ""
    if len(f) == 8:
        return f"{int(f[6:])} de {MESES[int(f[4:6]) - 1]} de {f[:4]}"
    return titulo or "Maravillado estoy de ti"


def versiculo_de(descripcion: str) -> tuple[str, str]:
    """Saca de la descripción la primera frase del versículo y su cita («1 Crónicas 16:23»)."""
    texto = INVISIBLES.sub("", descripcion or "").strip()
    cita = ""
    m = PATRON_CITA.search(texto)
    if m:
        cita = re.sub(r"\s+", " ", m.group(1)).strip()
        texto = texto[:m.start()]
    texto = re.sub(r"\s+", " ", texto).strip(" \"“”«»'‘’")
    # Primera frase, sin los signos de apertura
    frase = re.split(r"(?<=[.!?;])\s", texto)[0].strip()
    frase = frase.strip(" ¡¿\"“”«»").rstrip(".!?;:,")
    palabras = frase.split()
    if len(palabras) > 11:
        # Se corta en una coma si la hay a tiempo; si no, en la palabra 10
        corte = next((i + 1 for i, p in enumerate(palabras[:11]) if p.endswith(",") and i >= 4), None)
        frase = " ".join(palabras[:corte]).rstrip(",") if corte else " ".join(palabras[:10]) + "…"
    return frase, cita


def lineas_verso(frase: str) -> tuple[str, int]:
    """HTML de las líneas del verso (palabra a palabra, para la animación) y su tamaño de letra."""
    if not frase:
        frase = "Maravillado estoy de ti"
    n = len(frase)
    tamaño = 112 if n <= 34 else 96 if n <= 56 else 80
    max_caracteres = int(900 / (tamaño * 0.47))
    lineas, actual = [], []
    for p in frase.split():
        if actual and len(" ".join(actual + [p])) > max_caracteres:
            lineas.append(actual)
            actual = []
        actual.append(p)
    if actual:
        lineas.append(actual)
    partes = []
    for linea in lineas:
        palabras = [f'<span class="word">{html.escape(p)}{" " if i < len(linea) - 1 else ""}</span>'
                    for i, p in enumerate(linea)]
        partes.append(f'<span class="line">{"".join(palabras)}</span>')
    return "\n              ".join(partes), tamaño


def medir(video: Path) -> tuple[float, int, int]:
    salida = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height:format=duration",
         "-of", "json", str(video)], capture_output=True, text=True, check=True).stdout
    d = json.loads(salida)
    s = d["streams"][0]
    return float(d["format"]["duration"]), int(s["width"]), int(s["height"])


def avance_render(linea: str) -> float | None:
    """Saca el porcentaje de una línea del render («45%» o «fotograma 120/300»), o None."""
    porcentaje = re.search(r"(\d{1,3}(?:\.\d+)?)\s*%", linea)
    if porcentaje:
        return min(100.0, float(porcentaje.group(1)))
    fotogramas = re.search(r"(\d+)\s*/\s*(\d+)", linea)
    if fotogramas and int(fotogramas.group(2)) > 0:
        return min(100.0, 100 * int(fotogramas.group(1)) / int(fotogramas.group(2)))
    return None


# Segundos de render por segundo de vídeo; se ajusta con cada render para estimar el avance
# cuando la CLI no da cifra.
ritmo = {"segundos_por_segundo": 6.0}


def editar(v: dict, al_avanzar=None) -> Path:
    """Devuelve el MP4 con entrada y salida de un vídeo descargado (el dict de subir.video_descargado).

    al_avanzar(porcentaje, texto) se llama mientras se monta, si se pasa.
    """
    original = Path(v["video"])
    destino = original.with_name(f"{v['id']}.editado.mp4")
    if destino.exists() and destino.stat().st_size > 0:
        return destino
    info = v.get("info") or {}
    duracion, ancho, alto = medir(original)
    duracion = round(duracion, 2)
    frase, cita = versiculo_de(info.get("description") or "")
    verso, tamaño = lineas_verso(frase)
    salida = round(INICIO_CLIP + duracion - SOLAPE_SALIDA, 2)
    valores = {
        "FECHA": html.escape(fecha_de(info)),
        "VERSO": verso,
        "TAMANO_VERSO": str(tamaño),
        "CITA": html.escape(cita),
        "CLIP": f"{duracion:g}",
        "BAJADA": f"{max(0.7, round(duracion - BAJADA_SONIDO, 2)):g}",
        "SALIDA": f"{salida:g}",
        "TOTAL": f"{round(salida + DURACION_SALIDA, 2):g}",
        # Vertical: llena la pantalla. Horizontal o cuadrado: entero, sin recortar.
        "AJUSTE": "cover" if alto / ancho >= 1.6 else "contain",
    }

    proyecto = TRABAJO / v["id"]
    if proyecto.exists():
        shutil.rmtree(proyecto)
    shutil.copytree(PLANTILLA, proyecto)
    for fichero in [proyecto / "index.html", *(proyecto / "compositions").glob("*.html")]:
        texto = fichero.read_text(encoding="utf-8")
        for clave, valor in valores.items():
            texto = texto.replace("{{" + clave + "}}", valor)
        if "{{" in texto:
            raise ErrorEdicion(f"queda un hueco sin rellenar en {fichero.name}")
        fichero.write_text(texto, encoding="utf-8", newline="\n")
    shutil.copy2(original, proyecto / "assets" / "clip.mp4")
    if al_avanzar:
        al_avanzar(0, "Preparando la plantilla de entrada y salida")

    temporal = destino.with_name(f"{v['id']}.editando.mp4")
    temporal.unlink(missing_ok=True)
    npx = shutil.which("npx.cmd") or shutil.which("npx") or "npx"
    total = float(valores["TOTAL"])
    inicio = time.monotonic()
    proceso = subprocess.Popen([npx, "--yes", HYPERFRAMES, "render", str(proyecto), "-o", str(temporal)],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8",
                               errors="replace", cwd=proyecto)
    ultimas: list[str] = []
    con_cifra = False

    def estimar() -> None:
        # Mientras la CLI no dé cifra, se estima por el tiempo que suele tardar (sin pasar del 95 %).
        while proceso.poll() is None:
            if al_avanzar and not con_cifra:
                al_avanzar(min(95.0, 100 * (time.monotonic() - inicio) / (total * ritmo["segundos_por_segundo"])),
                           f"Montando la entrada y la salida ({int(time.monotonic() - inicio)} s)")
            time.sleep(1)
    threading.Thread(target=estimar, daemon=True).start()
    for linea in proceso.stdout:  # en modo texto, los \r de las barras de progreso también cortan línea
        linea = linea.strip()
        if not linea:
            continue
        ultimas = (ultimas + [linea])[-3:]
        avance = avance_render(linea)
        if avance is not None and al_avanzar:
            con_cifra = True
            al_avanzar(avance, f"Montando la entrada y la salida ({int(time.monotonic() - inicio)} s)")
    proceso.wait()
    if proceso.returncode != 0 or not temporal.exists():
        raise ErrorEdicion("no se ha podido montar la entrada y salida: " + " | ".join(ultimas))
    ritmo["segundos_por_segundo"] = max(1.0, (time.monotonic() - inicio) / total)
    temporal.replace(destino)
    return destino


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    import subir
    for vid in sys.argv[1:]:
        v = subir.video_descargado(vid)
        if not v:
            print(f"{vid}: no está descargado")
            continue
        info = v["info"]
        print(vid, "|", fecha_de(info), "|", versiculo_de(info.get("description") or ""))
        print("  ->", editar(v))
