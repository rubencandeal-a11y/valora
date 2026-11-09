"""Subida automática diaria: cada día mete en la cola los N vídeos siguientes que cumplan unas
condiciones, en orden ascendente o descendente, y guarda en el historial qué se hizo cada día.

La configuración vive en plan.json y el historial en historial.json, junto a la cola. No sube
nada por su cuenta: solo añade a la cola, y el trabajador de web.py hace el resto (descargar,
rehacer con entrada y salida, subir y meter en la lista).

Si un día no cabe todo (cuota de Google), lo que queda sigue en la cola y cuenta para el día
siguiente: se añaden solo los que faltan para llegar a N, así la cola no crece sin fin.
"""
import json
import threading
from datetime import datetime
from pathlib import Path

import subir

BASE = Path(__file__).resolve().parent
RUTA_PLAN = BASE / "plan.json"
RUTA_HISTORIAL = BASE / "historial.json"

PLAN_INICIAL = {
    "activa": False,
    "por_dia": 10,
    "hora": "03:00",
    "dias": [0, 1, 2, 3, 4, 5, 6],      # 0 = lunes
    "privacidad": "public",
    "entrada_salida": True,
    "titulo_modo": "ia",
    "orden": "asc",                       # asc: más antiguos primero; desc: más recientes primero
    "desde": "",                          # AAAA-MM-DD, vacío = sin límite
    "hasta": "",
    "listas": [],                         # vacía = todas; "-" = sin lista
    "tipo": "",                           # "", "Short" o "Vídeo"
    "texto": "",                          # el título tiene que contenerlo
    "tope": 0,                            # parar al llegar a este total de vídeos automáticos (0 = sin tope)
    "ultimo_dia": "",                     # AAAA-MM-DD del último lote metido
}
ESTADOS_ACTIVOS = ("pendiente", "descargando", "editando", "subiendo", "limpiando")

cerrojo = threading.Lock()


def leer_plan() -> dict:
    plan = dict(PLAN_INICIAL)
    plan.update(subir.leer_json(RUTA_PLAN, {}))
    return plan


def guardar_plan(plan: dict) -> None:
    RUTA_PLAN.write_text(json.dumps(plan, ensure_ascii=False, indent=1), encoding="utf-8")


def leer_historial() -> list[dict]:
    return subir.leer_json(RUTA_HISTORIAL, [])


def guardar_historial(historial: list[dict]) -> None:
    RUTA_HISTORIAL.write_text(json.dumps(historial, ensure_ascii=False, indent=1), encoding="utf-8")


def validar(datos: dict, actual: dict) -> dict:
    """Mezcla lo que llega de la web o de Valora con el plan actual, comprobando cada campo."""
    plan = dict(actual)
    if "activa" in datos:
        plan["activa"] = bool(datos["activa"])
    if "por_dia" in datos:
        plan["por_dia"] = max(1, min(100, int(datos["por_dia"])))
    if "hora" in datos:
        hora = str(datos["hora"]).strip()
        h, m = hora.split(":")
        if not (0 <= int(h) < 24 and 0 <= int(m) < 60):
            raise ValueError("hora")
        plan["hora"] = f"{int(h):02d}:{int(m):02d}"
    if "dias" in datos:
        dias = sorted({int(d) for d in datos["dias"] if 0 <= int(d) <= 6})
        if not dias:
            raise ValueError("dias")
        plan["dias"] = dias
    if "privacidad" in datos:
        if datos["privacidad"] not in ("private", "unlisted", "public"):
            raise ValueError("privacidad")
        plan["privacidad"] = datos["privacidad"]
    if "entrada_salida" in datos:
        plan["entrada_salida"] = bool(datos["entrada_salida"])
    if "titulo_modo" in datos:
        if datos["titulo_modo"] not in ("igual", "recuerdo", "ia"):
            raise ValueError("titulo_modo")
        plan["titulo_modo"] = datos["titulo_modo"]
    if "orden" in datos:
        if datos["orden"] not in ("asc", "desc"):
            raise ValueError("orden")
        plan["orden"] = datos["orden"]
    for campo in ("desde", "hasta"):
        if campo in datos:
            valor = str(datos[campo] or "").strip()
            if valor:
                datetime.strptime(valor, "%Y-%m-%d")
            plan[campo] = valor
    if "listas" in datos:
        plan["listas"] = [str(l) for l in (datos["listas"] or []) if str(l).strip()]
    if "tipo" in datos:
        if datos["tipo"] not in ("", "Short", "Vídeo"):
            raise ValueError("tipo")
        plan["tipo"] = datos["tipo"]
    if "texto" in datos:
        plan["texto"] = str(datos["texto"] or "").strip()[:100]
    if "tope" in datos:
        plan["tope"] = max(0, int(datos["tope"] or 0))
    return plan


def cumple(v: dict, plan: dict) -> bool:
    fecha = v.get("fecha") or ""
    if plan["desde"] and (not fecha or fecha < plan["desde"]):
        return False
    if plan["hasta"] and (not fecha or fecha > plan["hasta"]):
        return False
    if plan["tipo"] and v.get("tipo") != plan["tipo"]:
        return False
    if plan["listas"]:
        listas = v.get("playlists") or []
        if not any(l in listas for l in plan["listas"]) and not ("-" in plan["listas"] and not listas):
            return False
    if plan["texto"] and plan["texto"].lower() not in (v.get("titulo") or "").lower():
        return False
    return True


def candidatos(plan: dict, catalogo: dict, subidos: dict, cola: list[dict]) -> list[dict]:
    """Vídeos que cumplen las condiciones y aún no están subidos ni en la cola, ya ordenados.

    Los que no tienen fecha van siempre al final.
    """
    ocupados = {i["id"] for i in cola if i["estado"] != "error"}
    lista = [v for v in catalogo.get("videos", [])
             if v["id"] not in subidos and v["id"] not in ocupados and cumple(v, plan)]
    con_fecha = sorted((v for v in lista if v.get("fecha")), key=lambda v: (v["fecha"], v["id"]),
                       reverse=plan["orden"] == "desc")
    return con_fecha + [v for v in lista if not v.get("fecha")]


def total_automaticos(historial: list[dict]) -> int:
    return sum(len(d["videos"]) for d in historial)


def resumen(plan: dict, catalogo: dict, subidos: dict, cola: list[dict], historial: list[dict]) -> dict:
    """Lo que enseña la ventana: cuántos entran, los siguientes y cuántos días faltan."""
    lista = candidatos(plan, catalogo, subidos, cola)
    quedan = len(lista)
    if plan["tope"]:
        quedan = max(0, min(quedan, plan["tope"] - total_automaticos(historial)))
    por_semana = plan["por_dia"] * len(plan["dias"])
    dias = -(-quedan * 7 // por_semana) if por_semana else 0
    return {
        "plan": plan,
        "candidatos": len(lista),
        "quedan": quedan,
        "dias_estimados": dias,
        "siguientes": [{"id": v["id"], "titulo": v["titulo"], "fecha": v.get("fecha", "")}
                       for v in lista[:plan["por_dia"]]],
        "automaticos": total_automaticos(historial),
        "pendientes": pendientes_automaticos(cola),
        "total_catalogo": len(catalogo.get("videos", [])),
        "total_subidos": len(subidos),
    }


def pendientes_automaticos(cola: list[dict]) -> int:
    return sum(1 for i in cola if i.get("auto") and i["estado"] in ESTADOS_ACTIVOS)


def toca(plan: dict, ahora: datetime) -> bool:
    """¿Hay que meter hoy el lote? Activa, día marcado, ya pasada la hora y no metido todavía."""
    if not plan["activa"] or ahora.weekday() not in plan["dias"]:
        return False
    if plan["ultimo_dia"] == ahora.strftime("%Y-%m-%d"):
        return False
    return ahora.strftime("%H:%M") >= plan["hora"]


def meter_lote(cola: list[dict], catalogo: dict, subidos: dict, plan: dict, historial: list[dict],
               ahora: datetime, por: str) -> list[dict]:
    """Añade a la cola (en la misma lista) los que faltan para llegar a por_dia y devuelve los añadidos.

    Cuenta los automáticos que siguen pendientes de días anteriores, para no amontonar.
    """
    hueco = plan["por_dia"] - pendientes_automaticos(cola)
    if plan["tope"]:
        hueco = min(hueco, plan["tope"] - total_automaticos(historial))
    if hueco <= 0:
        return []
    dia = ahora.strftime("%Y-%m-%d")
    nuevos = []
    for v in candidatos(plan, catalogo, subidos, cola)[:hueco]:
        cola.append({"id": v["id"], "titulo": v["titulo"], "privacidad": plan["privacidad"],
                     "entrada_salida": plan["entrada_salida"], "titulo_modo": plan["titulo_modo"],
                     "estado": "pendiente", "por": por, "pedido": f"{ahora:%Y-%m-%d %H:%M}", "auto": dia})
        nuevos.append(v)
    return nuevos


def apuntar_dia(historial: list[dict], plan: dict, ahora: datetime, nuevos: list[dict],
                arrastrados: int, por: str) -> None:
    historial.append({
        "dia": ahora.strftime("%Y-%m-%d"),
        "hora": ahora.strftime("%H:%M"),
        "por": por,
        "por_dia": plan["por_dia"],
        "arrastrados": arrastrados,
        "condiciones": describir(plan),
        "videos": [{"id": v["id"], "titulo": v["titulo"], "fecha": v.get("fecha", ""),
                    "playlists": v.get("playlists") or []} for v in nuevos],
    })


def describir(plan: dict) -> str:
    partes = ["ascendente" if plan["orden"] == "asc" else "descendente"]
    if plan["desde"] or plan["hasta"]:
        partes.append(f"de {plan['desde'] or 'el principio'} a {plan['hasta'] or 'hoy'}")
    partes.append(", ".join(plan["listas"]) if plan["listas"] else "todas las listas")
    if plan["tipo"]:
        partes.append("solo shorts" if plan["tipo"] == "Short" else "solo vídeos")
    if plan["texto"]:
        partes.append(f"título con «{plan['texto']}»")
    if plan["tope"]:
        partes.append(f"tope {plan['tope']}")
    return " · ".join(partes)


def historial_con_estado(historial: list[dict], cola: list[dict], subidos: dict) -> list[dict]:
    """El historial, del día más reciente al más antiguo, con cómo va cada vídeo ahora mismo."""
    en_cola = {i["id"]: i for i in cola}
    salida = []
    for dia in reversed(historial):
        videos, cuenta = [], {"hecho": 0, "pendiente": 0, "error": 0}
        for v in dia["videos"]:
            item = en_cola.get(v["id"], {})
            nuevo = subidos.get(v["id"], {}).get("nuevo") or item.get("nuevo")
            if nuevo:
                estado = "hecho"
            elif item.get("estado") == "error":
                estado = "error"
            elif item:
                estado = "pendiente"
            else:
                estado = "quitado"
            cuenta[estado] = cuenta.get(estado, 0) + 1
            titulo_subido = subidos.get(v["id"], {}).get("titulo") or item.get("titulo_nuevo") or ""
            videos.append(dict(v, estado=estado, nuevo=nuevo, error=item.get("error", ""),
                               titulo_original=v["titulo"], titulo=titulo_subido or v["titulo"],
                               en_cola=item.get("estado", ""),
                               subido=subidos.get(v["id"], {}).get("fecha", "")))
        salida.append(dict(dia, videos=videos, cuenta=cuenta))
    return salida
