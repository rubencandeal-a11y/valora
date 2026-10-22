"""Vuelve a subir al canal los vídeos descargados en descargas/.

Por cada carpeta, del vídeo más antiguo al más reciente:
  1. Sube el mp4 con el título, descripción, tags y categoría de su info.json.
  2. Pone la miniatura.
  3. Lo mete en la misma playlist que tenía (según playlists.json). Si en el canal ya hay
     una playlist con ese nombre la usa; si no, la crea.
  4. Apunta en subidos.json el id original y el nuevo.

Cuando YouTube corta por cuota (quotaExceeded o uploadLimitExceeded) se para y guarda.
Al relanzarlo sigue por donde iba, sin repetir nada de lo ya subido.

Necesita client_secret.json (credenciales OAuth de escritorio de Google Cloud) en esta
carpeta. La primera vez abre el navegador para entrar con la cuenta del canal y guarda
el permiso en token.json.

Uso:
    python subir.py --prueba                 # enseña qué subiría, sin conectar
    python subir.py                          # sube como privados
    python subir.py --privacidad public
    python subir.py --limite 10              # como mucho 10 en esta ejecución
"""
import argparse
import json
import sys
import time
from datetime import datetime
from pathlib import Path

BASE = Path(__file__).resolve().parent
DESCARGAS = BASE / "descargas"
RUTA_SUBIDOS = BASE / "subidos.json"
RUTA_TOKEN = BASE / "token.json"
RUTA_SECRETO = BASE / "client_secret.json"
RUTA_LOG = BASE / "subida.log"

PERMISOS = ["https://www.googleapis.com/auth/youtube"]

# yt-dlp guarda la categoría por nombre; la API la quiere por id
CATEGORIAS = {
    "Film & Animation": "1", "Autos & Vehicles": "2", "Music": "10",
    "Pets & Animals": "15", "Sports": "17", "Travel & Events": "19", "Gaming": "20",
    "People & Blogs": "22", "Comedy": "23", "Entertainment": "24", "News & Politics": "25",
    "Howto & Style": "26", "Education": "27", "Science & Technology": "28",
    "Nonprofits & Activism": "29",
}
CATEGORIA_POR_DEFECTO = "22"

ERRORES_DE_CUOTA = {"quotaExceeded", "uploadLimitExceeded", "rateLimitExceeded",
                    "dailyLimitExceeded"}


class CuotaAgotada(Exception):
    pass


def log(mensaje: str) -> None:
    linea = f"{datetime.now():%Y-%m-%d %H:%M:%S} {mensaje}"
    print(linea)
    with RUTA_LOG.open("a", encoding="utf-8") as f:
        f.write(linea + "\n")


def leer_json(ruta: Path, defecto):
    return json.loads(ruta.read_text(encoding="utf-8")) if ruta.exists() else defecto


def pendientes(subidos: dict) -> list[dict]:
    """Vídeos descargados que aún no se han subido, del más antiguo al más reciente."""
    lista = []
    for ruta_info in DESCARGAS.glob("*/*.info.json"):
        carpeta = ruta_info.parent
        info = leer_json(ruta_info, {})
        vid = info.get("id")
        mp4 = carpeta / f"{vid}.mp4"
        if not vid or vid in subidos or not mp4.exists():
            continue
        lista.append({
            "id": vid,
            "info": info,
            "video": mp4,
            "miniatura": next(iter(carpeta.glob(f"{vid}.jpg")), None),
        })
    lista.sort(key=lambda v: (v["info"].get("upload_date") or "", v["id"]))
    return lista


def conectar():
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials
    from google_auth_oauthlib.flow import InstalledAppFlow
    from googleapiclient.discovery import build

    credenciales = None
    if RUTA_TOKEN.exists():
        credenciales = Credentials.from_authorized_user_file(str(RUTA_TOKEN), PERMISOS)
    if not credenciales or not credenciales.valid:
        if credenciales and credenciales.expired and credenciales.refresh_token:
            credenciales.refresh(Request())
        else:
            if not RUTA_SECRETO.exists():
                sys.exit(f"Falta {RUTA_SECRETO.name}. Ver IDEAS.md, apartado 'Lo que hay que preparar'.")
            flujo = InstalledAppFlow.from_client_secrets_file(str(RUTA_SECRETO), PERMISOS)
            credenciales = flujo.run_local_server(port=0)
        RUTA_TOKEN.write_text(credenciales.to_json(), encoding="utf-8")
    return build("youtube", "v3", credentials=credenciales)


class SinCredenciales(Exception):
    pass


def leer_secreto() -> dict:
    """client_id y client_secret de client_secret.json (vale para cliente de escritorio o de TV)."""
    if not RUTA_SECRETO.exists():
        raise SinCredenciales(f"Falta {RUTA_SECRETO.name} en la carpeta del proyecto (ver IDEAS.md).")
    datos = leer_json(RUTA_SECRETO, {})
    secreto = datos.get("installed") or datos.get("web") or datos
    if "client_id" not in secreto:
        raise SinCredenciales(f"{RUTA_SECRETO.name} no tiene client_id.")
    return secreto


def iniciar_dispositivo() -> dict:
    """Empieza el login por código (como en las teles): sirve desde cualquier navegador.

    Devuelve user_code y verification_url para enseñar al usuario, y device_code para esperar.
    El cliente OAuth tiene que ser de tipo "TV y dispositivos de entrada limitada".
    """
    import requests
    secreto = leer_secreto()
    r = requests.post("https://oauth2.googleapis.com/device/code", timeout=30,
                      data={"client_id": secreto["client_id"], "scope": " ".join(PERMISOS)})
    if not r.ok:
        raise SinCredenciales(f"Google no acepta el cliente: {r.text[:200]}")
    return r.json()


def esperar_dispositivo(datos: dict) -> None:
    """Espera a que el usuario apruebe el código y guarda token.json."""
    import time

    import requests
    secreto = leer_secreto()
    fin = time.time() + datos.get("expires_in", 1800)
    intervalo = datos.get("interval", 5)
    while time.time() < fin:
        time.sleep(intervalo)
        r = requests.post("https://oauth2.googleapis.com/token", timeout=30, data={
            "client_id": secreto["client_id"], "client_secret": secreto.get("client_secret", ""),
            "device_code": datos["device_code"],
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"})
        respuesta = r.json()
        error = respuesta.get("error")
        if error == "authorization_pending":
            continue
        if error == "slow_down":
            intervalo += 5
            continue
        if error:
            raise SinCredenciales(f"Login cancelado o rechazado: {error}")
        RUTA_TOKEN.write_text(json.dumps({
            "token": respuesta["access_token"],
            "refresh_token": respuesta.get("refresh_token"),
            "token_uri": "https://oauth2.googleapis.com/token",
            "client_id": secreto["client_id"],
            "client_secret": secreto.get("client_secret", ""),
            "scopes": PERMISOS,
        }), encoding="utf-8")
        log("YouTube conectado con login por código")
        return
    raise SinCredenciales("El código ha caducado sin que nadie entrara.")


def motivo_error(error) -> str:
    try:
        return json.loads(error.content)["error"]["errors"][0]["reason"]
    except (ValueError, KeyError, IndexError, TypeError):
        return ""


def llamar(peticion):
    """Ejecuta una petición de la API y convierte los cortes de cuota en CuotaAgotada."""
    from googleapiclient.errors import HttpError
    try:
        return peticion.execute()
    except HttpError as error:
        if motivo_error(error) in ERRORES_DE_CUOTA:
            raise CuotaAgotada(motivo_error(error)) from error
        raise


def playlists_del_canal(youtube) -> dict[str, str]:
    """Nombre -> id de las playlists que ya tiene el canal."""
    resultado, pagina = {}, None
    while True:
        respuesta = llamar(youtube.playlists().list(
            part="snippet", mine=True, maxResults=50, pageToken=pagina))
        for p in respuesta.get("items", []):
            resultado.setdefault(p["snippet"]["title"], p["id"])
        pagina = respuesta.get("nextPageToken")
        if not pagina:
            return resultado


def id_playlist(youtube, nombre: str, existentes: dict, originales: dict) -> str:
    if nombre not in existentes:
        descripcion = (originales.get(nombre) or {}).get("descripcion") or ""
        creada = llamar(youtube.playlists().insert(part="snippet,status", body={
            "snippet": {"title": nombre, "description": descripcion},
            "status": {"privacyStatus": "public"},
        }))
        existentes[nombre] = creada["id"]
        log(f"  playlist creada: {nombre}")
    return existentes[nombre]


def subir_video(youtube, v: dict, privacidad: str, al_avanzar=None) -> str:
    from googleapiclient.http import MediaFileUpload

    info = v["info"]
    categoria = CATEGORIAS.get((info.get("categories") or [""])[0], CATEGORIA_POR_DEFECTO)
    cuerpo = {
        "snippet": {
            "title": (v.get("titulo") or info.get("title") or v["id"])[:100],
            "description": (info.get("description") or "")[:5000],
            "tags": info.get("tags") or [],
            "categoryId": categoria,
        },
        "status": {"privacyStatus": privacidad, "selfDeclaredMadeForKids": False},
    }
    if info.get("upload_date"):
        fecha = info["upload_date"]
        cuerpo["recordingDetails"] = {"recordingDate": f"{fecha[:4]}-{fecha[4:6]}-{fecha[6:]}T00:00:00Z"}

    # Trozos de 2 MB: el avance se ve moverse también en los shorts, que pesan poco
    media = MediaFileUpload(str(v["video"]), chunksize=2 * 1024 * 1024, resumable=True,
                            mimetype="video/mp4")
    total_mb = Path(v["video"]).stat().st_size / 1024 / 1024
    if al_avanzar:
        al_avanzar(0, f"Subiendo a YouTube: 0 de {total_mb:.1f} MB")
    peticion = youtube.videos().insert(part=",".join(cuerpo), body=cuerpo, media_body=media)

    from googleapiclient.errors import HttpError
    respuesta = None
    while respuesta is None:
        try:
            avance, respuesta = peticion.next_chunk()
            if avance and al_avanzar:
                al_avanzar(100 * avance.progress(),
                           f"Subiendo a YouTube: {avance.resumable_progress / 1024 / 1024:.1f} de {total_mb:.1f} MB")
        except HttpError as error:
            if motivo_error(error) in ERRORES_DE_CUOTA:
                raise CuotaAgotada(motivo_error(error)) from error
            raise
    return respuesta["id"]


def cargar_listas() -> tuple[dict, dict]:
    """(id de vídeo -> nombres de sus playlists, nombre -> playlist original)."""
    listas = leer_json(BASE / "playlists.json", [])
    listas_de = {}
    for lista in listas:
        for vid in lista["videos"]:
            listas_de.setdefault(vid, []).append(lista["titulo"])
    return listas_de, {l["titulo"]: l for l in listas}


def video_descargado(vid: str) -> dict | None:
    """Datos de un vídeo ya descargado, en el formato de pendientes(), o None."""
    for ruta_info in DESCARGAS.glob(f"*[[]{vid}[]]/{vid}.info.json"):
        mp4 = ruta_info.parent / f"{vid}.mp4"
        if mp4.exists():
            return {"id": vid, "info": leer_json(ruta_info, {}), "video": mp4,
                    "miniatura": next(iter(ruta_info.parent.glob(f"{vid}.jpg")), None)}
    return None


def subir_uno(youtube, v: dict, privacidad: str, listas_de: dict, existentes: dict,
              originales: dict, subidos: dict, playlists: list[str] | None = None, al_avanzar=None) -> str:
    """Sube un vídeo con su miniatura y lo mete en sus playlists. Devuelve el id nuevo.

    playlists: nombres de las listas donde meterlo; si es None, las que tenía el original.
    al_avanzar(porcentaje, texto): para enseñar en qué va, si se pasa.
    """
    avisar = al_avanzar or (lambda porcentaje, texto: None)
    from googleapiclient.http import MediaFileUpload

    titulo = v.get("titulo") or v["info"].get("title")
    nuevo = subir_video(youtube, v, privacidad, al_avanzar)
    registro = {"nuevo": nuevo, "titulo": titulo, "fecha": f"{datetime.now():%Y-%m-%d %H:%M}",
                "privacidad": privacidad, "playlists": []}
    subidos[v["id"]] = registro
    RUTA_SUBIDOS.write_text(json.dumps(subidos, ensure_ascii=False, indent=1), encoding="utf-8")
    log(f"subido {v['id']} -> {nuevo}  {titulo}")

    # Miniatura y playlist son secundarias: si fallan por otra cosa que no sea cuota, se sigue
    if v["miniatura"]:
        avisar(100, "Poniendo la miniatura")
        try:
            llamar(youtube.thumbnails().set(videoId=nuevo, media_body=MediaFileUpload(str(v["miniatura"]))))
        except CuotaAgotada:
            raise
        except Exception as error:
            log(f"  miniatura no puesta: {error}")
    for nombre in listas_de.get(v["id"], []) if playlists is None else playlists:
        avisar(100, f"Metiéndolo en la lista «{nombre}»")
        lista_id = id_playlist(youtube, nombre, existentes, originales)
        from googleapiclient.errors import HttpError
        cuerpo = {"snippet": {"playlistId": lista_id,
                              "resourceId": {"kind": "youtube#video", "videoId": nuevo}}}
        # Justo después de crear la lista (o de subir el vídeo) YouTube a veces responde
        # 409 SERVICE_UNAVAILABLE: se reintenta unas veces antes de darlo por fallido.
        for intento in range(5):
            try:
                llamar(youtube.playlistItems().insert(part="snippet", body=cuerpo))
                break
            except HttpError as error:
                if intento == 4 or error.resp.status not in (409, 500, 503):
                    raise
                time.sleep(3 * (intento + 1))
        registro["playlists"].append(nombre)
    RUTA_SUBIDOS.write_text(json.dumps(subidos, ensure_ascii=False, indent=1), encoding="utf-8")
    return nuevo


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--privacidad", choices=["private", "unlisted", "public"], default="private")
    parser.add_argument("--limite", type=int, default=0, help="máximo de vídeos en esta ejecución")
    parser.add_argument("--prueba", action="store_true", help="no sube nada, solo enseña la lista")
    parser.add_argument("--conectar", action="store_true",
                        help="solo hace el login con Google y guarda token.json")
    args = parser.parse_args()

    if args.conectar:
        conectar()
        print("Conectado. Permiso guardado en token.json.")
        return 0

    subidos = leer_json(RUTA_SUBIDOS, {})
    cola = pendientes(subidos)
    if args.limite:
        cola = cola[:args.limite]

    listas_de, originales = cargar_listas()

    print(f"Subidos antes: {len(subidos)}. Pendientes en esta ejecución: {len(cola)}.")
    if args.prueba:
        for v in cola[:30]:
            print(f"  {v['info'].get('upload_date')}  {v['info'].get('title')}  "
                  f"-> {', '.join(listas_de.get(v['id'], [])) or 'sin playlist'}")
        if len(cola) > 30:
            print(f"  ... y {len(cola) - 30} más")
        return 0
    if not cola:
        return 0

    youtube = conectar()
    existentes = playlists_del_canal(youtube)
    hechos = 0
    try:
        for v in cola:
            subir_uno(youtube, v, args.privacidad, listas_de, existentes, originales, subidos)
            hechos += 1
    except CuotaAgotada as motivo:
        log(f"Cuota agotada ({motivo}) tras {hechos} vídeos hoy. Relanzar mañana: sigue por donde iba.")
        return 2
    log(f"Terminado: {hechos} vídeos subidos en esta ejecución.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
