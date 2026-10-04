"""
06_validacion_python.py  ·  VALIDACIÓN INDEPENDIENTE DE LA CAPA PLATA
Responsable: Jose (Ingeniero ETL)

Qué hace
--------
El ETL se hizo en SQL. Este script lo revisa con OTRA herramienta (Python),
sin usar las funciones de limpieza de la base:

  A. Conteos de bronce y plata contra los valores documentados.
  B. Toma una muestra al azar de plata, trae la fila ORIGINAL de bronce,
     la vuelve a limpiar en Python con las mismas reglas (R1-R8) y compara
     columna por columna con lo que quedó en plata.
  C. Toma filas que la deduplicación (R5) eliminó y busca su "gemela" en plata.
  D. Revisa en Python el promedio de versiones de SECOP II (R7b).
  E. Lista los valores extremos marcados (R9b).
  F. Compara los totales por año con las cifras oficiales.

Nada se modifica en la base: solo se leen datos.

Cómo se corre
-------------
  1. Una sola vez:   pip install pandas psycopg2-binary
  2. Cada vez:       python 06_validacion_python.py
     Pide la contraseña de PostgreSQL. Tarda entre 10 y 25 minutos.
  3. Deja el resultado en  reporte_validacion_python.md  (misma carpeta).

Conexión: por defecto localhost:5432, base secop_dw, usuario postgres.
Para cambiarla, editar CONFIG aquí abajo.
"""

import getpass
import os
import re
import sys
import time
import unicodedata
from datetime import date, datetime
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from pathlib import Path

import pandas as pd
import psycopg2
import psycopg2.extras

CONFIG = {
    "host": "localhost",
    "port": 5432,
    "dbname": "secop_dw",
    "user": "postgres",
}
MUESTRA_PORCENTAJE = 0.8      # % de plata que se revisa fila por fila (~100.000 filas)
SEMILLA = 42                  # misma semilla = misma muestra si se vuelve a correr

# Valores documentados en README_ETL.md
FILAS_BRONCE_ESPERADAS = 16_025_993
FILAS_PLATA_ESPERADAS = 13_005_402

# Cifras oficiales de referencia (Colombia Compra Eficiente), en billones de pesos
OFICIAL_2018 = 100            # ≈ 100 billones en el año
OFICIAL_2023_ENE_OCT = 111    # ≈ 111 billones de enero a octubre


# =====================================================================
# 1. REGLAS DE LIMPIEZA, ESCRITAS DE NUEVO EN PYTHON
#    (no se llama a ninguna función de la base)
# =====================================================================

NULOS_DISFRAZADOS = {"", "NO DEFINIDO", "NO DEFINIDA", "SIN DESCRIPCION",
                     "NO REGISTRA", "N/A", "NA", "NULL", "-"}

HOMOLOGACION = {   # mismo catálogo que silver.homologacion (17 reglas)
    ("departamento", "DISTRITO CAPITAL DE BOGOTA"): "BOGOTA D.C.",
    ("municipio", "BOGOTA"): "BOGOTA D.C.",
    ("tipo_contrato", "SUMINISTROS"): "SUMINISTRO",
    ("tipo_contrato", "OTRO TIPO DE CONTRATO"): "OTRO",
    ("modalidad", "CONTRATACION DIRECTA (LEY 1150 DE 2007)"): "CONTRATACION DIRECTA",
    ("modalidad", "CONTRATACION DIRECTA (CON OFERTAS)"): "CONTRATACION DIRECTA",
    ("modalidad", "CONTRATACION DIRECTA MENOR CUANTIA"): "CONTRATACION DIRECTA",
    ("modalidad", "CONTRATACION REGIMEN ESPECIAL"): "REGIMEN ESPECIAL",
    ("modalidad", "CONTRATACION REGIMEN ESPECIAL (CON OFERTAS)"): "REGIMEN ESPECIAL",
    ("modalidad", "CONTRATACION MINIMA CUANTIA"): "MINIMA CUANTIA",
    ("modalidad", "SELECCION ABREVIADA DE MENOR CUANTIA (LEY 1150 DE 2007)"): "SELECCION ABREVIADA",
    ("modalidad", "SELECCION ABREVIADA DE MENOR CUANTIA"): "SELECCION ABREVIADA",
    ("modalidad", "SELECCION ABREVIADA SUBASTA INVERSA"): "SELECCION ABREVIADA",
    ("modalidad", "SUBASTA"): "SELECCION ABREVIADA",
    ("modalidad", "LICITACION OBRA PUBLICA"): "LICITACION PUBLICA",
    ("modalidad", "LICITACION PUBLICA OBRA PUBLICA"): "LICITACION PUBLICA",
    ("modalidad", "CONCURSO DE MERITOS ABIERTO"): "CONCURSO DE MERITOS",
}

# Tabla de caracteres de unaccent (la misma que usa PostgreSQL: unaccent.rules).
# Se lee del servidor al arrancar (cargar_reglas_unaccent) y se aplica aquí, con
# código propio de Python. Es un catálogo de datos, igual que la homologación:
# la regla de limpieza la vuelve a escribir este script.
# Si el servidor no deja leer el archivo, se usa Unicode (NFKD) + esta tabla mínima.
REGLAS_UNACCENT = None
REGLAS_MINIMAS = {"º": "o", "ª": "a", "¼": " 1/4", "½": " 1/2", "¾": " 3/4", "¿": "?",
                  "¡": "!", "Ø": "O", "ø": "o", "Đ": "D", "đ": "d", "Ł": "L", "ł": "l",
                  "ı": "i", "Æ": "AE", "æ": "ae", "Œ": "OE", "œ": "oe", "ß": "ss",
                  "–": "-", "—": "-", "‘": "'", "’": "'", "“": '"', "”": '"', "…": "..."}


def cargar_reglas_unaccent(cur):
    """Lee unaccent.rules del servidor. Devuelve un texto que dice qué modo se usó."""
    global REGLAS_UNACCENT
    try:
        cur.execute("SELECT setting FROM pg_config WHERE name = 'SHAREDIR'")
        carpeta = cur.fetchone()["setting"]
        cur.execute("SELECT pg_read_file(%s) AS t", (carpeta + "/tsearch_data/unaccent.rules",))
        texto = cur.fetchone()["t"]
    except psycopg2.Error:
        cur.connection.rollback()
        return "tabla mínima propia (el servidor no dejó leer unaccent.rules)"
    reglas = {}
    for linea in texto.splitlines():
        if not linea:
            continue
        origen, _, destino = linea.partition("\t")
        reglas[origen] = destino
    REGLAS_UNACCENT = reglas
    return f"unaccent.rules del servidor ({len(reglas)} caracteres)"


def quitar_tildes(t):
    if REGLAS_UNACCENT is not None:
        return "".join(REGLAS_UNACCENT.get(c, c) for c in t)
    t = "".join(REGLAS_MINIMAS.get(c, c) for c in t)
    t = unicodedata.normalize("NFKD", t)
    return "".join(c for c in t if unicodedata.category(c) != "Mn")


MESES = {"JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6,
         "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12}


def limpiar_texto(t):
    """R1 + R2: sin tildes, espacios simples, sin | en los bordes, MAYÚSCULAS, nulos disfrazados a None."""
    if t is None:
        return None
    t = quitar_tildes(t)
    t = re.sub(r"\s+", " ", t)
    t = re.sub(r"^[\s|]+|[\s|]+$", "", t).upper()
    return None if t in NULOS_DISFRAZADOS else t


def homologar(campo, valor):
    """R3"""
    return HOMOLOGACION.get((campo, valor), valor)


def a_fecha(t):
    """R4 (parte 1): texto → fecha; lo que no sea una fecha real → None."""
    if t is None:
        return None
    t = t.strip(" ")
    try:
        if re.match(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}", t):
            return date(int(t[0:4]), int(t[5:7]), int(t[8:10]))
        if re.match(r"^[0-9]{2}/[0-9]{2}/[0-9]{4}", t):
            return date(int(t[6:10]), int(t[0:2]), int(t[3:5]))
        m = re.match(r"^([0-9]{4}) ([A-Za-z]{3}) ([0-9]{2})", t)
        if m and m.group(2).upper() in MESES:
            return date(int(m.group(1)), MESES[m.group(2).upper()], int(m.group(3)))
    except ValueError:          # 30 de febrero, mes 13, año 0...
        return None
    return None


def en_rango(f, minimo, maximo):
    """R4 (parte 2): fechas imposibles → None."""
    return f if f is not None and minimo <= f <= maximo else None


def a_numero(t):
    """Texto → número: quita $, comas y espacios; lo que no sea número → None."""
    if t is None:
        return None
    limpio = re.sub(r"[^0-9.\-]", "", t)
    if limpio == "":
        return None
    try:
        return Decimal(limpio)
    except InvalidOperation:
        return None


def es_relleno(v):
    """R6: 8 o más nueves (99999999) es un valor de relleno."""
    return v is not None and re.fullmatch(r"9{8,}(\.0+)?", str(v)) is not None


def a_2_decimales(v):
    return None if v is None else v.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def solo_digitos(t):
    if t is None:
        return None
    d = re.sub(r"[^0-9]", "", t).lstrip("0")
    return d or None


def dv_nit(nit):
    """Dígito de verificación de la DIAN (módulo 11)."""
    if nit is None or not re.fullmatch(r"[0-9]{1,15}", nit):
        return None
    pesos = [3, 7, 13, 17, 19, 23, 29, 37, 41, 43, 47, 53, 59, 67, 71]
    suma = sum(int(digito) * pesos[i] for i, digito in enumerate(reversed(nit)))
    r = suma % 11
    return 11 - r if r > 1 else r


def nit_base(t):
    """R8: NIT sin dígito de verificación."""
    if t is None:
        return None
    if re.fullmatch(r"\s*[0-9][0-9.\s]*-\s*[0-9]\s*", t):
        return solo_digitos(t.split("-")[0])
    d = solo_digitos(t)
    if d is None or not 5 <= len(d) <= 11:
        return None
    if len(d) >= 10 and dv_nit(d[:-1]) == int(d[-1]):
        return d[:-1]
    return d


def vacio_a_none(t):
    if t is None:
        return None
    t = t.strip(" ")
    return t or None


def limpiar_fila(b):
    """Aplica las reglas a una fila cruda de bronce y devuelve lo que plata DEBERÍA tener."""
    corte = b["fecha_carga"].date() if isinstance(b["fecha_carga"], datetime) else b["fecha_carga"]
    firma = a_fecha(b["fecha_de_firma_del_contrato"])
    inicio = a_fecha(b["fecha_inicio_ejecucion"])
    fin = a_fecha(b["fecha_fin_ejecucion"])
    firma_ok = en_rango(firma, date(2000, 1, 1), corte)
    inicio_ok = en_rango(inicio, date(2000, 1, 1), date(2060, 12, 31))
    fin_ok = en_rango(fin, date(2000, 1, 1), date(2060, 12, 31))
    valor = a_numero(b["valor_contrato"])
    valor_ok = None if es_relleno(valor) else valor
    tipo_doc = limpiar_texto(b["tipo_documento_proveedor"])
    return {
        "origen": limpiar_texto(b["origen"]),
        "id_contrato": vacio_a_none(b["numero_del_contrato"]),
        "id_proceso": vacio_a_none(b["numero_de_proceso"]),
        "nivel_entidad": limpiar_texto(b["nivel_entidad"]),
        "codigo_entidad": limpiar_texto(b["codigo_entidad_en_secop"]),
        "nombre_entidad": limpiar_texto(b["nombre_de_la_entidad"]),
        "nit_entidad": nit_base(b["nit_de_la_entidad"]),
        "departamento": homologar("departamento", limpiar_texto(b["departamento_entidad"])),
        "municipio": homologar("municipio", limpiar_texto(b["municipio_entidad"])),
        "estado_proceso": limpiar_texto(b["estado_del_proceso"]),
        "modalidad": homologar("modalidad", limpiar_texto(b["modalidad_de_contratacion"])),
        "tipo_contrato": homologar("tipo_contrato", limpiar_texto(b["tipo_de_contrato"])),
        "objeto_contrato": limpiar_texto(b["objeto_a_contratar"]),
        "fecha_firma": firma_ok,
        "fecha_inicio": inicio_ok,
        "fecha_fin": fin_ok,
        "valor_contrato": a_2_decimales(valor_ok),
        "tipo_doc_proveedor": tipo_doc,
        "documento_proveedor": (nit_base(b["documento_proveedor"])
                                if tipo_doc is not None and tipo_doc.startswith("NIT")
                                else solo_digitos(b["documento_proveedor"])),
        "nombre_proveedor": limpiar_texto(b["nom_raz_social_contratista"]),
        "url_contrato": vacio_a_none(b["url_contrato"]),
        "flag_fecha_invalida": ((firma is not None and firma_ok is None)
                                or (inicio is not None and inicio_ok is None)
                                or (fin is not None and fin_ok is None)),
        "flag_fechas_incoherentes": fin_ok is not None and inicio_ok is not None and fin_ok < inicio_ok,
        "flag_valor_cero": valor_ok is not None and valor_ok <= 0,
        "flag_valor_relleno": valor is not None and valor_ok is None,
    }


# Columna de plata → columna cruda de bronce (para mostrar ejemplos)
ORIGEN_EN_BRONCE = {
    "origen": "origen", "id_contrato": "numero_del_contrato", "id_proceso": "numero_de_proceso",
    "nivel_entidad": "nivel_entidad", "codigo_entidad": "codigo_entidad_en_secop",
    "nombre_entidad": "nombre_de_la_entidad", "nit_entidad": "nit_de_la_entidad",
    "departamento": "departamento_entidad", "municipio": "municipio_entidad",
    "estado_proceso": "estado_del_proceso", "modalidad": "modalidad_de_contratacion",
    "tipo_contrato": "tipo_de_contrato", "objeto_contrato": "objeto_a_contratar",
    "fecha_firma": "fecha_de_firma_del_contrato", "fecha_inicio": "fecha_inicio_ejecucion",
    "fecha_fin": "fecha_fin_ejecucion", "valor_contrato": "valor_contrato",
    "tipo_doc_proveedor": "tipo_documento_proveedor", "documento_proveedor": "documento_proveedor",
    "nombre_proveedor": "nom_raz_social_contratista", "url_contrato": "url_contrato",
    "flag_fecha_invalida": "fecha_de_firma_del_contrato", "flag_fechas_incoherentes": "fecha_fin_ejecucion",
    "flag_valor_cero": "valor_contrato", "flag_valor_relleno": "valor_contrato",
}

COLUMNAS_TEXTO = {"origen", "nivel_entidad", "codigo_entidad", "nombre_entidad", "departamento",
                  "municipio", "estado_proceso", "modalidad", "tipo_contrato", "objeto_contrato",
                  "tipo_doc_proveedor", "nombre_proveedor"}


def solo_letras_y_numeros(t):
    return re.sub(r"[^A-Z0-9]", "", t or "")


# =====================================================================
# 2. UTILIDADES
# =====================================================================

resultados = []          # (prueba, encontrados, estado, detalle)
ejemplos = []            # textos con ejemplos de diferencias
resultados_modo = []     # cómo se quitaron las tildes


def registrar(prueba, encontrados, detalle="", ok=None):
    estado = "OK" if (encontrados == 0 if ok is None else ok) else "REVISAR"
    resultados.append({"prueba": prueba, "encontrados": encontrados, "estado": estado, "detalle": detalle})
    print(f"  [{estado:7}] {prueba}: {encontrados}  {detalle}")


def consultar(cur, sql, params=None, titulo=None):
    if titulo:
        print(f"\n→ {titulo} ...", flush=True)
    t0 = time.time()
    cur.execute(sql, params)
    filas = cur.fetchall()
    print(f"  ({len(filas):,} filas en {time.time() - t0:,.0f} s)".replace(",", "."), flush=True)
    return filas


def miles(n):
    return f"{n:,}".replace(",", ".")


# =====================================================================
# 3. PRUEBAS
# =====================================================================

def prueba_a_conteos(cur):
    filas = consultar(cur, """
        SELECT (SELECT count(*) FROM bronze.secop_raw)  AS bronce,
               (SELECT count(*) FROM silver.contratos)  AS plata,
               (SELECT count(*) FROM silver.contratos s
                 WHERE NOT EXISTS (SELECT 1 FROM bronze.secop_raw b WHERE b.id_fila = s.id_fila))
                                                         AS plata_sin_origen
    """, titulo="A. Conteos")
    r = filas[0]
    registrar("A1. Filas en bronce", miles(r["bronce"]), f"esperado {miles(FILAS_BRONCE_ESPERADAS)}",
              ok=r["bronce"] == FILAS_BRONCE_ESPERADAS)
    registrar("A2. Filas en plata", miles(r["plata"]), f"esperado {miles(FILAS_PLATA_ESPERADAS)}",
              ok=r["plata"] == FILAS_PLATA_ESPERADAS)
    registrar("A3. Filas de plata que no vienen de bronce", r["plata_sin_origen"])


def prueba_b_muestra(cur):
    columnas_plata = ["origen", "id_contrato", "id_proceso", "nivel_entidad", "codigo_entidad",
                      "nombre_entidad", "nit_entidad", "departamento", "municipio", "estado_proceso",
                      "modalidad", "tipo_contrato", "objeto_contrato", "fecha_firma", "fecha_inicio",
                      "fecha_fin", "valor_contrato", "tipo_doc_proveedor", "documento_proveedor",
                      "nombre_proveedor", "url_contrato", "flag_fecha_invalida",
                      "flag_fechas_incoherentes", "flag_valor_cero", "flag_valor_relleno"]
    columnas_bronce = ["origen", "numero_del_contrato", "numero_de_proceso", "nivel_entidad",
                       "codigo_entidad_en_secop", "nombre_de_la_entidad", "nit_de_la_entidad",
                       "departamento_entidad", "municipio_entidad", "estado_del_proceso",
                       "modalidad_de_contratacion", "tipo_de_contrato", "objeto_a_contratar",
                       "fecha_de_firma_del_contrato", "fecha_inicio_ejecucion", "fecha_fin_ejecucion",
                       "valor_contrato", "tipo_documento_proveedor", "documento_proveedor",
                       "nom_raz_social_contratista", "url_contrato", "fecha_carga"]
    sql = f"""
        SELECT s.id_fila,
               {", ".join(f"s.{c} AS p_{c}" for c in columnas_plata)},
               {", ".join(f"b.{c} AS {c}" for c in columnas_bronce)}
        FROM silver.contratos s TABLESAMPLE BERNOULLI ({MUESTRA_PORCENTAJE}) REPEATABLE ({SEMILLA})
        JOIN bronze.secop_raw b ON b.id_fila = s.id_fila
    """
    filas = consultar(cur, sql, titulo=f"B. Muestra al azar de plata ({MUESTRA_PORCENTAJE} %) "
                                        "limpiada de nuevo en Python")
    diferencias = {c: 0 for c in columnas_plata}
    solo_simbolos = {c: 0 for c in columnas_plata}
    muestras = {c: [] for c in columnas_plata}
    for f in filas:
        esperado = limpiar_fila(f)
        for c in columnas_plata:
            real, calc = f[f"p_{c}"], esperado[c]
            if real == calc:
                continue
            if (c in COLUMNAS_TEXTO and real is not None and calc is not None
                    and solo_letras_y_numeros(real) == solo_letras_y_numeros(calc)):
                solo_simbolos[c] += 1          # p. ej. un símbolo raro que unaccent traduce distinto
                continue
            diferencias[c] += 1
            if len(muestras[c]) < 3:
                muestras[c].append((f["id_fila"], f[ORIGEN_EN_BRONCE[c]], real, calc))

    n = len(filas)
    registrar("B0. Filas revisadas en la muestra", miles(n), ok=n > 0)
    reglas = {"origen": "R1", "nivel_entidad": "R1-R2", "codigo_entidad": "R1", "nombre_entidad": "R1",
              "departamento": "R1-R3", "municipio": "R1-R3", "estado_proceso": "R1-R2",
              "modalidad": "R1-R3", "tipo_contrato": "R1-R3", "objeto_contrato": "R1",
              "tipo_doc_proveedor": "R1-R2", "nombre_proveedor": "R1", "nit_entidad": "R8",
              "documento_proveedor": "R8", "fecha_firma": "R4", "fecha_inicio": "R4",
              "fecha_fin": "R4", "valor_contrato": "R6", "flag_fecha_invalida": "R4",
              "flag_fechas_incoherentes": "R4", "flag_valor_cero": "R6", "flag_valor_relleno": "R6",
              "id_contrato": "-", "id_proceso": "-", "url_contrato": "-"}
    for c in columnas_plata:
        detalle = f"({reglas[c]})"
        if solo_simbolos[c]:
            detalle += f" · {solo_simbolos[c]} difieren solo en símbolos especiales (aceptable)"
        registrar(f"B. {c}: plata ≠ Python", diferencias[c], detalle)
        for id_fila, crudo, real, calc in muestras[c]:
            ejemplos.append(f"- `{c}` id_fila {id_fila}: bronce=`{crudo}` · plata=`{real}` · Python=`{calc}`")

    # Revisiones directas sobre el resultado de plata (no dependen de la re-limpieza)
    df = pd.DataFrame([{c: f[f"p_{c}"] for c in columnas_plata} for f in filas])
    textos = df[sorted(COLUMNAS_TEXTO)].astype("string")
    registrar("B. Textos con minúsculas", int(textos.apply(lambda s: s.str.contains(r"[a-z]", na=False)).any(axis=1).sum()))
    registrar("B. Textos con tildes o Ñ", int(textos.apply(lambda s: s.str.contains(r"[ÁÉÍÓÚÜÑáéíóúüñ]", na=False)).any(axis=1).sum()))
    registrar("B. Textos con espacios dobles o en los bordes",
              int(textos.apply(lambda s: s.str.contains(r"\s{2,}|^\s|\s$", na=False)).any(axis=1).sum()))
    registrar("B. Nulos disfrazados que siguen como texto",
              int(textos.apply(lambda s: s.isin(list(NULOS_DISFRAZADOS))).any(axis=1).sum()))
    docs = df[["nit_entidad", "documento_proveedor"]].astype("string")
    registrar("B. NIT o documento con algo distinto de dígitos",
              int(docs.apply(lambda s: s.str.contains(r"[^0-9]", na=False)).any(axis=1).sum()))


def prueba_c_duplicados(cur):
    filas = consultar(cur, """
        SELECT count(*) - count(DISTINCT (origen, id_contrato, id_proceso, documento_proveedor,
                                          valor_contrato, fecha_firma)) AS sobrantes
        FROM silver.contratos
    """, titulo="C1. Filas repetidas en plata (R5)")
    registrar("C1. Filas repetidas en plata", filas[0]["sobrantes"])

    columnas = ["id_fila", "origen", "numero_del_contrato", "numero_de_proceso", "nivel_entidad",
                "codigo_entidad_en_secop", "nombre_de_la_entidad", "nit_de_la_entidad",
                "departamento_entidad", "municipio_entidad", "estado_del_proceso",
                "modalidad_de_contratacion", "tipo_de_contrato", "objeto_a_contratar",
                "fecha_de_firma_del_contrato", "fecha_inicio_ejecucion", "fecha_fin_ejecucion",
                "valor_contrato", "tipo_documento_proveedor", "documento_proveedor",
                "nom_raz_social_contratista", "url_contrato", "fecha_carga"]
    eliminadas = consultar(cur, f"""
        SELECT {", ".join("b." + c for c in columnas)}
        FROM bronze.secop_raw b TABLESAMPLE BERNOULLI (0.05) REPEATABLE ({SEMILLA})
        WHERE NOT EXISTS (SELECT 1 FROM silver.contratos s WHERE s.id_fila = b.id_fila)
        LIMIT 1000
    """, titulo="C2. Filas que la deduplicación quitó: ¿tienen su gemela en plata?")
    llaves = []
    sin_id = 0
    for b in eliminadas:
        e = limpiar_fila(b)
        if e["id_contrato"] is None or e["id_proceso"] is None:
            sin_id += 1
            continue
        llaves.append((b["id_fila"], (e["origen"], e["id_contrato"], e["id_proceso"],
                                      e["documento_proveedor"], e["valor_contrato"], e["fecha_firma"])))
    if not llaves:
        registrar("C2. Filas eliminadas sin gemela en plata", 0, "no hubo filas para revisar")
        return
    candidatas = consultar(cur, """
        SELECT id_fila, origen, id_contrato, id_proceso, documento_proveedor, valor_contrato, fecha_firma
        FROM silver.contratos
        WHERE id_contrato = ANY(%s) AND id_proceso = ANY(%s)
    """, ([k[1] for _, k in llaves], [k[2] for _, k in llaves]))
    gemelas = {}
    for s in candidatas:
        llave = (s["origen"], s["id_contrato"], s["id_proceso"], s["documento_proveedor"],
                 s["valor_contrato"], s["fecha_firma"])
        gemelas[llave] = min(gemelas.get(llave, s["id_fila"]), s["id_fila"])
    sin_gemela = [id_fila for id_fila, llave in llaves
                  if llave not in gemelas or gemelas[llave] > id_fila]
    registrar("C2. Filas eliminadas sin gemela en plata", len(sin_gemela),
              f"de {len(llaves)} revisadas ({sin_id} omitidas por no tener número de contrato o proceso)")
    for id_fila in sin_gemela[:5]:
        ejemplos.append(f"- Fila eliminada sin gemela: id_fila {id_fila}")


def prueba_d_versiones(cur):
    existe = consultar(cur, """
        SELECT count(*) AS n FROM information_schema.columns
        WHERE table_schema = 'silver' AND table_name = 'contratos'
          AND column_name IN ('flag_version_contrato', 'flag_valor_extremo')
    """, titulo="D. Versiones de SECOP II (R7b)")
    if existe[0]["n"] < 2:
        registrar("D. Versiones SECOP II", "no aplica", "falta correr 02c_correccion_valores.sql", ok=False)
        return
    filas = consultar(cur, f"""
        WITH g AS (
            SELECT id_contrato, coalesce(documento_proveedor, '') AS doc
            FROM silver.contratos
            WHERE flag_version_contrato
            GROUP BY 1, 2
            ORDER BY md5(id_contrato || coalesce(documento_proveedor, '') || '{SEMILLA}')
            LIMIT 2000
        )
        SELECT s.id_contrato, coalesce(s.documento_proveedor, '') AS doc,
               s.valor_contrato, s.valor_ajustado
        FROM silver.contratos s
        JOIN g ON g.id_contrato = s.id_contrato AND g.doc = coalesce(s.documento_proveedor, '')
        WHERE s.flag_version_contrato
    """)
    df = pd.DataFrame(filas, columns=["id_contrato", "doc", "valor_contrato", "valor_ajustado"])
    grupos = df.groupby(["id_contrato", "doc"])
    malos = 0
    for (id_contrato, _), g in grupos:
        n = len(g)
        promedio = sum(g["valor_contrato"]) / n
        suma_ajustada = sum(g["valor_ajustado"])
        cada_fila_ok = all(a == a_2_decimales(v / n) for v, a in zip(g["valor_contrato"], g["valor_ajustado"]))
        if abs(suma_ajustada - promedio) > Decimal("0.01") * n or not cada_fila_ok:
            malos += 1
            if malos <= 3:
                ejemplos.append(f"- Versión mal ajustada: contrato {id_contrato}, {n} versiones, "
                                f"promedio {promedio:.2f}, suma ajustada {suma_ajustada}")
    registrar("D. Contratos cuya suma ajustada no es el promedio de sus versiones", malos,
              f"de {miles(grupos.ngroups)} contratos revisados")


def prueba_e_extremos(cur):
    filas = consultar(cur, """
        SELECT id_fila, nombre_entidad, nombre_proveedor, valor_contrato, flag_valor_atipico
        FROM silver.contratos WHERE flag_valor_extremo ORDER BY valor_contrato DESC
    """, titulo="E. Valores extremos marcados (R9b)")
    mal = [f for f in filas if not f["flag_valor_atipico"] or f["valor_contrato"] <= Decimal("1e12")]
    registrar("E. Extremos marcados", len(filas), "esperado 10", ok=len(filas) == 10)
    registrar("E. Extremos sin excluir o por debajo de 1 billón", len(mal))
    for f in filas:
        ejemplos.append(f"- Extremo: {f['nombre_entidad']} → {f['nombre_proveedor']}: "
                        f"{f['valor_contrato'] / Decimal('1e12'):.2f} billones")


def prueba_f_totales(cur):
    filas = consultar(cur, """
        SELECT extract(year FROM fecha_firma)::int AS anio,
               sum(valor_ajustado) FILTER (WHERE NOT flag_valor_atipico) AS sin_atipicos
        FROM silver.contratos
        WHERE fecha_firma IS NOT NULL
        GROUP BY 1 ORDER BY 1
    """, titulo="F. Totales por año frente a las cifras oficiales")
    df = pd.DataFrame(filas, columns=["anio", "sin_atipicos"])
    df["billones"] = df["sin_atipicos"].apply(lambda v: round(float(v or 0) / 1e12, 2))
    print(df[["anio", "billones"]].to_string(index=False))
    por_anio = dict(zip(df["anio"], df["billones"]))
    v2018, v2023 = por_anio.get(2018, 0), por_anio.get(2023, 0)
    registrar("F1. 2018 (oficial ≈ 100 billones)", v2018, "tolerancia ±15 %",
              ok=abs(v2018 - OFICIAL_2018) <= 0.15 * OFICIAL_2018)
    registrar("F2. 2023 (oficial ≈ 111 billones de enero a octubre)", v2023,
              "el año completo debe ser mayor y no exagerado (111–160)",
              ok=OFICIAL_2023_ENE_OCT <= v2023 <= 160)
    completos = df[(df["anio"] >= 2017) & (df["anio"] <= 2025)]
    fuera = completos[(completos["billones"] < 60) | (completos["billones"] > 200)]
    registrar("F3. Años 2017–2025 fuera de 60–200 billones", len(fuera),
              ", ".join(str(a) for a in fuera["anio"]))


# =====================================================================
# 4. PROGRAMA PRINCIPAL
# =====================================================================

def main():
    sys.stdout.reconfigure(errors="replace")   # consola de Windows: no fallar por un símbolo
    print("Validación independiente de la capa plata (Python)\n")
    clave = os.environ.get("PGPASSWORD") or getpass.getpass(
        f"Contraseña de PostgreSQL para {CONFIG['user']}: ")
    inicio = time.time()
    try:
        conexion = psycopg2.connect(password=clave, **CONFIG)
    except psycopg2.OperationalError as e:
        sys.exit(f"No se pudo conectar a la base: {e}")
    conexion.set_session(readonly=True)          # garantía: este script no puede modificar nada
    cur = conexion.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    modo = cargar_reglas_unaccent(cur)
    print(f"Tabla de tildes y símbolos: {modo}")
    resultados_modo.append(modo)

    for prueba in (prueba_a_conteos, prueba_b_muestra, prueba_c_duplicados,
                   prueba_d_versiones, prueba_e_extremos, prueba_f_totales):
        prueba(cur)
    conexion.close()

    tabla = pd.DataFrame(resultados)
    revisar = tabla[tabla["estado"] == "REVISAR"]
    minutos = (time.time() - inicio) / 60
    print("\n" + "=" * 70)
    print(f"RESUMEN: {len(tabla) - len(revisar)} de {len(tabla)} pruebas en OK · {minutos:.1f} min")
    if len(revisar):
        print("Pruebas para revisar:")
        print(revisar[["prueba", "encontrados"]].to_string(index=False))

    salida = Path(__file__).with_name("reporte_validacion_python.md")
    with open(salida, "w", encoding="utf-8") as f:
        f.write("# Validación independiente de la capa plata (Python)\n\n")
        f.write(f"Fecha: {datetime.now():%Y-%m-%d %H:%M} · Duración: {minutos:.1f} min · "
                f"Muestra: {MUESTRA_PORCENTAJE} % de plata, semilla {SEMILLA}\n\n"
                f"Tabla de tildes y símbolos: {resultados_modo[0]}\n\n")
        f.write(f"**{len(tabla) - len(revisar)} de {len(tabla)} pruebas en OK**\n\n")
        f.write("| Prueba | Encontrados | Estado | Detalle |\n|---|---|---|---|\n")
        for r in resultados:
            f.write(f"| {r['prueba']} | {r['encontrados']} | {r['estado']} | {r['detalle']} |\n")
        if ejemplos:
            f.write("\n## Ejemplos\n\n" + "\n".join(ejemplos) + "\n")
    print(f"\nReporte guardado en: {salida}")


if __name__ == "__main__":
    main()
