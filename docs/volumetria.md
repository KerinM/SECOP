# Volumetría — SECOP Integrado

**Entregable 1 de 5** · Responsable: **Kerin** (rol: Analista de Datos)
**Corte vigente:** `secop_dw` · descargado el **29/09/2026**
**Fuente:** [SECOP Integrado — datos.gov.co](https://www.datos.gov.co/Estad-sticas-Nacionales/SECOP-Integrado/rpmr-utcd) · ID Socrata `rpmr-utcd`

---

## 1. Cambio de corte: qué hay que saber antes de leer este documento

El proyecto tuvo **dos cortes de datos** y este documento describe el vigente. Si encontras cifras de `secop_integrado` por ahí, son del corte anterior.

| | Corte anterior (retirado) | **Corte vigente (`secop_dw`)** |
|---|---|---:|
| Base | `secop_integrado` | **`secop_dw`** |
| Contratos firmados | 2000 – 2026 | **2017 – 2026** |
| Archivos de origen | 454 CSV | **10 CSV (uno por año)** |
| Filas en la capa cruda | 22.670.028 | **16.025.993** |
| Esquema de la capa cruda | `staging` | **`bronze`** (`bronze.secop_raw`) |
| Tabla limpia | `silver.contrato` | **`silver.contratos`** |
| Filas tras limpiar | 22.670.028 (fiel al origen) | **13.005.402** (deduplicada) |
| Columnas de origen | 22 | **16** |

Dos diferencias cambian cómo se lee todo lo demás:

1. **El rango temporal se acortó a 2017-2026.** Por eso `fact_contrato` tiene 13 particiones y no 30.
2. **Plata ahora deduplica.** La regla R5 elimina filas idénticas (mismo origen, contrato, proceso, proveedor, valor y fecha). Es la **única** regla destructiva del ETL; las otras diez corrigen, marcan o calculan. Por eso 16.025.993 → 13.005.402 y por eso el grano en oro es la versión y no el registro bruto.

---

## 2. Fuente y método de medición

Las cifras de este documento se **midieron**, no se estimaron a ojo. Tres vías:

| Vía | Qué permite |
|---|---|
| **API Socrata (SoQL)** | Conteos y distribuciones exactas sin descargar nada: `?$select=...&$group=...` |
| **Descarga por años** | 10 CSV, uno por año, con gzip vía `/resource/` |
| **PostgreSQL** | `count(*)` y `pg_total_relation_size()` sobre la base cargada |

> **Advertencia metodológica que sigue vigente.** La metadata en caché del portal (`cachedContents`) **está desfasada**. En el corte anterior mostraba 20.800.218 filas cuando la verdad eran 22.670.028, un desfase de −1.869.810.
>
> **Conclusión, y es la razón de que RF-19 obligue a recontar en PostgreSQL después de cargar: el conteo nunca debe tomarse de la ficha del portal.** Se cuenta con `count(*)` sobre la API o sobre la tabla cargada.

### 2.1 Verificación del requisito de volumen

> Requisito: base de datos con **más de 10 millones de registros** y **modelo relacional**.

| Criterio | Resultado | Estado |
|---|---|---:|
| Más de 10.000.000 de registros | **13.005.402** (plata) · **16.025.993** (bronce) | ✅ Cumplido |
| Cobertura geográfica | Departamentos normalizados a 35 categorías | ✅ Nacional |
| Cobertura temporal | 2017 – 2026 | ✅ 10 años |
| 2 plataformas integradas | `SECOPI` + `SECOPII` | ✅ |

### 2.2 Sobre el carácter "relacional"

**El origen NO es relacional.** Es un CSV plano de 16 columnas con una fila = un registro de contrato, que repite nombre de entidad, departamento, modalidad y proveedor en cada fila.

**Sí es modelable a relacional**, porque tiene 7 dimensiones naturales identificables más el tiempo. El modelo en estrella del Entregable 2 sale de aquí, y su volumetría está en la sección 5.

---

## 3. Volumetría de origen (medida)

### 3.1 Las dos capas y su cuadre

| Capa | Tabla | Filas | Δ |
|---|---|---:|---:|
| Cruda | `bronze.secop_raw` | **16.025.993** | — |
| Limpia | `silver.contratos` | **13.005.402** | **−3.020.591 (−18,85%)** |

La diferencia son exactamente las filas que la regla R5 elimina por duplicadas. **Cero filas perdidas** por error de carga: la validación de plata da **42/42 pruebas OK**.

### 3.2 Reparto por archivo de origen

La descarga es de 10 archivos, uno por año, y `id_fila` se asigna de forma correlativa:

| Archivo | Rango de `id_fila` |
|---|---|
| `secop_2017.csv` | 1 … 1.498.976 |
| … | … |
| `secop_2026.csv` | … … 16.025.993 |

> **Consecuencia para la trazabilidad.** `id_fila` es correlativo por archivo de descarga. Por eso `gold.fact_contrato.id_fila` **hereda** esa numeración y no genera una identidad nueva: es lo que permite auditar una cifra de oro hasta el CSV de origen con un solo `JOIN`. El precio es que hay que reconstruir oro si bronce se recarga con otro orden. Ver `modelo_relacional.md` §9.

### 3.3 Dimensiones del origen

Las cardinalidades **exactas del corte vigente no están medidas todavía**: no se ejecutaron consultas de conteo sobre `silver.contratos` en este corte. La tabla las marca como pendientes, con la consulta que las produce.

| Dimensión | Origen | Valores distintos |
|---|---|---:|
| Entidad contratante | `codigo_entidad`, `nombre_entidad`, `nit_entidad`, `nivel_entidad` | *pendiente* |
| Proveedor | `documento_proveedor`, `nombre_proveedor`, `tipo_doc_proveedor` | *pendiente* |
| Ubicación | `departamento`, `municipio` (atributo de la entidad) | *pendiente* |
| Tipo de contrato | `tipo_contrato` | *pendiente* |
| Modalidad | `modalidad` | *pendiente* |
| Estado | `estado_proceso` | *pendiente* |
| Origen | `origen` | **2** (`SECOPI`, `SECOPII`) |
| Tiempo | `fecha_firma`, `fecha_inicio`, `fecha_fin` | calendario fijo |

**Estructural, sin depender de los datos:**

| Objeto | Cardinalidad | Por qué se conoce |
|---|---:|---|
| `dim_tiempo` | **47.847** | Días exactos de 1900-01-01 a 2030-12-31, por construcción |
| `dim_origen` | **2** | Las dos plataformas de SECOP |
| Registros `-1` por dimensión | **1** cada uno | Por construcción, uno por dimensión categórica |
| Particiones de `fact_contrato` | **13** | 11 anuales (2017-2027) + cuarentena + por defecto |
| **Medido en plata** | | |
| Valores marcados `flag_valor_atipico` | **33.928** | Regla R9 + R9b |
| Contratos con versiones | **554.063** | Regla R7b |
| De ellos, cambian de número de proceso entre versiones | **4.720 (0,85%)** | |
| De ellos, cambian de fecha de firma entre versiones | **116** | |
| Nombres de proveedor con barra suelta en los bordes | **538** | Corregidos por `02b_correccion_barras.sql` |
| Reglas del catálogo `silver.homologacion` | **17** | |
| Variantes de `nivel_entidad` | **7 → 3** (+ vacío) | Regla R3 |

### 3.4 Completitud por columna

**No medida en el corte vigente.** Las tres columnas de fecha concentran el 100% de los nulos: SECOP I no exige fecha de ejecución, SECOP II sí. Es un patrón estable entre cortes y se confirma con `05_qa_silver.sql` prueba 1.

---

## 4. Calidad del dato que afecta a la volumetría

Estas cuatro cosas **cambian el número** y por eso se tratan en plata, no en oro. Las cuatro están medidas.

| Anomalía | Medición | Qué hace plata |
|---|---:|---|
| **Duplicados exactos** | 3.020.591 filas (−18,85%) | R5 los elimina |
| **Valores atípicos** | 33.928 | R9 (Tukey por tipo) y R9b (imposibles para su entidad) los **marcan**, no los borran |
| **Fechas imposibles** | Regla R4 | `< 2000`, `> 2060` o posteriores a la descarga → `NULL` + `flag_fecha_invalida` |
| **Barras sueltas en nombres** | 538 | `02b` las quita; **idempotente**: `UPDATE 538` la primera vez, `UPDATE 0` la segunda |

Además, y sin corrección posible:

- **Fechas incoherentes entre sí:** 670 contratos con duración negativa y 662 con `fecha_fin` anterior a `fecha_inicio`. Se marcan con `es_fechas_incoherentes` y **no se corrigen**: son hechos del dato, no errores de carga.
- **Texto dañado desde SECOP:** la `ñ` llega como `���` (ej. `NI���O` en vez de `NIÑO`). La limpieza no lo repara con seguridad porque no se sabe qué letra era, y queda como `NII? 1/2O`. **Solo afecta nombres y textos; no afecta valores, fechas ni llaves.**

### 4.1 Por qué las banderas viajan a oro

Oro no recalcula nada de esto: copia las banderas de plata **eliminando el prefijo `flag_`**. Un tablero filtra por `es_atipico`, `es_fecha_invalida` o `es_valor_extremo` sin volver a plata, y cada KPI de dinero aplica `NOT es_atipico`.

Es la razón de que la regla R9 **marque en vez de borrar**: borrar el dato anómalo sería más limpio y **peor**, porque ocultaría el vacío. Marcado, el número es auditable.

---

## 5. Proyección a PostgreSQL

Entorno destino: **PostgreSQL 18.6** en `localhost:5432`, UTF-8, 15,3 GB RAM, 12 núcleos lógicos.

### 5.1 Método de cálculo

En PostgreSQL una tupla ocupa: **23 B de cabecera** + bitmap de nulos (redondeado a 2) + **padding de alineación a 8 B** + datos, donde cada `text` añade 1–4 B de cabecera `varlena` y cada `date` ocupa **4 B** (no ~20 B como en el CSV).

Este cálculo se validó con −1,6% de error en el corte anterior, así que es fiable. Lo que **no** se puede calcular con muestra es el número de claves distintas de un texto libre: eso solo se sabe recorriéndolo.

### 5.2 Por bytes/fila no se puede proyectar `gold` sin medir

Cada columna de texto largo tiene un tamaño muy distinto, pero el peso relativo es estable entre cortes porque viene del **mismo dataset**:

| Columna | % del payload |
|---|---:|
| Objetos textuales (2 columnas) | **50,8%** |
| `url_contrato` | 9,8% |
| `nombre_entidad` | 6,3% |
| `modalidad` | 4,0% |
| resto | 29,1% |

**Consecuencia de diseño:** la mitad del payload son dos columnas de texto libre. Es el mayor vector de tamaño de `fact_contrato` y el motivo de que el modelo no «descarte» `objeto_del_proceso` sin una decisión explícita del proyecto.

### 5.3 Qué se sabe del tamaño de `gold`

**No medido todavía.** El corte vigente no tiene `gold` cargada. Se obtiene con `pg_total_relation_size()` sobre cada tabla y cada índice (consulta 11.2 de `decisiones_tecnicas.md` y bloque 9 del DDL).

Lo que sí se puede afirmar sin medir:

| Afirmación | Base |
|---|---|
| `gold` es **más pequeño que bronce y plata** | Las dimensiones absorben la repetición: entidad, proveedor y ubicación dejan de repetirse 13 millones de veces |
| `dim_tiempo` ocupa ~1 MB | 47.847 filas de calendario, tamaño fijo |
| Las 6 dimensiones categóricas son **pequeñas** | Cardinalidades de 2 a decenas de valores |
| `fact_contrato` domina el tamaño | Tiene todas las medidas y los dos textos |

### 5.4 Decisiones de tamaño ya tomadas

| Decisión | Ahorro | Motivo |
|---|---|---|
| **BRIN** en vez de B-tree para fechas | ×1/160 | El orden de carga es por año, así que las páginas ya están ordenadas |
| **Sin índice sobre `es_atipico`** | — | 33.928 en `true` sobre 13 millones: un índice sobre el 99,7% de falsos no lo usa nadie |
| **Sin índice sobre `valor_ajustado` suelto** | — | Redundante con el índice compuesto por año y valor |
| **Sin `fecha_firma_original` en oro** | ~52 MB | Plata borró el original (R4 lo puso en `NULL`); guardarlo sería una copia de `fecha_firma`. Vive en bronce |
| **Sin `codigo_proceso`** | ~170 MB | `numero_proceso` ya contiene el código; duplicarlo no recupera nada |

Las dos últimas se tomaron **al construir el DDL**, no después: se detectó que columnas que el modelo anterior cargaba ya no tenían fuente real en plata.

---

## 6. Particionamiento

### 6.1 Criterio y número

`fact_contrato` se particiona por **RANGE sobre `fecha_firma`**, y son **13 particiones**:

| Tipo | Rango | Cantidad |
|---|---|---:|
| Anual | 2017 … 2027 | **11** |
| Cuarentena | 1900-01-01 → 2000-01-01 | 1 |
| Por defecto | el resto | 1 |

La cuarentena existe por el centinela: las filas sin fecha válida caen en `1900-01-01` y se concentran ahí. Es una característica del diseño, no un remanente.

El rango va hasta **2027** aunque el dato termine en 2026, para que un año de consultas más no exija un `CREATE TABLE`.

### 6.2 Beneficios

| Beneficio | Detalle |
|---|---|
| Consultas por año | 1 de 13 particiones |
| `VACUUM` / `ANALYZE` | Por partición, no 13 millones de filas de una vez |
| Índices | Cada índice de partición es 13 veces más pequeño → caben en RAM |
| Mantenimiento | Reindexar un año no bloquea los otros |
| Crecimiento | Añadir 2028 = un `CREATE TABLE`, sin migrar filas |

### 6.3 Trade-off explícito

> PostgreSQL **no** permite índice único ni clave primaria que **no incluyan la clave de partición**. Con particionado por año, la PK tiene que ser compuesta: `(fecha_firma, id_fila)`.
>
> **Alternativa evaluada y rechazada:** tabla sin particionar, para permitir `PK (id_fila)`. Con 15,3 GB de RAM y una tabla de 13 millones de filas, el `VACUUM` completo y los índices no caben. Se particiona y se acepta la PK compuesta.
>
> **Efecto lateral útil:** como la PK empieza por `fecha_firma`, los rangos de fecha ya quedan cubiertos y no hace falta un B-tree extra sobre la fecha.

---

## 7. Crecimiento proyectado

**Proyección, no medición.** Se apoya en que el rango del corte vigente es 2017-2026 y en que la tasa de crecimiento medida en el corte anterior fue de +1,7M a +2,0M filas/año.

| Año | Filas acumuladas en plata | Tamaño CSV estimado | `gold` estimado |
|---|---:|---:|---:|
| 2026 (corte 29/09) | **13,0M** *(medido)* | 12,5 – 14 GiB | por medir |
| 2027 | ~14,5M | 14 – 16 GiB | por medir |
| 2028 | ~16,2M | 15,5 – 17,5 GiB | por medir |
| 2029 | ~18,0M | 17 – 19 GiB | por medir |
| 2030 | ~19,9M | 19 – 21 GiB | por medir |

**Advertencia de la proyección:** el corte vigente eliminó 2016 y anteriores, así que la serie histórica de crecimiento del corte anterior **no es comparable** con esta. La proyección cubre solo el rango 2017+ y hay que revisarla en el próximo corte, con dos puntos medidos en lugar de uno.

---

## 8. Riesgo de capacidad

### 8.1 Recursos de la máquina

| Recurso | Disponible | Necesario | Margen |
|---|---:|---:|---:|
| Disco libre (C:) | **129 GB** | CSV + 3 capas ≈ 40 GB | ~89 GB |
| RAM | **15,3 GB** | 8 GB (PostgreSQL) | 7,3 GB |
| Núcleos | 12 | 2 (carga `COPY`) | 10 |
| Puerto 5432 | Libre · PostgreSQL 18.6 activo | — | — |

**Veredicto: capacidad suficiente.** El corte vigente tiene 30% menos filas que el anterior, así que el margen mejoró.

### 8.2 Riesgo de tiempo de descarga

| Método | Velocidad medida | Para 16M filas |
|---|---|---|
| Endpoint oficial (monocanal, sin gzip) | 0,5 – 1,2 MB/s | 4 – 10 h ⚠️ |
| API paginada, 4 conexiones en paralelo | 4 – 9 MB/s | 30 – 50 min ✅ |

**Estrategia adoptada:** descarga por años con la API `/resource/`, que además entrega gzip. Detalle en `etl_carga.md` (Entregable 4, responsable **José**).

### 8.3 Riesgo de memoria durante la carga

Cargar 13M filas con `COPY` en un solo lote dispara la memoria. **Mitigación:** lotes de 250.000 filas con `commit` por lote.

La carga de `gold` tiene el mismo riesgo y por eso el DDL expone `lote_desde` y `lote_hasta` para insertar por tramos. Ver la sección 6.2 del DDL, que explica por qué los bloques anteriores son idempotentes y por qué eso es lo que hace viable el recorrido por tramos.

---

## 9. Consultas para convertir estas estimaciones en mediciones

Se ejecutan **después de construir y cargar `gold`**. El bloque 9 del DDL ya incluye las que corresponden a las secciones 3.3 y 5.3; aquí están las de verificación de capa.

```sql
-- 9.1 Conteo real por capa. Los tres numeros deben cuadrar:
--      bronce = 16.025.993, plata = 13.005.402, oro = plata.
SELECT (SELECT count(*) FROM bronze.secop_raw) AS bronce,
       (SELECT count(*) FROM silver.contratos) AS plata,
       (SELECT count(*) FROM gold.fact_contrato) AS oro;

-- 9.2 Tamaño real por tabla (confirma la seccion 5.3)
SELECT relname AS tabla, n_live_tup AS filas,
       pg_size_pretty(pg_table_size(relid))           AS tabla_solo,
       pg_size_pretty(pg_indexes_size(relid))         AS indices,
       pg_size_pretty(pg_total_relation_size(relid)) AS total
FROM pg_stat_user_tables
WHERE schemaname = 'gold'
ORDER BY pg_total_relation_size(relid) DESC;

-- 9.3 Cardinalidades reales de las dimensiones (completa la seccion 3.3)
SELECT 'dim_entidad'       AS dimension, count(*) AS filas FROM gold.dim_entidad
UNION ALL SELECT 'dim_proveedor',     count(*) FROM gold.dim_proveedor
UNION ALL SELECT 'dim_tipo_contrato', count(*) FROM gold.dim_tipo_contrato
UNION ALL SELECT 'dim_modalidad',     count(*) FROM gold.dim_modalidad
UNION ALL SELECT 'dim_estado',        count(*) FROM gold.dim_estado
UNION ALL SELECT 'dim_origen',        count(*) FROM gold.dim_origen
UNION ALL SELECT 'dim_tiempo',        count(*) FROM gold.dim_tiempo
ORDER BY filas DESC;

-- 9.4 Tamaño real por particion (confirma la seccion 6.1: deben ser 13)
SELECT c.relname AS particion,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total,
       pg_get_expr(c.relpartbound, c.oid)            AS rango
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE i.inhparent = 'gold.fact_contrato'::regclass
ORDER BY c.relname;

-- 9.5 Bytes reales por fila en plata
SELECT pg_size_pretty(pg_table_size('silver.contratos')) AS tabla,
       pg_table_size('silver.contratos')::bigint / count(*) AS bytes_por_fila,
       count(*) AS filas
FROM silver.contratos;

-- 9.6 Tamaño de los indices de una tabla particionada.
-- OJO: pg_stat_user_indexes no tiene filas para el padre de una tabla
-- particionada, porque el padre no almacena paginas. Hay que recorrer
-- pg_inherits. Esto fue un error real durante la carga anterior
-- (ver bitacora_sesiones.md).
SELECT c.relname AS indice_padre,
       pg_size_pretty(COALESCE(s.tam, 0::bigint)) AS espacio_en_particiones
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
LEFT JOIN LATERAL (
    SELECT sum(pg_relation_size(ci.oid)) AS tam
    FROM pg_inherits ih
    JOIN pg_class ci ON ci.oid = ih.inhrelid
    WHERE ih.inhparent = i.indexrelid
) s ON true
WHERE i.indrelid = 'gold.fact_contrato'::regclass
ORDER BY COALESCE(s.tam, 0::bigint) DESC;

-- 9.7 Donde viven realmente las particiones.
-- Esta consulta destapo el bug del corte anterior: 28 de 30 particiones
-- estaban en 'public' en vez de 'gold'. El sintoma era que gold.fact_contrato
-- existia pero las consultas noodian datos.
SELECT n.nspname AS esquema, c.relname AS particion, c.relispartition,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS tamano
FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE i.inhparent = 'gold.fact_contrato'::regclass
ORDER BY n.nspname, c.relname;

-- 9.8 Completitud por columna en plata (completa la seccion 3.4)
SELECT
  count(*) FILTER (WHERE fecha_firma   IS NULL) * 100.0 / count(*) AS nul_firma,
  count(*) FILTER (WHERE fecha_inicio  IS NULL) * 100.0 / count(*) AS nul_inicio,
  count(*) FILTER (WHERE fecha_fin     IS NULL) * 100.0 / count(*) AS nul_fin,
  count(*) FILTER (WHERE documento_proveedor IS NULL) * 100.0 / count(*) AS nul_proveedor,
  count(*) AS total
FROM silver.contratos;
```

---

## 10. Conclusiones

1. **El requisito de volumen se cumple:** 13.005.402 registros en plata = **1,30×** el mínimo de 10 millones, y 16.025.993 en bronce = **1,60×**.
2. **La deduplicación es la diferencia clave respecto al corte anterior.** 16.025.993 → 13.005.402 es −18,85%, todo por la regla R5. Es la única regla destructiva del ETL, y el grano del modelo es exactamente lo que sobrevive a ella.
3. **El rango 2017-2026 define la capa física:** 13 particiones en vez de 30, y 10 archivos de origen en vez de 454.
4. **El 50,8% del payload son dos columnas de texto libre.** Es el mayor vector de tamaño de `fact_contrato` y la razón de que el DDL fuera deliberadamente austero en columnas redundantes: eliminó `fecha_firma_original` y `codigo_proceso` porque plata ya no tenía de dónde copiarlas.
5. **Marcar es mejor que borrar.** Las 33.928 filas atípicas siguen ahí, marcadas. Borrarlas daría un número más limpio y peor, porque ocultaría el vacío. Lo mismo con las 670 duraciones negativas y las 662 fechas incoherentes.
6. **El conteo nunca se lee de la ficha del portal.** La metadata del portal está desfasada; hay que contar con `count(*)`. Es la razón de que RF-19 obligue a recontar después de cargar.
7. **Lo que no se puede proyectar es el número de claves distintas de un texto libre.** El conteo de filas y el espacio por fila se estiman bien con una muestra (−1,6% de error), pero las cardinalidades de `dim_entidad` y `dim_proveedor` hay que medirlas. Por eso la sección 3.3 las marca como pendientes en vez de estimarlas.
8. **La volumetría del corte vigente está incompleta y eso es visible en el documento.** Las secciones 3.3, 3.4, 5.3 y 7 dicen "pendiente" o "proyección" en cada punto afectado. Preferimos huecos declarados a números plausibles e inventados.

---

## 11. Referencias

| Documento | Contenido |
|---|---|
| [`modelo_relacional.md`](modelo_relacional.md) | Entregable 2 · modelo conceptual, lógico y DDL |
| [`decisiones_tecnicas.md`](decisiones_tecnicas.md) | Por qué el modelo es como es, con alternativas descartadas |
| [`requerimientos.md`](requerimientos.md) | RF-01 a RF-20, RNF-01 a RNF-10 |
| [`Plan_Entrega.md`](Plan_Entrega.md) | Los 5 entregables, roles y estados |
| `sql/ETL/01_cargar_bronce.sql` | Definición de `bronze.secop_raw` y carga por años |
| `sql/ETL/02_silver_limpieza.sql` | Reglas R1 a R9 y `silver.homologacion` |
| `sql/ETL/02c_correccion_valores.sql` | R7b y R9b: `valor_ajustado` y atípicos |
| `sql/ETL/05_qa_silver.sql` | 42 pruebas de calidad de plata |
| `sql/ETL/reporte_validacion_python.md` | Resultado 42/42 |

**Fuente de datos:** Agencia Nacional de Contratación Pública — Colombia Compra Eficiente. Licencia [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).