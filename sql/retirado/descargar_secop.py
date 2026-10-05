"""
descargar_secop.py  ·  SECOP Integrado  ·  Entregable 4 (José)

Descarga el dataset SECOP Integrado de datos.gov.co por la API paginada de
Socrata y deja las partes en data/descargas/ para que cargar_secop.py las
consuma con COPY.

Por qué paginada y no el endpoint oficial
-----------------------------------------
El endpoint oficial de descarga no entrega gzip. Medido en esta máquina:

    1 hilo,  $limit=50000    43,67 MB en 29,9 s  =  1,46 MB/s
    4 hilos, $limit=50000   160,88 MB en 26,5 s  =  6,07 MB/s
    8 hilos, $limit=50000   379,05 MB en 51,2 s  =  7,40 MB/s

Pasar de 4 a 8 hilos solo mejora 22%, así que la API satura alrededor de
6-7 MB/s. Con 6 hilos la descarga completa de 21.160 MB tarda del orden
de 50 minutos. En un solo hilo serían unas 4 horas.

933,6 bytes por fila medidos, que coincide con la proyección de
volumetria.md 4.1. 22.670.028 filas = 21,16 GB en partes.

El script es reanudable: si se corta, al volverlo a correr se saltea los
archivos que ya estan en disco.

Uso
---
    python scripts/descargar_secop.py                  # descarga completa
    python scripts/descargar_secop.py --paginas 3      # prueba con 3 paginas
    python scripts/descargar_secop.py --hilos 4
    python scripts/descargar_secop.py --verificar       # solo recounta
"""

from __future__ import annotations

import argparse
import csv
import logging
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import requests

# ---------------------------------------------------------------------------
# Configuracion
# ---------------------------------------------------------------------------
RAIZ = Path(__file__).resolve().parent.parent
DIR_DESCARGAS = RAIZ / "data" / "descargas"
DIR_LOGS = RAIZ / "logs"

DATASET_ID = "rpmr-utcd"
BASE_CSV = f"https://www.datos.gov.co/resource/{DATASET_ID}.csv"

# Conteo verificado contra la API el 27/09/2026 con count(*), que devolvio
# exactamente 22.670.028. La ficha del portal se desfasaba en 1,87M, asi
# que este numero viene medido, no de la metadata.
FILAS_ESPERADAS = 22_670_028

# Socrata acepta hasta 50.000 por pagina en datasets grandes. Medido: con
# 50.000 salen 43,67 MB y 29,9 s, o sea 1,46 MB/s, contra 0,88 MB/s con
# 5.000. Mas grande es mas rapido.
FILAS_POR_PAGINA = 50_000

TIMEOUT_SEG = 300
REINTENTOS = 5
ESPERA_ENTRE_REINTENTOS = 5

log = logging.getLogger("descargar_secop")


# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------
def configurar_log() -> None:
    DIR_LOGS.mkdir(parents=True, exist_ok=True)
    formato = "%(asctime)s  %(levelname)-7s  %(message)s"

    consola = logging.StreamHandler(sys.stdout)
    consola.setFormatter(logging.Formatter(formato))
    log.addHandler(consola)
    log.setLevel(logging.INFO)

    archivo = logging.FileHandler(DIR_LOGS / "descarga.log", encoding="utf-8")
    archivo.setFormatter(logging.Formatter(formato))
    log.addHandler(archivo)


def ruta_parte(indice: int) -> Path:
    return DIR_DESCARGAS / f"parte_{indice:05d}.csv"


def partes_existentes() -> dict[int, int]:
    """Devuelve {indice: tamano_en_bytes} de las partes ya descargadas."""
    if not DIR_DESCARGAS.exists():
        return {}
    encontradas = {}
    for archivo in DIR_DESCARGAS.glob("parte_*.csv"):
        try:
            indice = int(archivo.stem.split("_")[1])
        except (IndexError, ValueError):
            continue
        encontradas[indice] = archivo.stat().st_size
    return encontradas


def pedir_pagina(offset: int, limite: int) -> bytes:
    """Descarga una pagina con reintentos y espera creciente.

    Cada intento crea su propia Session: requests.Session no es segura para
    usar desde varios hilos a la vez.
    """
    url = f"{BASE_CSV}?$limit={limite}&$offset={offset}"
    ultimo_error: Exception | None = None

    for intento in range(1, REINTENTOS + 1):
        try:
            with requests.Session() as sesion:
                respuesta = sesion.get(
                    url,
                    timeout=TIMEOUT_SEG,
                    headers={"Accept-Encoding": "gzip"},
                )
            if respuesta.status_code == 200:
                return respuesta.content
            if respuesta.status_code in (429, 503):
                # La API pide que se baje el ritmo.
                espera = ESPERA_ENTRE_REINTENTOS * intento * 2
                log.warning(
                    "HTTP %s en offset %d. Se espera %ds antes de reintentar "
                    "(intento %d/%d)",
                    respuesta.status_code, offset, espera, intento, REINTENTOS,
                )
                time.sleep(espera)
                continue
            # 4xx distinto: reintentar no va a arreglarlo.
            respuesta.raise_for_status()
        except requests.RequestException as error:
            ultimo_error = error
            espera = ESPERA_ENTRE_REINTENTOS * intento
            log.warning(
                "Fallo en offset %d (intento %d/%d): %s. Reintenta en %ds",
                offset, intento, REINTENTOS, error, espera,
            )
            if intento < REINTENTOS:
                time.sleep(espera)

    raise RuntimeError(
        f"No se pudo descargar la pagina con offset {offset} tras "
        f"{REINTENTOS} intentos. Ultimo error: {ultimo_error}"
    )


def descargar_una(indice: int, limite: int) -> tuple[int, int, int]:
    """Descarga una pagina y la guarda. Devuelve (indice, bytes, filas)."""
    offset = indice * limite
    destino = ruta_parte(indice)

    contenido = pedir_pagina(offset, limite)

    # Escritura atomica: se escribe a un .tmp y se renombra. Si el proceso
    # se mata a mitad de archivo, no queda una parte corrupta que el
    # reanudador tomaria por buena.
    temporal = destino.with_suffix(".csv.tmp")
    temporal.write_bytes(contenido)
    temporal.replace(destino)

    lineas = contenido.count(b"\n")
    # Cada parte trae su propia linea de encabezado, que no es un dato.
    filas = max(0, lineas - 1)
    return indice, len(contenido), filas


# ---------------------------------------------------------------------------
# Programa principal
# ---------------------------------------------------------------------------
def main() -> int:
    analizador = argparse.ArgumentParser(description=__doc__)
    analizador.add_argument(
        "--hilos", type=int, default=6,
        help="hilos en paralelo. 6 es el punto dulce medido (default: 6)",
    )
    analizador.add_argument(
        "--paginas", type=int, default=None,
        help="descargar solo las N primeras paginas (para pruebas)",
    )
    analizador.add_argument(
        "--limite", type=int, default=FILAS_POR_PAGINA,
        help=f"filas por pagina (default: {FILAS_POR_PAGINA})",
    )
    analizador.add_argument(
        "--verificar", action="store_true",
        help="solo recounta las partes existentes y sale",
    )
    argumentos = analizador.parse_args()

    configurar_log()
    DIR_DESCARGAS.mkdir(parents=True, exist_ok=True)

    total_paginas = -(-FILAS_ESPERADAS // argumentos.limite)  # division entera hacia arriba
    if argumentos.paginas is not None:
        total_paginas = min(total_paginas, argumentos.paginas)

    if argumentos.verificar:
        return verificar()

    log.info("Dataset          : %s", DATASET_ID)
    log.info("Filas esperadas  : %d", FILAS_ESPERADAS)
    log.info("Paginas totales  : %d de %d filas", total_paginas, argumentos.limite)
    log.info("Hilos            : %d", argumentos.hilos)
    log.info("Destino          : %s", DIR_DESCARGAS)

    existentes = partes_existentes()
    if existentes:
        log.info(
            "Reanudacion: %d partes ya estan en disco y se van a saltar",
            len(existentes),
        )

    pendientes = [i for i in range(total_paginas) if i not in existentes]
    if not pendientes:
        log.info("No queda ninguna pagina por descargar.")
        return verificar()

    inicio = time.time()
    descargadas = 0
    bytes_totales = 0
    filas_totales = 0
    fallos: list[int] = []

    with ThreadPoolExecutor(max_workers=argumentos.hilos) as pool:
        futuros = {
            pool.submit(descargar_una, indice, argumentos.limite): indice
            for indice in pendientes
        }
        for futuro in as_completed(futuros):
            indice = futuros[futuro]
            try:
                _, bytes_pagina, filas = futuro.result()
            except Exception as error:  # noqa: BLE001
                log.error("Pagina %d fallo definitivamente: %s", indice, error)
                fallos.append(indice)
                continue

            descargadas += 1
            bytes_totales += bytes_pagina
            filas_totales += filas

            transcurrido = time.time() - inicio
            velocidad = bytes_totales / transcurrido / 1_048_576 if transcurrido else 0
            quedan = len(pendientes) - descargadas - len(fallos)
            restante = (
                quedan / (descargadas / transcurrido)
                if descargadas and transcurrido else 0
            )
            log.info(
                "[%d/%d] parte %05d  %6.1f MB  %6d filas  |  %.2f MB/s  |  faltan ~%d min",
                descargadas, len(pendientes), indice,
                bytes_pagina / 1_048_576, filas, velocidad, restante / 60,
            )

    log.info("Descarga terminada en %.1f minutos", (time.time() - inicio) / 60)

    if fallos:
        log.error(
            "%d paginas fallaron: %s",
            len(fallos),
            ", ".join(str(i) for i in sorted(fallos)[:20]),
        )
        log.error("Volver a correr el script las reintenta: se saltea las buenas.")

    return verificar()


def verificar() -> int:
    """Recuenta las partes en disco y compara contra lo esperado."""
    existentes = partes_existentes()
    if not existentes:
        log.error("No hay ninguna parte en %s", DIR_DESCARGAS)
        return 1

    total_bytes = 0
    total_filas = 0

    # Se cuenta con el modulo csv y NO contando bytes b"\n". Este dataset
    # tiene saltos de linea DENTRO de los campos de texto entrecomillados:
    # medido en la parte 00000, csv.reader encuentra 50.001 registros
    # mientras que contar \n da 85.189, o sea 35.188 lineas de mas. Casi el
    # 70% de las filas trae un salto interno. Cualquier procesamiento por
    # lineas de este CSV daria un numero falso.
    for indice in sorted(existentes):
        archivo = ruta_parte(indice)
        total_bytes += archivo.stat().st_size
        with archivo.open("r", encoding="utf-8", newline="") as flujo:
            for _ in csv.reader(flujo):
                total_filas += 1

    total_filas -= len(existentes)  # una cabecera por parte

    faltante = (total_paginas_esperadas() - len(existentes))
    log.info("-" * 62)
    log.info("Partes en disco   : %d", len(existentes))
    log.info("Tamano total      : %.2f GB", total_bytes / 1_073_741_824)
    log.info("Filas acumuladas  : %d", total_filas)
    log.info("Esperadas         : %d", FILAS_ESPERADAS)
    log.info("Diferencia        : %+d", total_filas - FILAS_ESPERADAS)
    if faltante > 0:
        log.info("Paginas faltantes : %d", faltante)
    log.info("-" * 62)

    if total_filas == FILAS_ESPERADAS:
        log.info("COMPLETO. Se puede correr scripts/cargar_secop.py")
        return 0

    log.warning(
        "La descarga esta incompleta o hay filas de mas. "
        "Faltan %d paginas por bajar.",
        max(0, faltante),
    )
    return 2


def total_paginas_esperadas() -> int:
    return -(-FILAS_ESPERADAS // FILAS_POR_PAGINA)


if __name__ == "__main__":
    sys.exit(main())
