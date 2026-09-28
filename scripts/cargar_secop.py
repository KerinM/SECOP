"""
cargar_secop.py  ·  SECOP Integrado  ·  Entregable 4 (José)

Carga las partes de data/descargas/ en la base secop_integrado y las lleva
por las tres capas:

    data/descargas/parte_*.csv
        -> COPY          -> staging.contratos_raw   (fiel al origen, sin tipar)
        -> INSERT SELECT -> silver.contrato          (tipada y depurada)
        -> INSERT SELECT -> gold.fact_contrato       (estrella, particionada)

Por qué COPY y no INSERT
------------------------
COPY es la vía de carga más rápida de PostgreSQL y, además, es la única
que resuelve bien este archivo: el CSV tiene saltos de línea dentro de
campos entrecomillados (35.188 de más en las primeras 50.000 filas), que
romperían cualquier lector por líneas.

Por qué lotes de 250.000
------------------------
volumetria.md 10.3: cargar 22,67M filas en un solo lote dispara la memoria.
Se inserta por tramos de id_contrato, con commit por tramo, como en
PlascspBigData. Así además se ve el avance y un corte no tira el trabajo
hecho.

Uso
---
    python scripts/cargar_secop.py --etapa staging     # solo COPY
    python scripts/cargar_secop.py --etapa silver
    python scripts/cargar_secop.py --etapa gold
    python scripts/cargar_secop.py                      # las tres, en orden

    --lote 100000   para probar con menos filas por commit
    --truncar       para vaciar staging antes de copiar
    --verificar     para comparar contra las 22.670.028 filas de la API
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
import time
from pathlib import Path

import psycopg2

# ---------------------------------------------------------------------------
# Configuracion
# ---------------------------------------------------------------------------
RAIZ = Path(__file__).resolve().parent.parent
DIR_DESCARGAS = RAIZ / "data" / "descargas"
DIR_LOGS = RAIZ / "logs"
ARCHIVO_ENV = RAIZ / ".env"

FILAS_ESPERADAS = 22_670_028
LOTE_POR_DEFECTO = 250_000

log = logging.getLogger("cargar_secop")


# ---------------------------------------------------------------------------
# Configuracion
# ---------------------------------------------------------------------------
def leer_env() -> None:
    """Carga el .env sin depender de python-dotenv, que no esta instalado.

    Solo define variables que aun no existan en el entorno, para que lo que
    se pase por consola gane.
    """
    if not ARCHIVO_ENV.exists():
        return
    for linea in ARCHIVO_ENV.read_text(encoding="utf-8").splitlines():
        linea = linea.strip()
        if not linea or linea.startswith("#") or "=" not in linea:
            continue
        clave, _, valor = linea.partition("=")
        clave = clave.strip()
        valor = valor.strip().strip('"').strip("'")
        os.environ.setdefault(clave, valor)


def configurar_log() -> None:
    DIR_LOGS.mkdir(parents=True, exist_ok=True)
    formato = "%(asctime)s  %(levelname)-7s  %(message)s"

    consola = logging.StreamHandler(sys.stdout)
    consola.setFormatter(logging.Formatter(formato))
    log.addHandler(consola)
    log.setLevel(logging.INFO)

    archivo = logging.FileHandler(DIR_LOGS / "carga.log", encoding="utf-8")
    archivo.setFormatter(logging.Formatter(formato))
    log.addHandler(archivo)


def conectar():
    leer_env()
    conexion = psycopg2.connect(
        host=os.environ.get("PGHOST", "localhost"),
        port=int(os.environ.get("PGPORT", "5432")),
        dbname=os.environ.get("PGDATABASE", "secop_integrado"),
        user=os.environ.get("PGUSER", "secop_etl"),
        password=os.environ["PGPASSWORD"],
    )
    conexion.autocommit = False
    return conexion


def partes() -> list[Path]:
    if not DIR_DESCARGAS.exists():
        return []
    return sorted(DIR_DESCARGAS.glob("parte_*.csv"))


# ---------------------------------------------------------------------------
# Etapa 1: COPY a staging
# ---------------------------------------------------------------------------
def etapa_staging(conexion, truncar: bool) -> None:
    archivos = partes()
    if not archivos:
        log.error("No hay partes en %s", DIR_DESCARGAS)
        log.error("Correr antes: python scripts/descargar_secop.py")
        sys.exit(1)

    log.info("Etapa 1/3  COPY a staging.contratos_raw")
    log.info("Partes a copiar: %d", len(archivos))

    with conexion.cursor() as cursor:
        if truncar:
            log.info("Vaciando staging.contratos_raw")
            # RESTART IDENTITY es obligatorio: sin esto, una carga anterior de
            # prueba deja la secuencia corrida y silver.contrato arranca con
            # un hueco en id_contrato (los ids no quedan 1..N).
            cursor.execute("TRUNCATE staging.contratos_raw RESTART IDENTITY")
            conexion.commit()

        # En una carga masiva de staging no se necesita durabilidad por
        # commit: si algo falla, la tabla se puede volver a llenar desde los
        # CSV, que son la fuente de verdad. Eso ahorra las escrituras de WAL
        # de cada commit.
        cursor.execute("SET synchronous_commit = off")
        cursor.execute("SET maintenance_work_mem = '1GB'")

        inicio = time.time()
        total = 0
        for numero, archivo in enumerate(archivos, 1):
            with archivo.open("r", encoding="utf-8", newline="") as flujo:
                # HEADER true porque cada parte trae su propio encabezado, y
                # el orden de las columnas del CSV es exactamente el de la
                # tabla, asi que COPY empareja por posicion.
                cursor.copy_expert(
                    "COPY staging.contratos_raw FROM STDIN "
                    "WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')",
                    flujo,
                )
            conexion.commit()
            total += 1
            log.info(
                "  [%d/%d] %s  |  acumulado %.1f min",
                numero, len(archivos), archivo.name, (time.time() - inicio) / 60,
            )

    filas = contar(conexion, "staging.contratos_raw")
    log.info("staging.contratos_raw tiene %d filas (%.1f min)", filas,
             (time.time() - inicio) / 60)
    if filas != FILAS_ESPERADAS:
        log.warning(
            "Se esperaban %d filas y hay %d. Si es una carga parcial, sigue; "
            "si es la descarga completa, hay que revisarla.",
            FILAS_ESPERADAS, filas,
        )


# ---------------------------------------------------------------------------
# Etapa 2: staging -> silver
# ---------------------------------------------------------------------------
# Las sentencias van como cadenas crudas (prefijo r) porque los patrones de
# regexp contienen \- y \d: en una cadena normal Python eso es un escape
# invalido y sale un SyntaxWarning.
SQL_STAGING_A_SILVER = r"""
INSERT INTO silver.contrato (
    nivel_entidad, codigo_entidad_en_secop, nombre_de_la_entidad,
    nit_de_la_entidad, departamento_entidad, municipio_entidad,
    estado_del_proceso, modalidad_de_contrataci_n,
    objeto_a_contratar, objeto_del_proceso, tipo_de_contrato,
    fecha_de_firma_del_contrato, fecha_inicio_ejecuci_n, fecha_fin_ejecuci_n,
    numero_del_contrato, numero_de_proceso, valor_contrato,
    nom_raz_social_contratista, url_contrato, origen,
    tipo_documento_proveedor, documento_proveedor, fecha_firma_texto
)
SELECT
    nivel_entidad,
    codigo_entidad_en_secop,
    nombre_de_la_entidad,
    nit_de_la_entidad,
    departamento_entidad,
    municipio_entidad,
    estado_del_proceso,
    modalidad_de_contrataci_n,
    objeto_a_contratar,
    objeto_del_proceso,
    tipo_de_contrato,
    -- es_fecha_valida no lanza: ya valida anio, mes y dia antes de llamar
    -- a make_date. Las fechas imposibles (1899, 2099, 8201) salen NULL.
    silver.es_fecha_valida(fecha_de_firma_del_contrato),
    silver.es_fecha_valida(fecha_inicio_ejecuci_n),
    silver.es_fecha_valida(fecha_fin_ejecuci_n),
    numero_del_contrato,
    numero_de_proceso,
    -- valor_contrato llega como texto plano ("1518440"), sin separador de
    -- miles ni simbolo. Maximo medido 999999999999999, que cabe en numeric(18,2).
    NULLIF(regexp_replace(valor_contrato, '[^0-9.\-]', '', 'g'), '')::numeric(18,2),
    nom_raz_social_contratista,
    url_contrato,
    origen,
    tipo_documento_proveedor,
    documento_proveedor,
    -- Se guarda el texto original de la fecha, no el de las otras dos: es
    -- la unica que tiene 1,77M de nulos y la que hay que auditar.
    fecha_de_firma_del_contrato
FROM staging.contratos_raw
"""


def minimo_id_contrato(conexion):
    """Menor id_contrato de silver, o None si la tabla esta vacia."""
    with conexion.cursor() as cursor:
        cursor.execute("SELECT min(id_contrato) FROM silver.contrato")
        fila = cursor.fetchone()
    conexion.rollback()
    return fila[0] if fila else None


def etapa_silver(conexion) -> None:
    log.info("Etapa 2/3  staging -> silver.contrato")
    existentes = contar(conexion, "silver.contrato")
    if existentes:
        log.error("silver.contrato ya tiene %d filas.", existentes)
        log.error("Se vacia a mano o se corre con el DDL en modo recrear.")
        sys.exit(1)

    inicio = time.time()
    with conexion.cursor() as cursor:
        cursor.execute("SET synchronous_commit = off")
        cursor.execute("SET maintenance_work_mem = '1GB'")
        cursor.execute(SQL_STAGING_A_SILVER)
        insertadas = cursor.rowcount
        conexion.commit()

    log.info("silver.contrato: %d filas en %.1f min", insertadas,
             (time.time() - inicio) / 60)

    # id_contrato debe arrancar en 1. Si no, la secuencia de silver quedo
    # corrida (un TRUNCATE sin RESTART IDENTITY previo) y el id es un hueco
    # sin consecuencia funcional, pero conviene enterarse.
    minimo = minimo_id_contrato(conexion)
    if minimo is not None and minimo != 1:
        log.warning(
            "ATENCION: id_contrato arranca en %d y no en 1. La secuencia de "
            "silver.contrato quedo corrida. No afecta la integridad (la PK es "
            "(fecha_firma, id_contrato)), pero el id no queda 1..N.", minimo)

    with conexion.cursor() as cursor:
        cursor.execute("""
            SELECT
                count(*) FILTER (WHERE fecha_de_firma_del_contrato IS NULL) AS sin_fecha,
                count(*) FILTER (WHERE fecha_inicio_ejecuci_n IS NULL)     AS sin_inicio,
                count(*) FILTER (WHERE fecha_fin_ejecuci_n IS NULL)        AS sin_fin,
                count(*) FILTER (WHERE valor_contrato IS NULL)             AS sin_valor
            FROM silver.contrato
        """)
        sin_fecha, sin_inicio, sin_fin, sin_valor = cursor.fetchone()
    log.info("  Fechas nulas: firma %d, inicio %d, fin %d", sin_fecha, sin_inicio, sin_fin)
    log.info("  Valores nulos: %d", sin_valor)
    conexion.rollback()


# ---------------------------------------------------------------------------
# Etapa 3: dimensiones y gold
# ---------------------------------------------------------------------------
# Las claves de las 6 dimensiones de texto se normalizan con silver.normaliza_texto
# y la unicidad la impone el indice UNIQUE sobre una columna COLLATE secop_ci.
# Por eso Compraventa y COMPRAVENTA terminan siendo la MISMA fila: la segunda
# choca con el indice y ON CONFLICT la descarta.
#
# El NULL de origen se vuelve 'NO DEFINIDO' porque la columna codigo es NOT
# NULL y porque el dato trae ese centinela de todas formas. Sin esto, las
# filas sin documento (76) y sin razon social (66) no tendrian a que apuntar.

SQL_DIM_ENTIDAD = """
INSERT INTO gold.dim_entidad
    (codigo_entidad, nombre_entidad, nit_entidad, nivel_entidad, departamento, municipio)
SELECT coalesce(silver.normaliza_texto(codigo_entidad_en_secop), 'NO DEFINIDO'),
       max(nombre_de_la_entidad),
       max(nit_de_la_entidad),
       max(silver.normaliza_texto(nivel_entidad)),
       max(silver.normaliza_texto(departamento_entidad)),
       max(silver.normaliza_texto(municipio_entidad))
FROM silver.contrato
GROUP BY 1
ON CONFLICT (codigo_entidad) DO NOTHING
"""

SQL_DIM_PROVEEDOR = """
INSERT INTO gold.dim_proveedor (documento, documento_crudo, tipo_documento, razon_social)
SELECT silver.normaliza_documento(documento_proveedor),
       max(documento_proveedor),
       max(silver.normaliza_texto(tipo_documento_proveedor)),
       max(nom_raz_social_contratista)
FROM silver.contrato
-- El filtro va en WHERE y no en HAVING: WHERE se evalua antes de agrupar,
-- y un HAVING sobre el alias de la salida no resuelve de forma fiable.
WHERE silver.normaliza_documento(documento_proveedor) IS NOT NULL
GROUP BY 1
ON CONFLICT (documento) DO NOTHING
"""

# Un documento NULL o vacio no puede ser clave (es NOT NULL y UNIQUE), asi que
# esas filas se cuelan con el centinela explicito.
SQL_DIM_PROVEEDOR_SIN_DOCUMENTO = """
INSERT INTO gold.dim_proveedor (documento, documento_crudo, tipo_documento, razon_social)
SELECT 'NO DEFINIDO', max(documento_proveedor),
       max(silver.normaliza_texto(tipo_documento_proveedor)),
       max(nom_raz_social_contratista)
FROM silver.contrato
WHERE silver.normaliza_documento(documento_proveedor) IS NULL
HAVING count(*) > 0
ON CONFLICT (documento) DO NOTHING
"""

SQL_DIM_SIMPLE = """
INSERT INTO gold.dim_{tabla} (codigo, descripcion)
SELECT coalesce(silver.normaliza_texto({columna}), 'NO DEFINIDO'), max({columna})
FROM silver.contrato
GROUP BY 1
ON CONFLICT (codigo) DO NOTHING
"""

DIMENSIONES_SIMPLES = [
    ("tipo_contrato", "tipo_de_contrato"),
    ("modalidad", "modalidad_de_contrataci_n"),
    ("estado", "estado_del_proceso"),
    ("origen", "origen"),
    ("tipo_documento", "tipo_documento_proveedor"),
]


def etapa_dimensiones(conexion) -> None:
    log.info("Etapa 3a/3  Poblando las 8 dimensiones")
    with conexion.cursor() as cursor:
        cursor.execute("SET maintenance_work_mem = '1GB'")
        cursor.execute("SET synchronous_commit = off")

        for nombre, sentencia in (
            ("dim_entidad", SQL_DIM_ENTIDAD),
            ("dim_proveedor", SQL_DIM_PROVEEDOR),
            ("dim_proveedor (sin documento)", SQL_DIM_PROVEEDOR_SIN_DOCUMENTO),
        ):
            inicio = time.time()
            cursor.execute(sentencia)
            conexion.commit()
            log.info("  %-32s %8d filas nuevas  (%.1f s)",
                     nombre, cursor.rowcount, time.time() - inicio)

        for tabla, columna in DIMENSIONES_SIMPLES:
            inicio = time.time()
            cursor.execute(SQL_DIM_SIMPLE.format(tabla=tabla, columna=columna))
            conexion.commit()
            log.info("  %-32s %8d filas nuevas  (%.1f s)",
                     f"dim_{tabla}", cursor.rowcount, time.time() - inicio)

    with conexion.cursor() as cursor:
        cursor.execute("""
            SELECT 'dim_entidad', count(*) FROM gold.dim_entidad
            UNION ALL SELECT 'dim_proveedor', count(*) FROM gold.dim_proveedor
            UNION ALL SELECT 'dim_tipo_contrato', count(*) FROM gold.dim_tipo_contrato
            UNION ALL SELECT 'dim_modalidad', count(*) FROM gold.dim_modalidad
            UNION ALL SELECT 'dim_estado', count(*) FROM gold.dim_estado
            UNION ALL SELECT 'dim_origen', count(*) FROM gold.dim_origen
            UNION ALL SELECT 'dim_tipo_documento', count(*) FROM gold.dim_tipo_documento
            UNION ALL SELECT 'dim_tiempo', count(*) FROM gold.dim_tiempo
            ORDER BY 1
        """)
        filas = cursor.fetchall()
    conexion.rollback()

    log.info("-" * 52)
    for nombre, total in filas:
        log.info("  %-22s %9d", nombre, total)
    log.info("-" * 52)

    # Comparar con lo que la volumetria estimo. dim_proveedor es la prueba de
    # que normalizar el documento sirvio de algo: la estimacion era
    # 3.364.090 con el documento CRUDO, contando varias veces a la misma
    # persona por los puntos y guiones.
    with conexion.cursor() as cursor:
        cursor.execute("""
            SELECT
                (SELECT count(DISTINCT documento_proveedor) FROM silver.contrato),
                (SELECT count(DISTINCT silver.normaliza_documento(documento_proveedor))
                   FROM silver.contrato WHERE silver.normaliza_documento(documento_proveedor) IS NOT NULL)
        """)
        crudo, normalizado = cursor.fetchone()
    conexion.rollback()
    log.info("  documento_proveedor CRUDO distinto     : %d", crudo)
    log.info("  documento_proveedor NORMALIZADO distinto: %d", normalizado)
    if normalizado < crudo:
        log.info("  Se colapsaron %d duplicados por puntos y guiones", crudo - normalizado)


SQL_GOLD = """
INSERT INTO gold.fact_contrato (
    fecha_firma, fecha_firma_es_centinela, fecha_firma_original,
    fecha_inicio, fecha_fin,
    numero_contrato, numero_proceso, valor_contrato,
    objeto_contrato, objeto_proceso, url_contrato,
    id_entidad, id_proveedor, id_tipo_contrato, id_modalidad,
    id_estado, id_origen, id_tipo_documento
)
SELECT
    -- El centinela existe en dim_tiempo (arranca en 1900) justamente para que
    -- estas filas tengan a donde apuntar sin romper la clave foranea.
    coalesce(s.fecha_de_firma_del_contrato, DATE '1900-01-01'),
    s.fecha_de_firma_del_contrato IS NULL,
    s.fecha_de_firma_del_contrato,
    s.fecha_inicio_ejecuci_n,
    s.fecha_fin_ejecuci_n,
    s.numero_del_contrato,
    s.numero_de_proceso,
    s.valor_contrato,
    s.objeto_a_contratar,
    s.objeto_del_proceso,
    s.url_contrato,
    de.id_entidad, dp.id_proveedor, dtc.id_tipo_contrato, dm.id_modalidad,
    des.id_estado, dor.id_origen, dtd.id_tipo_documento
FROM silver.contrato s
JOIN gold.dim_entidad       de  ON de.codigo_entidad
        = coalesce(silver.normaliza_texto(s.codigo_entidad_en_secop), 'NO DEFINIDO')
JOIN gold.dim_proveedor     dp  ON dp.documento
        = coalesce(silver.normaliza_documento(s.documento_proveedor), 'NO DEFINIDO')
JOIN gold.dim_tipo_contrato dtc ON dtc.codigo
        = coalesce(silver.normaliza_texto(s.tipo_de_contrato), 'NO DEFINIDO')
JOIN gold.dim_modalidad     dm  ON dm.codigo
        = coalesce(silver.normaliza_texto(s.modalidad_de_contrataci_n), 'NO DEFINIDO')
JOIN gold.dim_estado        des ON des.codigo
        = coalesce(silver.normaliza_texto(s.estado_del_proceso), 'NO DEFINIDO')
JOIN gold.dim_origen        dor ON dor.codigo
        = coalesce(silver.normaliza_texto(s.origen), 'NO DEFINIDO')
JOIN gold.dim_tipo_documento dtd ON dtd.codigo
        = coalesce(silver.normaliza_texto(s.tipo_documento_proveedor), 'NO DEFINIDO')
WHERE s.id_contrato BETWEEN %s AND %s
"""


def etapa_gold(conexion, lote: int) -> None:
    log.info("Etapa 3b/3  silver -> gold.fact_contrato (lotes de %d)", lote)

    with conexion.cursor() as cursor:
        cursor.execute("SELECT coalesce(max(id_contrato), 0) FROM silver.contrato")
        maximo = cursor.fetchone()[0]
    conexion.rollback()

    if not maximo:
        log.error("silver.contrato esta vacia. Correr antes la etapa silver.")
        sys.exit(1)

    inicio = time.time()
    total = 0
    lote_numero = 0
    for desde in range(1, maximo + 1, lote):
        hasta = min(desde + lote - 1, maximo)
        with conexion.cursor() as cursor:
            cursor.execute("SET synchronous_commit = off")
            cursor.execute("SET maintenance_work_mem = '1GB'")
            cursor.execute(SQL_GOLD, (desde, hasta))
            insertadas = cursor.rowcount
            conexion.commit()
        total += insertadas
        lote_numero += 1
        transcurrido = time.time() - inicio
        log.info(
            "  lote %3d  ids %d..%d  |  %d filas  |  %d total  |  %.1f min",
            lote_numero, desde, hasta, insertadas, total, transcurrido / 60,
        )

    log.info("gold.fact_contrato: %d filas en %.1f min", total,
             (time.time() - inicio) / 60)


def etapa_grupos(conexion) -> None:
    """Calcula id_grupo y es_contrato_repetido.

    Va aparte porque son dos funciones de ventana sobre 22,67M filas de texto:
    obligan a un orden completo y son la parte mas cara de la carga. Se puede
    correr mas tarde sin volver a hacer la carga.
    """
    log.info("Etapa 3c/3  Calculando id_grupo y es_contrato_repetido")
    log.info("Es un ORDER BY sobre 22,67M valores de texto. Puede tardar.")
    inicio = time.time()
    with conexion.cursor() as cursor:
        cursor.execute("SET maintenance_work_mem = '1GB'")
        cursor.execute("SET synchronous_commit = off")
        cursor.execute("""
            WITH marcado AS (
                SELECT
                    id_contrato,
                    dense_rank() OVER (ORDER BY numero_del_contrato COLLATE secop_ci)
                        AS id_grupo,
                    count(*) OVER (PARTITION BY numero_del_contrato COLLATE secop_ci) > 1
                        AS es_repetido
                FROM silver.contrato
                WHERE numero_del_contrato IS NOT NULL
            )
            UPDATE silver.contrato s
               SET id_grupo = m.id_grupo,
                   es_contrato_repetido = m.es_repetido
              FROM marcado m
             WHERE s.id_contrato = m.id_contrato
        """)
        actualizadas = cursor.rowcount
        conexion.commit()
    log.info("silver.contrato: %d filas marcadas en %.1f min", actualizadas,
             (time.time() - inicio) / 60)


# ---------------------------------------------------------------------------
# Verificacion
# ---------------------------------------------------------------------------
def contar(conexion, tabla: str) -> int:
    with conexion.cursor() as cursor:
        cursor.execute(f"SELECT count(*) FROM {tabla}")
        total = cursor.fetchone()[0]
    conexion.rollback()
    return total


def verificar(conexion, exigir_completo: bool = False) -> int:
    log.info("=" * 66)
    log.info("VERIFICACION")
    log.info("=" * 66)

    with conexion.cursor() as cursor:
        cursor.execute("""
            SELECT 'staging.contratos_raw', count(*) FROM staging.contratos_raw
            UNION ALL SELECT 'silver.contrato', count(*) FROM silver.contrato
            UNION ALL SELECT 'gold.fact_contrato', count(*) FROM gold.fact_contrato
        """)
        conteos = dict(cursor.fetchall())
    conexion.rollback()

    for tabla, total in conteos.items():
        marca = "" if total == FILAS_ESPERADAS else "   <-- parcial"
        log.info("  %-24s %12d%s", tabla, total, marca)

    staging = conteos.get("staging.contratos_raw", 0)
    silver = conteos.get("silver.contrato", 0)
    gold = conteos.get("gold.fact_contrato", 0)

    # La comprobacion de que no se perdieron filas solo tiene sentido si gold
    # se acaba de cargar. Si se corrio una sola etapa, gold en 0 es lo normal.
    if gold > 0:
        if gold != staging:
            log.error(
                "gold tiene %d filas y staging %d. Se perdieron filas en "
                "alguna etapa.", gold, staging,
            )
            return 1
        if silver and silver != staging:
            log.error("silver tiene %d filas y staging %d.", silver, staging)
            return 1
    elif exigir_completo:
        log.error("gold.fact_contrato esta vacia y se pedia la carga completa.")
        return 1

    if staging == FILAS_ESPERADAS:
        log.info("")
        log.info("COMPLETO: staging tiene las %d filas de la API.", FILAS_ESPERADAS)
        if gold == FILAS_ESPERADAS:
            log.info("Y gold tambien. La carga llego al final.")
        else:
            log.info("Falta terminar la carga: silver y/o gold siguen vacias.")
    else:
        log.info("")
        log.info("Carga parcial: staging tiene %d de %d filas esperadas.",
                 staging, FILAS_ESPERADAS)
    return 0


# ---------------------------------------------------------------------------
# Programa principal
# ---------------------------------------------------------------------------
def main() -> int:
    analizador = argparse.ArgumentParser(description=__doc__)
    analizador.add_argument(
        "--etapa", choices=["staging", "silver", "gold", "todas"],
        default="todas",
    )
    analizador.add_argument("--lote", type=int, default=LOTE_POR_DEFECTO)
    analizador.add_argument("--truncar", action="store_true",
                            help="vaciar staging antes del COPY")
    analizador.add_argument("--grupos", action="store_true",
                            help="calcular id_grupo (lento, se puede aparte)")
    analizador.add_argument("--verificar", action="store_true")
    argumentos = analizador.parse_args()

    configurar_log()
    conexion = conectar()

    try:
        if argumentos.verificar:
            return verificar(conexion)

        if argumentos.etapa in ("staging", "todas"):
            etapa_staging(conexion, argumentos.truncar)
        if argumentos.etapa in ("silver", "todas"):
            etapa_silver(conexion)
        if argumentos.etapa in ("gold", "todas"):
            etapa_dimensiones(conexion)
            etapa_gold(conexion, argumentos.lote)
        if argumentos.grupos:
            etapa_grupos(conexion)

        return verificar(conexion, exigir_completo=(argumentos.etapa == "todas"))
    finally:
        conexion.close()


if __name__ == "__main__":
    sys.exit(main())
