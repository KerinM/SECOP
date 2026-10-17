# Volumetría — SECOP Integrado

**Entregable 1 de 5** · Responsable: **Kerin** (rol: Analista de Datos)
**Corte vigente:** `secop_dw` · descargado el **29/09/2026**
**Fuente:** [SECOP Integrado — datos.gov.co](https://www.datos.gov.co/Estad-sticas-Nacionales/SECOP-Integrado/rpmr-utcd) · ID Socrata `rpmr-utcd`

---

## 0. Cómo leer las cifras de este documento

| Marca | Significado |
|---|---|
| **medido** | Salió de una consulta sobre el corte vigente (`secop_dw`, 29/09/2026) |
| **proyección** | Estimación con método y fuente explícitos |
| **pendiente** | No medido todavía; se indica la consulta que lo produce (sección 9) |

Preferimos un hueco declarado a un número plausible e inventado.

---

## 1. Cambio de corte: qué hay que saber antes de leer este documento

El proyecto tuvo **dos cortes de datos** y este documento describe el vigente. Si encuentras cifras de `secop_integrado` por ahí, son del corte anterior y no valen aquí.

| | Corte anterior (retirado) | **Corte vigente (`secop_dw`)** |
|---|---|---:|
| Base | `secop_integrado` | **`secop_dw`** |
| Contratos firmados | 2000 – 2026 | **2017 – 2026** |
| Archivos de origen | 454 CSV | **10 CSV (uno por año)** |
| Filas en la capa cruda | 22.670.028 | **16.025.993** |
| Esquema de la capa cruda | `staging` | **`bronze`** (`bronze.secop_raw`) |
| Tabla limpia | `silver.contrato` | **`silver.contratos`** |
| Filas tras limpiar | 22.670.028 (fiel al origen) | **13.005.402** (deduplicada) |
| Columnas de datos del origen | 22 | **22** (sin cambio) |
| Dimensiones de oro | 7 | **5** |
| Particiones de `fact_contrato` | 30 | **13** |

> **Corrección sobre las columnas.** Versiones anteriores de este documento decían «16 columnas» para el corte vigente. Es un error: `bronze.secop_raw` carga **22 columnas de datos** del CSV con `COPY ... HEADER true` (`sql/ETL/01_cargar_bronce.sql`), que empareja el CSV con la tabla columna por columna, y `scripts/inspeccionar_csv.py` también espera 22. Bronce añade 3 columnas de trazabilidad (`id_fila`, `fecha_carga`, `archivo_origen`). Para confirmarlo contra los archivos: `python scripts/inspeccionar_csv.py <carpeta de los CSV>`.

Tres diferencias cambian cómo se lee todo lo demás:

1. **El rango temporal se acortó a 2017-2026.** Por eso `fact_contrato` tiene 13 particiones y no 30.
2. **Plata ahora deduplica.** La regla R5 elimina filas idénticas (mismo origen, contrato, proceso, proveedor, valor y fecha de firma). De cada grupo de duplicados **conserva la fila con el estado de mayor avance del ciclo de vida** (`silver.rango_estado`) y, a igualdad, la de menor `id_fila`. Es la **única** regla destructiva del ETL; las otras diez (R1-R4, R6-R9b) corrigen, marcan o calculan. Por eso 16.025.993 → 13.005.402 y por eso el grano en oro es la versión y no el registro bruto.
3. **El modelo de oro se rediseñó a partir de los requerimientos.** Son 5 dimensiones (`dim_entidad`, `dim_ubicacion`, `dim_proveedor`, `dim_contrato`, `dim_tiempo`) y una tabla de hechos. Ver `modelo_relacional.md`.

---

## 2. Fuente y método de medición

Las cifras de este documento se **midieron**, no se estimaron a ojo. Tres vías:

| Vía | Qué permite |
|---|---|
| **API Socrata (SoQL)** | Conteos y distribuciones exactas sin descargar nada: `?$select=...&$group=...` |
| **Descarga por años** | 10 CSV, uno por año, vía `/resource/` |
| **PostgreSQL** | `count(*)` y `pg_total_relation_size()` sobre la base cargada |

> **Advertencia metodológica que sigue vigente.** La metadata en caché del portal (`cachedContents`) **está desfasada**. En el corte anterior mostraba 20.800.218 filas cuando la verdad eran 22.670.028, un desfase de −1.869.810.
>
> **Conclusión, y es la razón de que RF-14 obligue a recontar en PostgreSQL después de cargar: el conteo nunca debe tomarse de la ficha del portal.** Se cuenta con `count(*)` sobre la API o sobre la tabla cargada.

### 2.1 Verificación del requisito de volumen

> Requisito: base de datos con **más de 10 millones de registros** y **modelo relacional**.

| Criterio | Resultado | Estado |
|---|---|---:|
| Más de 10.000.000 de registros | **13.005.402** (plata y oro) · **16.025.993** (bronce) | ✅ Cumplido |
| Cobertura geográfica | 33 departamentos reales (más `COLOMBIA`, inválido, y `NO REGISTRA`: 35 valores en `dim_ubicacion`) | ✅ Nacional |
| Cobertura temporal | 2017 – 2026 (2026 parcial, hasta el 29/09) | ✅ 10 años |
| 2 plataformas integradas | `SECOPI` + `SECOPII` | ✅ |

### 2.2 Sobre el carácter «relacional»

**El origen NO es relacional.** Es un CSV plano de 22 columnas con una fila = un registro de contrato, que repite nombre de entidad, departamento, modalidad y proveedor en cada fila.

**Sí es modelable a relacional**, porque tiene dimensiones naturales identificables: quién contrata, dónde, a quién, cómo es el contrato y cuándo. El modelo en estrella del Entregable 2 (5 dimensiones y una tabla de hechos) sale de los requerimientos de negocio, y su volumetría está en las secciones 3.3 y 5.

---

## 3. Volumetría de origen (medida)

### 3.1 Las tres capas y su cuadre

| Capa | Tabla | Filas | Δ |
|---|---|---:|---:|
| Cruda | `bronze.secop_raw` | **16.025.993** | — |
| Limpia | `silver.contratos` | **13.005.402** | **−3.020.591 (−18,85 %)** |
| Analítica | `gold.fact_contrato` | **13.005.402** | **0** |

La diferencia entre bronce y plata son exactamente las filas que la regla R5 elimina por duplicadas. **Cero filas perdidas** por error de carga ni entre plata y oro.

**Validación de plata:** 18 validaciones automáticas en SQL (`05_qa_silver.sql`: 14 de la prueba 1 y 4 de la prueba 7), todas en OK, y **43 pruebas independientes en Python** (`06_validacion_python.py`), todas en OK.

### 3.2 Reparto por archivo de origen

La descarga es de 10 archivos, uno por año de firma (≈ 14,4 GB en texto plano en total), y `id_fila` se asigna de forma correlativa en el orden de carga:

| Archivo | Filas (medido) | Rango de `id_fila` |
|---|---:|---|
| `secop_2017.csv` | 1.498.976 | 1 … 1.498.976 |
| `secop_2018.csv` | 1.546.663 | 1.498.977 … 3.045.639 |
| `secop_2019.csv` | 1.671.680 | 3.045.640 … 4.717.319 |
| `secop_2020.csv` | 1.444.812 | 4.717.320 … 6.162.131 |
| `secop_2021.csv` | 1.512.288 | 6.162.132 … 7.674.419 |
| `secop_2022.csv` | 1.497.582 | 7.674.420 … 9.172.001 |
| `secop_2023.csv` | 1.458.129 | 9.172.002 … 10.630.130 |
| `secop_2024.csv` | 1.980.325 | 10.630.131 … 12.610.455 |
| `secop_2025.csv` | 2.123.615 | 12.610.456 … 14.734.070 |
| `secop_2026.csv` | 1.291.923 | 14.734.071 … 16.025.993 |
| **Total** | **16.025.993** | |

Los conteos por archivo son los de `bronze.log_cargas`; los rangos de `id_fila` son su suma acumulada, porque los archivos se cargaron en orden 2017 → 2026 (`01b_trazabilidad_bronce.sql`, paso 4).

> **2026 no es un año completo.** El corte es el 29/09/2026. Comparar 2026 contra años completos da una caída falsa; las vistas de consumo lo marcan con `es_anio_parcial`.

> **Consecuencia para la trazabilidad.** `id_fila` es correlativo por archivo de descarga. Por eso `gold.fact_contrato.id_fila` **hereda** esa numeración y no genera una identidad nueva: es lo que permite auditar una cifra de oro hasta el CSV de origen con un solo `JOIN`. El precio es que hay que reconstruir oro si bronce se recarga con otro orden. Ver `modelo_relacional.md` §10.

### 3.3 Dimensiones del origen

| Dimensión de oro | Se construye con | Filas | Estado |
|---|---|---:|---|
| `dim_entidad` | `codigo_entidad` (nombre, NIT, nivel) | **15.821** + el `-1` | medido |
| `dim_ubicacion` | pares `(departamento, municipio)` | **1.176** + el `-1` | medido |
| `dim_proveedor` | `documento_proveedor` | **2.181.586** + el `-1` = 2.181.587 | medido |
| `dim_contrato` | combinación `(modalidad, tipo_contrato, estado_proceso, origen)` | **1.014** + el `-1` | medido |
| `dim_tiempo` | calendario 2000-01-01 a 2060-12-31 | **22.282** (22.281 días + el `-1`) | medido |

> **`dim_proveedor`: 2.181.586 proveedores, 2.181.587 filas con el `-1`.** Cifras anteriores (2.178.559 y 2.178.560) eran incorrectas. Se verificó con `count(*)` sobre la dimensión y con `mv_kpis_globales` (2.181.586 proveedores).

**Medido sobre `fact_contrato` y `dim_ubicacion`:**

| Dato | Valor |
|---|---:|
| `id_contrato` distintos (contratos) | **12.147.523** |
| Versiones de contrato (filas de hechos) | **13.005.402** |
| Departamentos reales | **33** |
| Pares departamento-municipio con municipio registrado | **1.144** |

**Cardinalidades por atributo que aún no se midieron por separado** (modalidades, tipos de contrato y estados distintos): *pendiente*. La consulta está en 9.3. Lo medido es su combinación en `dim_contrato` (1.014).

**Estructural, sin depender de los datos:**

| Objeto | Valor | Por qué se conoce |
|---|---:|---|
| Calendario de `dim_tiempo` | **22.281 días** | `61 años × 365 + 16 bisiestos`, de 2000-01-01 a 2060-12-31 |
| Registros `-1` | **1 por dimensión** (las 5) | Por construcción |
| Particiones de `fact_contrato` | **13** | 1 cuarentena + 11 anuales (2017-2027) + 1 por defecto |
| `dim_origen` (como atributo de `dim_contrato`) | **2** | `SECOPI` y `SECOPII` |

**Medido en plata:**

| Dato | Valor | Regla |
|---|---:|---|
| Duplicados exactos eliminados | **3.020.591** | R5 |
| Grupos de bronce con estados distintos | **1.169.445** | R5 |
| De ellos, también difiere `fecha_fin` | **173.178 (14,8 %)** | R5 |
| Valores marcados `flag_valor_atipico` (total) | **33.939** | R9 + R9b |
| De ellos, por Tukey por tipo de contrato | 33.929 | R9 |
| De ellos, imposibles para su entidad | 10 | R9b |
| Filas que son versiones de un contrato SECOP II | **1.317.098** | R7b |
| Pares contrato-proveedor con versiones | **554.063** | R7b |
| Valor repetido en varias filas | **148.035** | R7 |
| Reglas del catálogo `silver.homologacion` | **17** | R3 |
| Variantes de `nivel_entidad` | **7 → 3** (+ vacío) | R3 |

> Los 554.063 son pares contrato-proveedor (lo que cuenta R7b). `mv_kpis_globales` cuenta **553.406** `id_contrato` distintos con la bandera de versión; la diferencia es esperable porque un mismo contrato puede aparecer con más de un proveedor.

> **Pendiente de remedir tras corregir R5:** 4.720 contratos (0,85 %) cambian de número de proceso entre versiones y 116 cambian de fecha de firma (0 cambian de entidad). Esas cifras se midieron con la plata anterior a la corrección de R5; el conteo de filas de versiones (1.317.098) sí coincide con el de hoy.

### 3.4 Completitud por columna

Medida sobre `gold.fact_contrato` (13.005.402 filas); cada fila cuenta el registro `-1` o la fecha ausente (reporte `mv_calidad_datos`, medido):

| Vacío | Filas | % |
|---|---:|---:|
| Sin fecha de firma válida | 3 | 0,00 |
| Sin fecha de inicio válida | 772.332 | 5,94 |
| Sin fecha de fin válida | 107 | 0,00 |
| Sin entidad | 900 | 0,01 |
| Sin ubicación | 54.026 | 0,42 |
| Sin proveedor | 30.709 | 0,24 |
| Sin clasificación del contrato | 0 | 0,00 |

El campo con más vacíos es la fecha de inicio de ejecución (5,94 %). Un vacío no es un error de carga: significa que el dato venía vacío, era un valor disfrazado (`NO DEFINIDO`, `N/A`) o era imposible, y se reporta, no se inventa.

### 3.5 Evolución por año de firma

Medida sobre las **versiones válidas** (sin atípicos, sin fecha inválida y con fecha de firma): 12.971.434 de las 13.005.402. El valor es `valor_ajustado` en billones de pesos. Fuente: `gold.v_evolucion_anual`.

| Año | Versiones válidas | Valor (billones) |
|---|---:|---:|
| 2017 | 1.194.283 | 94,19 |
| 2018 | 1.188.657 | 102,54 |
| 2019 | 1.279.214 | 104,86 |
| 2020 | 1.274.562 | 101,78 |
| 2021 | 1.462.612 | 141,97 |
| 2022 | 1.282.717 | 122,79 |
| 2023 | 1.164.090 | 125,33 |
| 2024 | 1.353.251 | 119,14 |
| 2025 | 1.597.922 | 153,17 |
| 2026 *(parcial, hasta el 29/09)* | 1.174.126 | 86,71 |

**Contraste con las cifras oficiales** (Colombia Compra Eficiente): 2018 da 102,54 billones frente a ≈ 100 oficiales. Con el valor sin ajustar, el mismo año daba ≈ 692 billones, por eso todo KPI de dinero usa `valor_ajustado`.

---

## 4. Calidad del dato que afecta a la volumetría

Estas cosas **cambian el número** y por eso se tratan en plata, no en oro. Todas están medidas.

| Anomalía | Medición | Qué hace plata |
|---|---:|---|
| **Duplicados exactos** | 3.020.591 filas (−18,85 %) | R5 los elimina |
| **Valores atípicos** | 33.939 | R9 (Tukey por tipo) y R9b (imposibles para su entidad) los **marcan**, no los borran |
| **Fechas imposibles** | 29 filas | R4: `< 2000`, `> 2060` o posteriores a la descarga → `NULL` + `flag_fecha_invalida` |
| **Valor en cero o negativo** | 80.137 | R6 los marca |
| **Valor de relleno (8 o más nueves)** | 94 | R6 los pasa a `NULL` y los marca |
| **Barras sueltas en nombres** | 538 | Corregidas en la limpieza (`02b_correccion_barras.sql`); idempotente: `UPDATE 538` la primera vez, `UPDATE 0` la segunda |

Además, y sin corrección posible:

- **Fechas incoherentes entre sí:** 616 filas con `fecha_fin` anterior a `fecha_inicio`. Se marcan con `es_fechas_incoherentes` y **no se corrigen**: son hechos del dato, no errores de carga.
- **Texto dañado desde SECOP:** la `ñ` llega como `���` (ej. `NI���O` en vez de `NIÑO`). La limpieza no lo repara con seguridad porque no se sabe qué letra era. **Solo afecta nombres y textos; no afecta valores, fechas ni llaves.**

### 4.1 Por qué las banderas viajan a oro

Oro no recalcula nada de esto: copia las banderas de plata **eliminando el prefijo `flag_`**. Un tablero filtra por `es_atipico`, `es_fecha_invalida` o `es_valor_extremo` sin volver a plata, y cada KPI de dinero aplica `NOT es_atipico`.

Es la razón de que la regla R9 **marque en vez de borrar**: borrar el dato anómalo sería más limpio y **peor**, porque ocultaría el vacío. Marcado, el número es auditable.

### 4.2 Por qué R5 cambió

La primera versión de R5 conservaba la fila de menor `id_fila` entre los duplicados. Eso descartaba el estado más avanzado del contrato: en SECOP II, por ejemplo, `CERRADO` quedaba subcontado. Se corrigió para conservar el estado de mayor rango y se reconstruyó plata (no un `UPDATE`), porque en 173.178 de los 1.169.445 grupos las filas duplicadas también difieren en `fecha_fin`. El conteo no cambió (13.005.402); cambió qué fila sobrevive. Efecto medido en SECOP II (antes → ahora): `CERRADO` 1.174.268 → 1.674.727; `TERMINADO` 644.692 → 776.995; `EN EJECUCION` 1.902.281 → 1.570.664; `MODIFICADO` 1.548.187 → 1.366.712.

---

## 5. Proyección a PostgreSQL

Entorno destino: **PostgreSQL 18.6** en `localhost:5432`, UTF-8, 15,3 GB RAM, 12 núcleos lógicos.

### 5.1 Método de cálculo

En PostgreSQL una tupla ocupa: **23 B de cabecera** + bitmap de nulos (redondeado a 2) + **padding de alineación a 8 B** + datos, donde cada `text` añade 1–4 B de cabecera `varlena` y cada `date` ocupa **4 B** (no ~20 B como en el CSV).

Este cálculo se validó con −1,6 % de error en el corte anterior. Lo que **no** se puede calcular con muestra es el número de claves distintas de un texto libre: eso solo se sabe recorriéndolo, y por eso la sección 3.3 las reporta medidas.

### 5.2 El peso de las columnas de texto

En el corte anterior se midió el peso relativo de cada columna sobre el contenido del CSV:

| Columna | % del payload |
|---|---:|
| Objetos textuales (2 columnas) | **50,8 %** |
| `url_contrato` | 9,8 % |
| `nombre_entidad` | 6,3 % |
| `modalidad` | 4,0 % |
| resto | 29,1 % |

**Estas cifras son del corte anterior y no se han vuelto a medir.** Aplican a bronce y plata, que conservan los textos. **Oro ya no los guarda:** `objeto_contrato` y `url_contrato` salieron de `fact_contrato` porque ningún requerimiento los usa, y se recuperan por `id_fila` desde plata (`decisiones_tecnicas.md` §3.4). Por eso el tamaño de oro no se puede deducir de estos porcentajes.

### 5.3 Qué se sabe del tamaño de `gold`

**No medido todavía.** Se obtiene con `pg_total_relation_size()` sobre cada tabla y cada índice (consultas 9.2 y 9.4). Hasta tenerlo, lo único que hay son expectativas razonadas, no mediciones:

| Expectativa | Base |
|---|---|
| `gold` debería ser **más pequeño que bronce y plata** | Las dimensiones absorben la repetición de entidad, proveedor y ubicación, y el hecho ya no guarda texto libre |
| `dim_tiempo` es pequeña | 22.282 filas de calendario |
| Las dimensiones categóricas son pequeñas | `dim_ubicacion` 1.177 filas y `dim_contrato` 1.015 filas |
| `dim_proveedor` es la dimensión más grande | 2.181.587 filas con nombre y documento |
| `fact_contrato` domina el tamaño | 13.005.402 filas con 8 banderas, 3 medidas de valor y 6 claves foráneas |

### 5.4 Decisiones de tamaño ya tomadas

| Decisión | Motivo |
|---|---|
| **BRIN** en vez de B-tree para la fecha | El orden de carga es por año, así que las páginas ya están ordenadas; mucho más pequeño que el B-tree equivalente |
| **Sin índice sobre `es_atipico`** | 33.939 en `true` sobre 13 millones: un índice sobre el 99,7 % de falsos no lo usa nadie |
| **Sin índice sobre `valor_ajustado` suelto** | Redundante con el índice compuesto `(sk_fecha_firma, valor_ajustado)` |
| **Sin `fecha_firma_original` en oro** | Plata borró el original (R4 lo puso en `NULL`); guardarlo sería una copia de `fecha_firma`. Vive en bronce |
| **Sin `objeto_contrato` ni `url_contrato` en oro** | Ningún requerimiento los usa; se recuperan por `id_fila` |
| **Sin `contratos` ni `valor_total` en las dimensiones** | Eran derivables; los agregados viven en las vistas materializadas |

---

## 6. Particionamiento

### 6.1 Criterio y número

`fact_contrato` se particiona por **RANGE sobre `sk_fecha_firma`**, un entero con forma de fecha (AAAAMMDD), y son **13 particiones**, todas en el esquema `gold` (medido, verificación 9.4 del DDL):

| Tipo | Rango de `sk_fecha_firma` | Cantidad |
|---|---|---:|
| Cuarentena `pre2017` | `MINVALUE` → 20170101 (incluye el `-1` de las filas sin fecha) | 1 |
| Anual | 2017 … 2027 | **11** |
| Por defecto `resto` | el resto | 1 |

La cuarentena concentra las filas sin fecha de firma válida (3 en el corte vigente) y cualquier firma anterior a 2017. Es una característica del diseño, no un remanente.

El rango va hasta **2027** aunque el dato termine en 2026, para que un año de consultas más no exija un `CREATE TABLE`.

### 6.2 Beneficios

| Beneficio | Detalle |
|---|---|
| Consultas por año | 1 de 13 particiones |
| `VACUUM` / `ANALYZE` | Por partición, no 13 millones de filas de una vez |
| Índices | Cada índice de partición es mucho más pequeño que el global |
| Mantenimiento | Reindexar un año no bloquea los otros |
| Crecimiento | Añadir 2028 = un `CREATE TABLE ... PARTITION OF`, sin migrar filas |

### 6.3 Trade-off explícito

> PostgreSQL **no** permite índice único ni clave primaria que **no incluyan la clave de partición**. Con particionado por año, la PK tiene que ser compuesta: `(sk_fecha_firma, id_fila)`.
>
> **Alternativa evaluada y rechazada:** tabla sin particionar, para permitir `PK (id_fila)`. Con 15,3 GB de RAM y una tabla de 13 millones de filas, el `VACUUM` completo y los índices no caben cómodamente. Se particiona y se acepta la PK compuesta.
>
> **Efecto lateral útil:** como la PK empieza por `sk_fecha_firma`, los rangos de fecha ya quedan cubiertos y no hace falta un B-tree extra sobre la fecha.

---

## 7. Crecimiento proyectado

**Proyección, no medición.** Se apoya en que el rango del corte vigente es 2017-2026 y en que la tasa de crecimiento medida en el corte anterior fue de +1,7M a +2,0M filas/año. Medido en el corte vigente: entre los años completos 2024 y 2025 las versiones válidas crecieron de 1.353.251 a 1.597.922 (+18,08 %, sección 3.5).

| Año | Filas acumuladas en plata | `gold` estimado |
|---|---:|---:|
| 2026 (corte 29/09) | **13,0M** *(medido)* | por medir |
| 2027 | ~14,5M | por medir |
| 2028 | ~16,2M | por medir |
| 2029 | ~18,0M | por medir |
| 2030 | ~19,9M | por medir |

**Advertencia de la proyección:** el corte vigente eliminó 2016 y anteriores, así que la serie histórica de crecimiento del corte anterior **no es comparable** con esta. La proyección cubre solo el rango 2017+ y hay que revisarla en el próximo corte, con dos puntos medidos en lugar de uno. La columna de tamaño de `gold` queda «por medir» hasta tener la medición de la sección 5.3.

---

## 8. Riesgo de capacidad

### 8.1 Recursos de la máquina

Medidos antes de la carga:

| Recurso | Disponible | Necesario | Margen |
|---|---:|---:|---:|
| Disco libre (C:) | **129 GB** | CSV + 3 capas ≈ 40 GB (estimación) | ~89 GB |
| RAM | **15,3 GB** | 8 GB (PostgreSQL) | 7,3 GB |
| Núcleos | 12 | 2 (carga `COPY`) | 10 |
| Puerto 5432 | Libre · PostgreSQL 18.6 activo | — | — |

**Veredicto: capacidad suficiente.** El corte vigente tiene 30 % menos filas que el anterior, así que el margen mejoró. El tamaño real de la base tras la carga completa **no está medido**; se obtiene con `pg_database_size('secop_dw')` (consulta 9.2).

### 8.2 Riesgo de tiempo de descarga

| Método | Velocidad medida | Para 16M filas |
|---|---|---|
| Endpoint oficial (monocanal, sin gzip) | 0,5 – 1,2 MB/s | 4 – 10 h ⚠️ |
| API paginada, 4 conexiones en paralelo | 4 – 9 MB/s | 30 – 50 min ✅ |

**Estrategia adoptada:** descarga por años con la API `/resource/`. Detalle en `etl_carga.md` (Entregable 4, responsable **José**).

### 8.3 Riesgo de memoria durante la carga

Bronce se carga con `\copy` archivo por archivo (10 CSV), de modo que ningún comando carga los 16 millones de filas a la vez.

La carga de `gold` tiene el riesgo de un `INSERT ... SELECT` de 13 millones de filas en una sola transacción, que mantiene WAL y bloqueos hasta el final. Por eso el DDL expone `lote_desde` y `lote_hasta` para insertar por tramos. Ver `decisiones_tecnicas.md` §14, que explica por qué los bloques anteriores son idempotentes y por qué eso es lo que hace viable el recorrido por tramos.

---

## 9. Consultas para convertir las pendientes en mediciones

Se ejecutan sobre `secop_dw`. Las de 9.2, 9.3 y 9.5 a 9.8 completan los puntos marcados como *pendiente*.

```sql
-- 9.1 Conteo real por capa. Los tres numeros deben cuadrar:
--     bronce = 16.025.993, plata = 13.005.402, oro = plata.
SELECT (SELECT count(*) FROM bronze.secop_raw)   AS bronce,
       (SELECT count(*) FROM silver.contratos)   AS plata,
       (SELECT count(*) FROM gold.fact_contrato) AS oro;

-- 9.2 Tamano real. Una tabla particionada no almacena paginas en el padre,
--     asi que las dimensiones y las particiones se miden por separado.
-- 9.2a Dimensiones y vistas materializadas de gold:
SELECT c.relname AS objeto,
       CASE c.relkind WHEN 'm' THEN 'materializada' ELSE 'tabla' END AS tipo,
       pg_size_pretty(pg_table_size(c.oid))          AS tabla_solo,
       pg_size_pretty(pg_indexes_size(c.oid))        AS indices,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'gold'
  AND c.relkind IN ('r', 'm')
  AND NOT c.relispartition
ORDER BY pg_total_relation_size(c.oid) DESC;

-- 9.2b Tamano total de gold (incluye particiones, indices y materializadas)
--      y de la base completa:
SELECT pg_size_pretty(sum(pg_total_relation_size(c.oid))) AS gold_total,
       pg_size_pretty(pg_database_size('secop_dw'))       AS base_total
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'gold'
  AND c.relkind IN ('r', 'm');

-- 9.3 Cardinalidades de las dimensiones (completa la seccion 3.3).
--     Usar count(*): n_live_tup de pg_stat_user_tables es una estimacion.
SELECT 'dim_entidad'   AS dimension, count(*) AS filas FROM gold.dim_entidad
UNION ALL SELECT 'dim_ubicacion', count(*) FROM gold.dim_ubicacion
UNION ALL SELECT 'dim_proveedor', count(*) FROM gold.dim_proveedor
UNION ALL SELECT 'dim_contrato',  count(*) FROM gold.dim_contrato
UNION ALL SELECT 'dim_tiempo',    count(*) FROM gold.dim_tiempo
ORDER BY filas DESC;

-- 9.3b Valores distintos por atributo de dim_contrato (pendientes de 3.3):
SELECT count(DISTINCT modalidad)      AS modalidades,
       count(DISTINCT tipo_contrato)  AS tipos_de_contrato,
       count(DISTINCT estado_proceso) AS estados,
       count(DISTINCT origen)         AS origenes
FROM silver.contratos;

-- 9.4 Tamano real por particion (confirma la seccion 6.1: deben ser 13).
SELECT c.relname AS particion,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total,
       pg_get_expr(c.relpartbound, c.oid)            AS rango
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE i.inhparent = 'gold.fact_contrato'::regclass
ORDER BY c.relname;

-- 9.5 Bytes reales por fila en plata.
SELECT pg_size_pretty(pg_table_size('silver.contratos')) AS tabla,
       pg_table_size('silver.contratos')::bigint / count(*) AS bytes_por_fila,
       count(*) AS filas
FROM silver.contratos;

-- 9.6 Tamano de los indices de una tabla particionada.
-- OJO: pg_stat_user_indexes no tiene filas para el padre de una tabla
-- particionada, porque el padre no almacena paginas. Hay que recorrer
-- pg_inherits (ver bitacora_sesiones.md).
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

-- 9.7 Donde viven realmente las particiones. Todas deben estar en 'gold'.
-- Esta consulta destapo el bug del corte anterior: 28 de 30 particiones
-- estaban en 'public' en vez de 'gold' (decisiones_tecnicas.md seccion 10.2).
SELECT n.nspname AS esquema, c.relname AS particion, c.relispartition,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS tamano
FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE i.inhparent = 'gold.fact_contrato'::regclass
ORDER BY n.nspname, c.relname;

-- 9.8 Completitud por columna en plata (complementa la seccion 3.4,
--     que se midio sobre oro).
SELECT
  round(count(*) FILTER (WHERE fecha_firma         IS NULL) * 100.0 / count(*), 2) AS nul_firma,
  round(count(*) FILTER (WHERE fecha_inicio        IS NULL) * 100.0 / count(*), 2) AS nul_inicio,
  round(count(*) FILTER (WHERE fecha_fin           IS NULL) * 100.0 / count(*), 2) AS nul_fin,
  round(count(*) FILTER (WHERE codigo_entidad      IS NULL) * 100.0 / count(*), 2) AS nul_entidad,
  round(count(*) FILTER (WHERE nit_entidad         IS NULL) * 100.0 / count(*), 2) AS nul_nit,
  round(count(*) FILTER (WHERE municipio           IS NULL) * 100.0 / count(*), 2) AS nul_municipio,
  round(count(*) FILTER (WHERE documento_proveedor IS NULL) * 100.0 / count(*), 2) AS nul_proveedor,
  count(*) AS total
FROM silver.contratos;
```

---

## 10. Conclusiones

1. **El requisito de volumen se cumple:** 13.005.402 registros en plata y oro = **1,30×** el mínimo de 10 millones, y 16.025.993 en bronce = **1,60×**.
2. **La deduplicación es la diferencia clave respecto al corte anterior.** 16.025.993 → 13.005.402 es −18,85 %, todo por la regla R5, que conserva el estado de mayor avance. Es la única regla destructiva del ETL, y el grano del modelo es exactamente lo que sobrevive a ella: una versión de contrato.
3. **El rango 2017-2026 define la capa física:** 13 particiones en vez de 30, y 10 archivos de origen en vez de 454. 2026 es un año parcial (corte 29/09/2026).
4. **El origen tiene 22 columnas de datos**, no 16. Oro conserva solo las que algún requerimiento usa, y deja fuera los textos libres y el tipo de documento.
5. **Marcar es mejor que borrar.** Las 33.939 filas atípicas siguen ahí, marcadas. Borrarlas daría un número más limpio y peor, porque ocultaría el vacío. Lo mismo con las 616 fechas incoherentes.
6. **El dinero se suma con `valor_ajustado`, nunca con `valor_contrato`.** 2018 da 102,54 billones frente a ≈ 100 oficiales; con el valor sin ajustar daba ≈ 692.
7. **El conteo nunca se lee de la ficha del portal.** La metadata del portal está desfasada; hay que contar con `count(*)`. Es la razón de que RF-14 obligue a recontar después de cargar.
8. **Lo que no se puede proyectar es el número de claves distintas de un texto libre**, y por eso las cardinalidades de las dimensiones se reportan medidas (15.821 entidades, 2.178.559 proveedores, 1.176 ubicaciones, 1.014 combinaciones de contrato).
9. **La volumetría tiene dos puntos aún sin medir y eso es visible en el documento:** el tamaño real de `gold` en disco (sección 5.3) y los valores distintos por atributo de `dim_contrato` (3.3). Cada uno tiene su consulta en la sección 9.

---

## 11. Referencias

| Documento | Contenido |
|---|---|
| [`modelo_relacional.md`](modelo_relacional.md) | Entregable 2 · modelo conceptual, lógico y DDL |
| [`decisiones_tecnicas.md`](decisiones_tecnicas.md) | Por qué el modelo es como es, con alternativas descartadas |
| [`requerimientos.md`](requerimientos.md) | RQ01-RQ14, RF y RNF |
| [`bitacora_sesiones.md`](bitacora_sesiones.md) | Errores encontrados durante la carga y cómo se resolvieron |
| [`Plan_Entrega.md`](Plan_Entrega.md) | Los 5 entregables, roles y estados |
| `sql/ETL/01_cargar_bronce.sql` | Definición de `bronze.secop_raw` y carga por años |
| `sql/ETL/01b_trazabilidad_bronce.sql` | `archivo_origen` y bitácora `bronze.log_cargas` |
| `sql/ETL/02_silver_limpieza.sql` | Reglas R1 a R9, R5 corregida y `silver.homologacion` |
| `sql/ETL/02c_correccion_valores.sql` | R7b y R9b: `valor_ajustado` y atípicos |
| `sql/ETL/05_qa_silver.sql` | Pruebas de calidad de plata (18 validaciones automáticas) |
| `sql/ETL/reporte_validacion_python.md` | Validación independiente en Python (43/43) |
| `sql/04_vistas.sql` | Vistas materializadas y vistas de consumo (evolución anual de 3.5) |

**Fuente de datos:** Agencia Nacional de Contratación Pública — Colombia Compra Eficiente. Licencia [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).