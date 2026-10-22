"""Web para elegir vídeos del canal y volver a subirlos.

Corre en este ordenador, que es donde están los vídeos descargados y el permiso de YouTube.
Con --publico abre además un túnel gratuito de Cloudflare para entrar desde fuera.

Uso:
    python web.py usuario NOMBRE CONTRASEÑA     # crea o cambia un usuario
    python web.py                               # arranca en http://localhost:8080
    python web.py --publico                     # y además publica una URL https://...trycloudflare.com
"""
import argparse
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta
from functools import wraps
from pathlib import Path

from flask import Flask, abort, g, jsonify, redirect, render_template, request, send_file, session, url_for
from itsdangerous import BadSignature, URLSafeTimedSerializer
from werkzeug.security import check_password_hash, generate_password_hash

import descargar
import editar
import inventario
import subir
import titulo

BASE = Path(__file__).resolve().parent
RUTA_CONFIG = BASE / "config.json"
RUTA_COLA = BASE / "cola.json"
RUTA_URL = BASE / "url_publica.txt"
RUTA_CANAL = BASE / "canal.json"
# Valora arranca su propia copia en otro puerto (RESUBIDA_PUERTO) para no chocar con esta.
PUERTO = int(os.environ.get("RESUBIDA_PUERTO", "8080"))

cerrojo = threading.Lock()
estado = {"trabajando": None, "pausa_hasta": None, "motivo_pausa": "", "actualizando": False,
          "conectando": False, "codigo": None, "url_verificacion": None, "error_conexion": "",
          "progreso": None}


def avance(vid: str):
    """Función que apunta en memoria el porcentaje y lo que se está haciendo con un vídeo."""
    def al_avanzar(porcentaje: float, texto: str) -> None:
        estado["progreso"] = {"id": vid, "porcentaje": round(max(0.0, min(100.0, porcentaje)), 1), "texto": texto}
    return al_avanzar


# ---------- configuración y usuarios ----------

def leer_config() -> dict:
    config = subir.leer_json(RUTA_CONFIG, {})
    if "clave" not in config:
        config["clave"] = secrets.token_hex(32)
        config.setdefault("usuarios", {})
        guardar_config(config)
    return config


def guardar_config(config: dict) -> None:
    RUTA_CONFIG.write_text(json.dumps(config, indent=2), encoding="utf-8")


def crear_usuario(nombre: str, contraseña: str) -> None:
    if len(contraseña) < 10:
        sys.exit("La contraseña tiene que tener al menos 10 caracteres.")
    config = leer_config()
    config["usuarios"][nombre] = generate_password_hash(contraseña)
    guardar_config(config)
    print(f"Usuario '{nombre}' guardado.")


# ---------- cola de resubida ----------

def leer_cola() -> list[dict]:
    return subir.leer_json(RUTA_COLA, [])


def guardar_cola(cola: list[dict]) -> None:
    RUTA_COLA.write_text(json.dumps(cola, ensure_ascii=False, indent=1), encoding="utf-8")


def cambiar(vid: str, **campos) -> None:
    with cerrojo:
        cola = leer_cola()
        for item in cola:
            if item["id"] == vid and item["estado"] not in ("hecho",):
                item.update(campos)
        guardar_cola(cola)


def pausar(motivo: str, horas: float = 1) -> None:
    estado["pausa_hasta"] = datetime.now() + timedelta(hours=horas)
    estado["motivo_pausa"] = motivo
    subir.log(f"Cola en pausa {horas} h: {motivo}")


conexion = {"youtube": None, "existentes": None, "token": None}


def limpiar(vid: str) -> None:
    """Ya subido, sobran la compilación y su carpeta de trabajo: en YouTube queda el vídeo tal cual.

    El vídeo original descargado se conserva.
    """
    v = subir.video_descargado(vid)
    if v:
        v["video"].with_name(f"{vid}.editado.mp4").unlink(missing_ok=True)
    trabajo = editar.TRABAJO / vid
    if trabajo.is_dir():
        shutil.rmtree(trabajo, ignore_errors=True)


def procesar_siguiente() -> bool:
    """Procesa el siguiente vídeo de la cola. Devuelve False si no había nada que hacer."""
    if estado["pausa_hasta"] and datetime.now() < estado["pausa_hasta"]:
        return False
    estado["pausa_hasta"], estado["motivo_pausa"] = None, ""

    with cerrojo:
        item = next((i for i in leer_cola() if i["estado"] in ("pendiente", "descargando", "editando", "subiendo", "limpiando")), None)
    if not item:
        return False
    vid = item["id"]
    subidos = subir.leer_json(subir.RUTA_SUBIDOS, {})
    if vid in subidos:
        cambiar(vid, estado="hecho", nuevo=subidos[vid]["nuevo"])
        return True
    if not subir.RUTA_TOKEN.exists():
        pausar("YouTube no está conectado: pulsa 'Conectar YouTube'", horas=0.02)
        return False
    # Si alguien ha conectado otra cuenta, se rehace la conexión
    token = subir.RUTA_TOKEN.stat().st_mtime
    if conexion["token"] != token:
        conexion.update(youtube=None, token=token)
    estado["trabajando"] = vid
    al_avanzar = avance(vid)
    try:
        v = subir.video_descargado(vid)
        if not v:
            cambiar(vid, estado="descargando")
            al_avanzar(0, "Esperando turno para bajar (YouTube pide unos segundos entre peticiones)")
            descargar.descargar_video(vid, al_avanzar=al_avanzar)
            v = subir.video_descargado(vid)
            if not v:
                raise RuntimeError("no se ha podido descargar")
        if item.get("entrada_salida"):
            # Se sube la versión con la entrada y la salida animadas (editar.py)
            cambiar(vid, estado="editando")
            al_avanzar(0, "Preparando la entrada y la salida")
            v = dict(v, video=editar.editar(v, al_avanzar))
            cambiar(vid, editado=True)
        modo_titulo = item.get("titulo_modo", "igual")
        if modo_titulo != "igual":
            if not item.get("titulo_nuevo"):
                if modo_titulo == "ia":
                    al_avanzar(0, "Pensando un título nuevo con IA")
                info = v.get("info") or {}
                nuevo_titulo = titulo.nuevo_titulo(
                    modo_titulo, info.get("title") or item["titulo"], info.get("description") or "",
                    al_fallar=lambda error: subir.log(f"  título con IA no disponible ({error}); se usa «Recuerdo»"))
                cambiar(vid, titulo_nuevo=nuevo_titulo)
                item["titulo_nuevo"] = nuevo_titulo
            v = dict(v, titulo=item["titulo_nuevo"])
        cambiar(vid, estado="subiendo")
        al_avanzar(0, "Conectando con YouTube")
        if conexion["youtube"] is None:
            conexion["youtube"] = subir.conectar()
            conexion["existentes"] = subir.playlists_del_canal(conexion["youtube"])
        listas_de, originales = subir.cargar_listas()
        nuevo = subir.subir_uno(conexion["youtube"], v, item["privacidad"], listas_de,
                                conexion["existentes"], originales, subidos, item.get("playlists"), al_avanzar)
        cambiar(vid, estado="limpiando", nuevo=nuevo)
        al_avanzar(100, "Borrando la compilación y los ficheros de trabajo")
        limpiar(vid)
        cambiar(vid, estado="hecho", nuevo=nuevo, error="")
    except subir.CuotaAgotada as motivo:
        cambiar(vid, estado="pendiente")
        pausar(f"cuota de YouTube agotada ({motivo}); se reintenta cada hora")
    except descargar.Bloqueado:
        cambiar(vid, estado="pendiente")
        pausar("YouTube ha bloqueado la descarga por exceso de peticiones", horas=2)
    except Exception as error:
        subir.log(f"Error con {vid}: {error}")
        cambiar(vid, estado="error", error=str(error)[:300])
        conexion["youtube"] = None  # por si el error era de la conexión
    finally:
        estado["trabajando"] = None
        estado["progreso"] = None
    return True


def trabajador() -> None:
    """Hilo que va sacando vídeos de la cola: descarga si hace falta y sube."""
    while True:
        try:
            if not procesar_siguiente():
                time.sleep(3)
        except Exception as error:  # que un fallo raro no mate el hilo
            subir.log(f"Error en el trabajador: {error}")
            time.sleep(10)


# ---------- web ----------

app = Flask(__name__)
app.config.update(SECRET_KEY=leer_config()["clave"], SESSION_COOKIE_HTTPONLY=True,
                  SESSION_COOKIE_SAMESITE="Lax", PERMANENT_SESSION_LIFETIME=timedelta(days=7))
fallos: dict[str, list] = {}
# Valora (la aplicación de escritorio) entra con un token en la cabecera Authorization en vez de
# con la cookie de sesión. Lleva el final del hash de la contraseña: si se cambia, deja de valer.
firmas = URLSafeTimedSerializer(app.config["SECRET_KEY"], salt="valora")
DIAS_TOKEN = 365  # quien entra desde Valora no tiene que volver a poner la contraseña en un año


def ip_cliente() -> str:
    return request.headers.get("CF-Connecting-IP") or request.remote_addr or "?"


def usuario_del_token() -> str | None:
    cabecera = request.headers.get("Authorization", "")
    if not cabecera.startswith("Bearer "):
        return None
    try:
        nombre, huella = firmas.loads(cabecera[7:], max_age=DIAS_TOKEN * 86400)
    except (BadSignature, ValueError):
        return None
    hash_guardado = leer_config()["usuarios"].get(nombre)
    return nombre if hash_guardado and hash_guardado[-12:] == huella else None


def con_login(vista):
    @wraps(vista)
    def envoltura(*a, **k):
        g.usuario = usuario_del_token()
        if g.usuario:
            # El token no lo manda el navegador solo, así que no hace falta comprobar CSRF.
            return vista(*a, **k)
        if not session.get("usuario"):
            if request.path.startswith("/api/"):
                abort(401)
            return redirect(url_for("login"))
        if request.method == "POST" and request.headers.get("X-CSRF") != session.get("csrf"):
            abort(403)
        g.usuario = session["usuario"]
        return vista(*a, **k)
    return envoltura


def comprobar_contraseña(nombre: str, contraseña: str) -> str:
    """Devuelve "" si es correcta o el mensaje de error. Bloquea 15 minutos tras 5 fallos por IP."""
    ip = ip_cliente()
    recientes = [t for t in fallos.get(ip, []) if t > time.time() - 900]
    if len(recientes) >= 5:
        return "Demasiados intentos. Prueba dentro de 15 minutos."
    hash_guardado = leer_config()["usuarios"].get(nombre)
    if hash_guardado and check_password_hash(hash_guardado, contraseña):
        fallos.pop(ip, None)
        return ""
    fallos[ip] = recientes + [time.time()]
    time.sleep(1)
    return "Usuario o contraseña incorrectos."


@app.route("/login", methods=["GET", "POST"])
def login():
    error = ""
    if request.method == "POST":
        nombre = request.form.get("usuario", "")
        error = comprobar_contraseña(nombre, request.form.get("contraseña", ""))
        if not error:
            session.clear()
            session.permanent = True
            session["usuario"] = nombre
            session["csrf"] = secrets.token_hex(16)
            return redirect(url_for("inicio"))
    return render_template("login.html", error=error)


@app.route("/api/entrar", methods=["POST"])
def api_entrar():
    """Login de Valora: devuelve un token que vale DIAS_TOKEN días."""
    datos = request.get_json(silent=True) or {}
    nombre = str(datos.get("usuario", ""))
    error = comprobar_contraseña(nombre, str(datos.get("contraseña", "")))
    if error:
        return jsonify({"error": error}), 401
    huella = leer_config()["usuarios"][nombre][-12:]
    return jsonify({"token": firmas.dumps([nombre, huella]), "usuario": nombre})


@app.route("/salir")
def salir():
    session.clear()
    return redirect(url_for("login"))


@app.route("/")
@con_login
def inicio():
    return render_template("index.html", usuario=session["usuario"], csrf=session["csrf"])


@app.route("/api/videos")
@con_login
def api_videos():
    catalogo = subir.leer_json(BASE / "catalogo.json", {"videos": [], "playlists": []})
    descargados = set()
    if descargar.RUTA_ARCHIVO.exists():
        descargados = {l.split()[-1] for l in descargar.RUTA_ARCHIVO.read_text().splitlines() if l.strip()}
    subidos = subir.leer_json(subir.RUTA_SUBIDOS, {})
    en_cola = {i["id"]: i["estado"] for i in leer_cola()}
    for v in catalogo["videos"]:
        v["descargado"] = v["id"] in descargados
        v["resubido"] = subidos.get(v["id"], {}).get("nuevo")
        v["cola"] = en_cola.get(v["id"])
    return jsonify(catalogo)


@app.route("/api/estado")
@con_login
def api_estado():
    cola = leer_cola()
    cuenta = {}
    for item in cola:
        cuenta[item["estado"]] = cuenta.get(item["estado"], 0) + 1
    pausa = estado["pausa_hasta"]
    return jsonify({
        "youtube_conectado": subir.RUTA_TOKEN.exists(),
        "credenciales": subir.RUTA_SECRETO.exists(),
        "client_id": id_cliente_visible(),
        "canal": subir.leer_json(RUTA_CANAL, {}).get("titulo") if subir.RUTA_TOKEN.exists() else None,
        "canal_id": subir.leer_json(RUTA_CANAL, {}).get("id") if subir.RUTA_TOKEN.exists() else None,
        "conectando": estado["conectando"],
        "codigo": estado["codigo"],
        "url_verificacion": estado["url_verificacion"],
        "error_conexion": estado["error_conexion"],
        "trabajando": estado["trabajando"],
        "progreso": estado["progreso"],
        "pausa_hasta": pausa.strftime("%H:%M") if pausa and pausa > datetime.now() else None,
        "motivo_pausa": estado["motivo_pausa"],
        "actualizando": estado["actualizando"],
        "cuenta": cuenta,
        "cola": cola[-300:],
        "descargados": descargar.contar_descargados(),
    })


@app.route("/api/cola", methods=["POST"])
@con_login
def api_cola_añadir():
    datos = request.get_json(force=True)
    privacidad = datos.get("privacidad", "private")
    entrada_salida = bool(datos.get("entrada_salida"))
    modo_titulo = datos.get("titulo", "igual")
    if modo_titulo not in titulo.MODOS:
        modo_titulo = "igual"
    if privacidad not in ("private", "unlisted", "public"):
        abort(400)
    ids = [i for i in datos.get("ids", []) if re.fullmatch(r"[\w-]{11}", i)]
    catalogo = {v["id"]: v for v in subir.leer_json(BASE / "catalogo.json", {"videos": []})["videos"]}
    subidos = subir.leer_json(subir.RUTA_SUBIDOS, {})
    with cerrojo:
        cola = leer_cola()
        activos = {i["id"] for i in cola if i["estado"] != "error"}
        cola = [i for i in cola if not (i["id"] in ids and i["estado"] == "error")]
        añadidos = 0
        for vid in ids:
            if vid in activos or vid in subidos or vid not in catalogo:
                continue
            cola.append({"id": vid, "titulo": catalogo[vid]["titulo"], "privacidad": privacidad,
                         "entrada_salida": entrada_salida, "titulo_modo": modo_titulo, "estado": "pendiente", "por": g.usuario,
                         "pedido": f"{datetime.now():%Y-%m-%d %H:%M}"})
            añadidos += 1
        guardar_cola(cola)
    subir.log(f"{g.usuario} añade {añadidos} vídeos a la cola ({privacidad}"
              f"{', con entrada y salida' if entrada_salida else ''}, título: {modo_titulo})")
    return jsonify({"añadidos": añadidos})


@app.route("/api/cola/quitar", methods=["POST"])
@con_login
def api_cola_quitar():
    ids = set(request.get_json(force=True).get("ids", []))
    with cerrojo:
        cola = [i for i in leer_cola()
                if not (i["id"] in ids and i["estado"] in ("pendiente", "error"))]
        guardar_cola(cola)
    return jsonify({"ok": True})


@app.route("/api/editado/<vid>")
@con_login
def api_editado(vid):
    """El vídeo ya rehecho con entrada y salida, para verlo antes o después de subirlo."""
    v = subir.video_descargado(vid) if re.fullmatch(r"[\w-]{6,20}", vid) else None
    ruta = v["video"].with_name(f"{vid}.editado.mp4") if v else None
    if not ruta or not ruta.exists():
        abort(404)
    return send_file(ruta, mimetype="video/mp4", download_name=ruta.name)


@app.route("/api/actualizar", methods=["POST"])
@con_login
def api_actualizar():
    if not estado["actualizando"]:
        def tarea():
            estado["actualizando"] = True
            try:
                inventario.generar()
            except Exception as error:
                subir.log(f"Error actualizando el listado: {error}")
            finally:
                estado["actualizando"] = False
        threading.Thread(target=tarea, daemon=True).start()
    return jsonify({"ok": True})


def guardar_canal() -> None:
    """Apunta en canal.json a qué canal se ha conectado, para enseñarlo en la web."""
    youtube = subir.conectar()
    canales = subir.llamar(youtube.channels().list(part="snippet", mine=True)).get("items", [])
    canal = {"titulo": canales[0]["snippet"]["title"], "id": canales[0]["id"]} if canales else \
        {"titulo": "(esta cuenta no tiene canal de YouTube)", "id": ""}
    RUTA_CANAL.write_text(json.dumps(canal, ensure_ascii=False), encoding="utf-8")
    subir.log(f"Canal conectado: {canal['titulo']} ({canal['id']})")


def id_cliente_visible() -> str | None:
    """El Client ID guardado, recortado: basta para reconocerlo sin enseñarlo entero."""
    try:
        client_id = subir.leer_secreto()["client_id"]
    except Exception:
        return None
    return client_id[:12] + "…" + client_id[-27:] if len(client_id) > 45 else client_id


@app.route("/api/credenciales", methods=["POST"])
@con_login
def api_credenciales():
    """Guarda el cliente OAuth de la API de YouTube (client_secret.json) desde la web o Valora."""
    datos = request.get_json(silent=True) or {}
    client_id = str(datos.get("client_id", "")).strip()
    client_secret = str(datos.get("client_secret", "")).strip()
    if not re.fullmatch(r"[\w.-]+\.apps\.googleusercontent\.com", client_id) or not client_secret:
        return jsonify({"error": "El Client ID tiene que acabar en .apps.googleusercontent.com "
                                 "y hace falta el Client secret."}), 400
    subir.RUTA_SECRETO.write_text(json.dumps({"installed": {
        "client_id": client_id, "client_secret": client_secret,
        "auth_uri": "https://accounts.google.com/o/oauth2/auth",
        "token_uri": "https://oauth2.googleapis.com/token"}}, indent=2), encoding="utf-8")
    estado["error_conexion"] = ""
    subir.log(f"{g.usuario} guarda las credenciales de la API ({client_id[:12]}…)")
    return jsonify({"ok": True, "client_id": id_cliente_visible()})


@app.route("/api/conectar", methods=["POST"])
@con_login
def api_conectar():
    """Login por código: quien pulsa entra con su Google desde su propio navegador."""
    if estado["conectando"] and estado["codigo"]:
        return jsonify({"ok": True})
    estado["error_conexion"] = ""
    try:
        datos = subir.iniciar_dispositivo()
    except Exception as error:
        estado["error_conexion"] = str(error)
        subir.log(f"No se ha podido conectar con YouTube: {error}")
        return jsonify({"ok": False, "error": str(error)})
    estado.update(conectando=True, codigo=datos["user_code"],
                  url_verificacion=datos.get("verification_url") or datos.get("verification_uri"))

    def tarea():
        try:
            subir.esperar_dispositivo(datos)
            conexion["youtube"] = None
            guardar_canal()
        except Exception as error:
            estado["error_conexion"] = str(error)
            subir.log(f"No se ha podido conectar con YouTube: {error}")
        finally:
            estado.update(conectando=False, codigo=None, url_verificacion=None)
    threading.Thread(target=tarea, daemon=True).start()
    return jsonify({"ok": True})


# ---------- arranque ----------

def abrir_tunel() -> None:
    """Lanza cloudflared y guarda la URL pública en url_publica.txt."""
    import shutil
    ejecutable = shutil.which("cloudflared") or r"C:\Program Files (x86)\cloudflared\cloudflared.exe"
    proceso = subprocess.Popen([ejecutable, "tunnel", "--no-autoupdate", "--url", f"http://localhost:{PUERTO}"],
                               stderr=subprocess.PIPE, stdout=subprocess.DEVNULL, text=True)

    def leer():
        for linea in proceso.stderr:
            encontrada = re.search(r"https://[\w-]+\.trycloudflare\.com", linea)
            if encontrada:
                RUTA_URL.write_text(encontrada.group(0), encoding="utf-8")
                subir.log(f"URL pública: {encontrada.group(0)}")
                threading.Thread(target=publicar_direccion, args=(encontrada.group(0),), daemon=True).start()
    threading.Thread(target=leer, daemon=True).start()


REPO_DIRECCION = "git@github-valora:rubencandeal-a11y/valora.git"
RAMA_DIRECCION = "direccion"


def publicar_direccion(url: str) -> None:
    """Deja la URL pública en la rama «direccion» del repo de Valora.

    Los Valora de otros PC la leen de ahí, así que no hay que pegarla a mano cada vez que
    cambia (trycloudflare da una nueva en cada arranque). Se usa una carpeta aparte para no
    tocar el código de Valora.
    """
    carpeta = BASE / ".direccion"
    try:
        carpeta.mkdir(exist_ok=True)
        def git(*args):
            subprocess.run(["git", *args], cwd=carpeta, check=True, capture_output=True, text=True)
        if not (carpeta / ".git").exists():
            git("init", "-q")
            git("config", "user.name", "web de resubida")
            git("config", "user.email", "web-resubida@localhost")
        (carpeta / "direccion.json").write_text(json.dumps({"url": url, "desde": f"{datetime.now():%Y-%m-%d %H:%M}"}),
                                                encoding="utf-8")
        git("add", "direccion.json")
        git("commit", "-q", "--allow-empty", "-m", f"Dirección de la web de resubida: {url}")
        git("push", "-q", "-f", REPO_DIRECCION, f"HEAD:{RAMA_DIRECCION}")
        subir.log(f"Dirección publicada para los Valora de otros PC: {url}")
    except Exception as error:
        detalle = getattr(error, "stderr", "") or error
        subir.log(f"No se ha podido publicar la dirección: {detalle}")


def refrescar_playlists() -> None:
    """Relee las playlists del canal (playlists.json). Si YouTube corta y vienen muchas menos
    que antes, se deja la versión anterior."""
    ruta = BASE / "playlists.json"
    anterior = ruta.read_text(encoding="utf-8") if ruta.exists() else "[]"
    descargar.guardar_playlists(descargar.CANAL_POR_DEFECTO, argparse.Namespace(cookies=None))
    antes, ahora = len(json.loads(anterior)), len(subir.leer_json(ruta, []))
    if ahora < antes * 0.9:
        ruta.write_text(anterior, encoding="utf-8")
        subir.log(f"Playlists: YouTube solo ha devuelto {ahora} de {antes}; se deja la lista anterior")


def refrescar_listado() -> None:
    """Vuelve a leer el canal al arrancar y cada 3 horas, para que salgan los vídeos nuevos.

    Las playlists, una vez al día y solo con la cola parada: son muchas peticiones y, junto a
    una descarga, YouTube puede bloquear por exceso.
    """
    ultima_playlists = 0.0
    while True:
        if not estado["actualizando"]:
            estado["actualizando"] = True
            try:
                if time.time() - ultima_playlists > 24 * 3600 and not estado["trabajando"]:
                    refrescar_playlists()
                    ultima_playlists = time.time()
                inventario.generar()
            except Exception as error:
                subir.log(f"Error actualizando el listado: {error}")
            finally:
                estado["actualizando"] = False
        time.sleep(3 * 3600)


def main() -> None:
    if len(sys.argv) == 4 and sys.argv[1] == "usuario":
        crear_usuario(sys.argv[2], sys.argv[3])
        return
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--publico", action="store_true", help="abre un túnel de Cloudflare")
    args = parser.parse_args()

    # Instalada por Valora en otro PC: empieza con los listados que vienen con el programa
    iniciales = BASE / "datos-iniciales"
    if iniciales.is_dir():
        for fichero in iniciales.glob("*.json"):
            if not (BASE / fichero.name).exists():
                shutil.copy2(fichero, BASE / fichero.name)

    if not leer_config()["usuarios"]:
        sys.exit("No hay usuarios. Crea uno: python web.py usuario NOMBRE CONTRASEÑA")
    if not (BASE / "catalogo.json").exists():
        inventario.generar()

    # Lo que quedó a medias al cerrar vuelve a la cola
    with cerrojo:
        cola = leer_cola()
        for item in cola:
            if item["estado"] in ("descargando", "editando", "subiendo", "limpiando"):
                item["estado"] = "pendiente"
        guardar_cola(cola)

    threading.Thread(target=trabajador, daemon=True).start()
    threading.Thread(target=refrescar_listado, daemon=True).start()
    if args.publico:
        abrir_tunel()

    from waitress import serve
    print(f"Web en http://localhost:{PUERTO}")
    serve(app, host="127.0.0.1", port=PUERTO, threads=8)


if __name__ == "__main__":
    main()
