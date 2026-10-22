"""Título del vídeo resubido, para que no salga igual que el original.

Tres modos:
- "igual": el título original.
- "recuerdo": «Recuerdo · <título original>».
- "ia": uno nuevo inventado por agy (la IA que ya usa Valora) a partir del versículo del
  vídeo. Si agy no está o falla, se usa el de "recuerdo".
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

import editar

MODOS = ("igual", "recuerdo", "ia")
LARGO_MAXIMO = 100  # lo que admite YouTube


def buscar_agy() -> str | None:
    encontrado = shutil.which("agy")
    if encontrado:
        return encontrado
    local = Path(os.environ.get("LOCALAPPDATA", ""))
    for patron in ("Microsoft/WinGet/Links/agy.exe", "Microsoft/WinGet/Packages/Google.AntigravityCLI*/agy.exe",
                   "Valora/bin/agy.exe"):
        for ruta in local.glob(patron):
            return str(ruta)
    return None


def recuerdo(original: str) -> str:
    return f"Recuerdo · {original}"[:LARGO_MAXIMO]


def con_ia(original: str, descripcion: str) -> str:
    agy = buscar_agy()
    if not agy:
        raise RuntimeError("no está agy")
    frase, cita = editar.versiculo_de(descripcion)
    pedido = ("Inventa un título corto (máximo 70 caracteres) para un short de YouTube cristiano. "
              f"El vídeo original se titulaba «{original}»"
              + (f" y su versículo es «{frase}» ({cita})" if frase else "")
              + ". El título tiene que ser distinto del original, cercano y sin emojis; si hay cita, "
                "termina con ella. Responde solo con el título, sin comillas ni explicaciones.")
    r = subprocess.run([agy, "--output-format", "text"], input=pedido.encode("utf-8"),
                       capture_output=True, timeout=180)
    if r.returncode != 0:
        raise RuntimeError(f"agy ha fallado ({r.returncode})")
    # agy contesta a veces en la codificación de Windows en vez de UTF-8
    try:
        texto = r.stdout.decode("utf-8")
    except UnicodeDecodeError:
        texto = r.stdout.decode("cp1252", errors="replace")
    lineas = [l.strip() for l in texto.splitlines() if l.strip()]
    if not lineas:
        raise RuntimeError("agy no ha devuelto nada")
    nuevo = lineas[-1].strip(" \"'«»“”*#")
    nuevo = re.sub(r"\s+", " ", nuevo)
    if not nuevo or nuevo.lower() == original.lower():
        raise RuntimeError("agy ha devuelto el mismo título")
    return nuevo[:LARGO_MAXIMO]


def nuevo_titulo(modo: str, original: str, descripcion: str, al_fallar=None) -> str:
    if modo == "recuerdo":
        return recuerdo(original)
    if modo == "ia":
        try:
            return con_ia(original, descripcion)
        except Exception as error:
            if al_fallar:
                al_fallar(error)
            return recuerdo(original)
    return original[:LARGO_MAXIMO]
