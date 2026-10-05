# Requerimientos del Proyecto — SECOP Integrado

**Proyecto:** Base de datos relacional de contratación pública de Colombia (SECOP I + SECOP II) construida sobre datos abiertos oficiales.
**Fuente:** [SECOP Integrado](https://www.datos.gov.co/Estad-sticas-Nacionales/SECOP-Integrado/rpmr-utcd) · ID Socrata `rpmr-utcd` · Agencia Nacional de Contratación Pública — Colombia Compra Eficiente.
**Volumetría:** **16.025.993 registros** en el corte del 29/09/2026 · 16 columnas · **13.005.402 filas** en plata tras deduplicar · detalle y proyecciones en [`volumetria.md`](volumetria.md).
**Motor:** PostgreSQL 18.6 + DBeaver 26.2.0 + Python 3.14 + Power BI Desktop.
**Entrega:** miércoles 14 de octubre de 2026.

**Equipo (3):**

| Miembro | Rol | Responsabilidades |
|---|---|---|
| **Kerin** | **Analista de Datos** | Volumetría, modelo conceptual y lógico de la bodega, consultas analíticas de negocio, vistas de soporte |
| **José** | **ETL / Administrador de PostgreSQL** | Descarga, carga, metodología Medallion, ETL, índices, particionado y tuning |
| **Isabella** | **QA / Visualización** | Calidad de datos, validación de integridad, tableros en Power BI y evidencias gráficas |

**Reparto:** José → RF-01 a RF-06 y RNF-01 a RNF-04 (10) · Kerin → RF-07 a RF-13 y RNF-05 a RNF-07 (10) · Isabella → RF-14 a RF-20 y RNF-08 a RNF-10 (10).

**Enfoque mixto 50/50:** 10 requisitos técnicos (carga, modelado físico, índices, calidad) y 10 de analítica de negocio (concentración, fraccionamiento, regiones, tiempos de ejecución) + 10 no funcionales.

---

# 1. Requisitos funcionales (RF-01 a RF-20)

## 1.1 Responsable: José — ETL / Administrador de PostgreSQL

### RF-01 — Descarga íntegra y automatizada del dataset

El sistema debe descargar la totalidad de los registros del conjunto SECOP Integrado desde la API oficial de Socrata, sin intervención manual y sin depender de un archivo descargado a mano.

La descarga debe realizarse de forma **paginada y en paralelo** sobre el endpoint `/resource/rpmr-utcd.json?$limit=&$offset=`, porque el endpoint oficial de archivo completo (`/api/views/.../rows.csv?accessType=DOWNLOAD`) no admite compresión ni rangos y entrega ~19,71 GiB a una velocidad medida de 0,5 – 1,2 MB/s (4 a 10 horas de espera).

**Criterio de aceptación:** el total de filas descargadas coincide exactamente con el `count(*)` de la API en la fecha de descarga (**16.025.993** en el corte vigente, 29/09/2026) y el total de bytes descargados es consistente con el promedio de bytes por fila medido en ese corte, ± 5%.

### RF-02 — Carga por lotes con `COPY FROM STDIN`

El sistema debe cargar los datos en PostgreSQL mediante `COPY ... FROM STDIN` en formato CSV, en lotes de **250.000 filas**, con `commit` al final de cada lote, sin generar archivos CSV intermedios en disco.

**Criterio de aceptación:** la carga se completa sin agotar la memoria disponible (15,3 GB) y el proceso es reanudable desde el último lote confirmado.

### RF-03 — Mapeo de tipos a esquema nativo de PostgreSQL

El sistema debe convertir los 22 campos de origen, que llegan todos como `text`, a tipos nativos:

| Origen (text) | Destino PostgreSQL |
|---|---|
| `fecha_de_firma_del_contrato`, `fecha_inicio_ejecuci_n`, `fecha_fin_ejecuci_n` | `date` |
| `valor_contrato` | `numeric(18,2)` |
| `documento_proveedor`, `nit_de_la_entidad` | `varchar` (con restricción de solo dígitos y guion) |
| Las 18 columnas restantes | `text` |

**Criterio de aceptación:** tras la carga, `information_schema.columns.data_type` refleja los 4 tipos esperados y ninguna columna de fecha quedó como `text`.

### RF-04 — Validación y saneamiento de fechas

El sistema debe aplicar una función `es_fecha_valida(fecha date)` que marque como inválida y excluya del rango analítico toda fecha:
- nula (1.767.413 registros sin fecha de firma),
- con año anterior a 1994 (se detectaron fechas hasta **1899-11-27**),
- con año posterior a la fecha de corte (se detectaron 106 registros de firma repartidos en 18 años futuros entre 2044 y 2099, con fecha máxima **2099-12-30**, y fechas de fin de ejecución hasta **8201-12-21**).

**Criterio de aceptación:** la vista analítica no contiene ninguna fila con año fuera de `[1994, 2026]`, y el reporte de descartes indica cuántas filas se excluyeron por cada causa.

### RF-05 — Normalización y tipificación de las dimensiones categóricas

El sistema debe reducir las categorías duplicadas por capitalización y sinonimia, documentando el mapeo:

| Dimensión | Origen | Destino |
|---|---:|---:|
| `tipo_de_contrato` | 33 valores | ~20 |
| `modalidad_de_contrataci_n` | 38 valores | ~22 |
| `estado_del_proceso` | 30 valores | ~20 |
| `departamento_entidad` | 38 valores | **35** (33 departamentos reales + `No Definido` + `Colombia` inválido) |
| `nivel_entidad` | 7 valores | 4 |

**Criterio de aceptación:** la tabla de mapeo está en el repositorio y ninguna consulta de agrupación por estas dimensiones devuelve variantes que difieran solo en mayúsculas/minúsculas.

### RF-06 — Modelo en estrella con claves primarias y foráneas

El sistema debe estructurar los datos en un esquema relacional en estrella compuesto por:

- **1 tabla de hechos:** `fact_contrato` con el grano de un contrato registrado.
- **8 dimensiones.** Cardinalidades **medidas** sobre la carga completa (las projections entre paréntesis):
  `dim_entidad` (15.928 · 17.183), `dim_proveedor` (2.508.996 · 3.364.090), `dim_tipo_contrato` (31 · 33), `dim_modalidad` (35 · 38), `dim_estado` (29 · 30), `dim_origen` (2 · 2), `dim_tipo_documento` (18 · 19), `dim_tiempo` (47.847 días, 1900-01-01 a 2030-12-31 · ~9.960).
- Claves **primarias** sustitutas `integer` generadas y **foráneas** con `REFERENCES` explícitas.
- `fact_contrato` **particionada por RANGE** sobre el año de `fecha_firma`, con **30 particiones**: cuarentena `pre2000` (1900-01-01 → 2000-01-01), 28 anuales 2000-2027, y una por defecto.

> **Desviación respecto a la especificación original, aceptada durante la construcción.** Se pidieron 9 dimensiones incluyendo `dim_ubicacion` (1.131 municipios). Se implementaron **8**: `dim_ubicacion` se eliminó porque municipio y departamento ya son atributos de `dim_entidad`, y mantenerla duplicaba el dato sin aportar granularidad. `dim_tiempo` se extendió a 1900-2030 (no 2000-2026) porque `fecha_firma` necesita que exista la fecha centinela `1900-01-01` para las 1.779.534 filas sin fecha válida. El motivo completo está en `decisiones_tecnicas.md`.

**Criterio de aceptación:** `information_schema` no reporta ninguna clave foránea sin índice, y la suma de filas de las 7 dimensiones más la tabla de hechos es coherente con los 13.005.402 registros de plata.

## 1.2 Responsable: Kerin — Analista de Datos

### RF-07 — Consultas analíticas de negocio sobre concentration de mercado

El sistema debe permitir medir la **concentración del gasto público** por entidad contratante y por proveedor, mediante ranking, porcentaje del total y el **índice HHI** (Herfindahl-Hirschman) de concentración por departamento y por tipo de contrato.

Contexto de la medición: el departamento con mayor volumen es Antioquia con 4.099.174 registros (18,1%) y el mayor es Bogotá con 5.649.612 sumando sus dos variantes (24,9%).

**Criterio de aceptación:** las consultas devuelven el top 20 de entidades y el top 20 de proveedores por valor contratado, con su porcentaje acumulado y el HHI calculado.

### RF-08 — Detección de fraccionamiento de contratos

El sistema debe permitir identificar posibles casos de **fraccionamiento**, es decir, una misma entidad contratante que divide un valor en varios contratos por debajo del umbral de Contratación Mínima Cuantía, o un mismo proveedor que recibe múltiples contratos sospechosamente similares de una misma entidad en una ventana de tiempo corta.

**Criterio de aceptación:** la consulta devuelve el listado de entidades y proveedores con mayor número de contratos sub-mínima cuantía en ventanas de 30 y 90 días, con su valor agregado.

### RF-09 — Análisis de tiempos de ejecución

El sistema debe permitir analizar la **duración real de los contratos** mediante `fecha_fin_ejecuci_n - fecha_inicio_ejecuci_n`, y detectar las anomalías: 1.521.879 contratos sin fecha de fin, contratos con fecha de fin anterior a la de inicio, y contratos con duración superior a 5 años.

**Criterio de aceptación:** el sistema reporta duración promedio, mediana y percentiles 25/50/75/95 por tipo de contrato, excluyendo los registros que RF-04 marcó como inválidos.

### RF-10 — Análisis de evolución temporal por modalidad y tipo

El sistema debe permitir analizar la evolución de la contratación por **año, trimestre y mes**, cruzando `fecha_de_firma_del_contrato` con `modalidad_de_contrataci_n` y `tipo_de_contrato`, y calcular tasas de variación interanual.

Contexto: el año pico es **2025 con 2.118.036 contratos**; el dataset **no está ordenado cronológicamente**, por lo que el análisis debe filtrar por rango y no confiar en el orden de carga.

**Criterio de aceptación:** la serie anual 2000–2026 devuelve 27 años con conteo y valor, y la tasa de variación se calcula sobre el año inmediatamente anterior presente en la serie.

### RF-11 — Análisis geográfico por departamento y municipio

El sistema debe permitir agregar número de contratos y valor contratado por `departamento_entidad` y `municipio_entidad`, **con los 35 valores ya normalizados** según RF-05, para que la visualización geográfica no duplique Bogotá, Norte de Santander ni el "sin departamento".

**Criterio de aceptación:** la consulta devuelve 33 filas de departamento (más la categoría "No Definido") y la suma de los 1.131 municipios cuadra con el total nacional.

### RF-12 — Perfilamiento de contratistas y su tipo documental

El sistema debe permitir analizar la composición de los **3.364.090 proveedores distintos** por `tipo_documento_proveedor` (19 valores de origen): cédula de ciudadanía, NIT de persona jurídica, NIT de persona natural, visa, pasaporte, etc., identificando personas naturales frente a personas jurídicas.

**Criterio de aceptación:** la consulta devuelve el conteo y el valor contratado por cada tipo documental, resaltando la proporción de contratos con `documento_proveedor = 'NO DEFINIDO'`.

### RF-13 — Vistas de consulta reutilizables

El sistema debe exponer **vistas analíticas** (y, si el rendimiento lo exige, vistas materializadas) normalizadas que sirvan de origen único a Power BI y a los requisitos RF-07 a RF-12, con los nombres de objetos del modelo normalizados y sin duplicar la lógica de agregación.

**Criterio de aceptación:** Power BI se conecta exclusivamente a estas vistas, y cada vista responde en menos de 5 segundos sobre los 13.005.402 registros de plata.

## 1.3 Responsable: Isabella — QA / Visualización

### RF-14 — Verificación de integridad de la carga

El sistema debe comparar el conteo cargado contra el conteo de la API oficial y reportar discrepancias. La verificación debe considerar que **la metadata del portal está desfasada en 1.869.810 registros**: el conteo de referencia es el de la API en vivo, no el de la ficha web.

Además debe reportar:
- Filas que comparten `numero_del_contrato` (medido: **4.621.012 filas, 20,38%**).
- Proporción de nulos por columna (medido: el 100% de los nulos está en las 3 columnas de fecha).
- Filas con `valor_contrato = 0` (medido: 802.977) y con valor centinela.

**Criterio de aceptación:** `SELECT count(*)` sobre la tabla cargada devuelve exactamente **16.025.993** en bronce, y `13.005.402` en plata tras deduplicar; la diferencia (**3.020.591**, 18,85%) queda explicada y documentada.

### RF-15 — Panel de KPIs globales

Power BI debe mostrar los indicadores principales del proyecto: total de contratos (**554.063** contratos distintos, con **13.005.402** versiones registradas en `gold.fact_contrato`), valor total contratado, número de entidades contratantes, número de proveedores, número de municipios y número de departamentos (35 categorías).

> **Cifras pendientes de medir en el corte vigente:** los recuentos de entidades contratantes, proveedores y municipios son `count(distinct ...)` sobre texto libre y **no se pueden proyectar**; los del corte anterior (15.928 y 2.508.996) **no son válidos aquí**. Se miden con la consulta 9.6 de [`volumetria.md`](volumetria.md) una vez construida la capa oro.

**Criterio de aceptación:** cada KPI del tablero coincide con el resultado de la consulta SQL equivalente, verificado documento a documento.

### RF-16 — Tablero de evolución temporal

Power BI debe visualizar la evolución de la contratación por **año y trimestre**, desglosada por tipo de contrato y por modalidad, con línea de tendencia y su tasa de variación interanual.

**Criterio de aceptación:** el gráfico cubre de 2000 a 2026 y la línea de tendencia corresponde a la serie de RF-10.

### RF-17 — Mapa geográfico de la contratación

Power BI debe representar en un mapa el número de contratos y el valor contratado por **departamento y por municipio**, utilizando la codificación de la dimensión ya normalizada, y resaltando la participación de Bogotá y Antioquia frente al total nacional.

**Criterio de aceptación:** el mapa muestra 33 departamentos sin duplicar Bogotá, y el drill-down a municipio funciona para al menos los 10 municipios con mayor valor.

### RF-18 — Panel de concentración y proveedor

Power BI debe presentar el **top 20 de contratistas por valor contratado**, su participación porcentual acumulada, el HHI calculado, y el perfil de los proveedores por tipo documental (persona natural vs jurídica), resolviendo RF-07 y RF-12.

**Criterio de aceptación:** el ranking del tablero es idéntico al que devuelve la consulta de RF-07.

### RF-19 — Reporte de calidad de datos

El sistema debe generar un reporte visual de las cuatro clases de anomalías medidas en la volumetría: (1) fechas imposibles — 106 registros de firma en 18 años futuros entre 2044 y 2099 —, (2) duplicados de número de contrato (4.621.012 filas), (3) inconsistencias de mayúsculas y minúsculas, y (4) valores cero y centinela, con su cantidad y porcentaje sobre el total.

**Criterio de aceptación:** el reporte cubre las 4 clases y el total de registros afectados está cuantificado.

### RF-20 — Filtros interactivos y reproducibilidad de las capturas

El tablero debe permitir filtrar de forma coherente por **año, departamento, tipo de contrato, modalidad, estado y nivel de entidad**, manteniendo la coherencia entre todas las páginas, y cada vista filtrada debe ser **reproducible como captura PNG** en alta resolución para el Entregable 5.

**Criterio de aceptación:** existen al menos 5 capturas PNG de alta resolución en `docs/imagenes/`, cada una rotulada con los filtros aplicados, que corresponden a las páginas del tablero.

---

# 2. Requisitos no funcionales (RNF-01 a RNF-10)

## 2.1 Responsable: José — ETL / Administrador de PostgreSQL

### RNF-01 — Rendimiento de la descarga

La descarga íntegra de los 16.025.993 registros debe completarse en **menos de 90 minutos** con 4 conexiones en paralelo, frente a los 4 a 10 horas que tomaría el endpoint oficial en monocanal a la velocidad medida de 0,5 – 1,2 MB/s.

**Métrica de verificación:** tiempo transcurrido entre el inicio y el fin de la descarga, y MB/s promedio alcanzado.

### RNF-02 — Latencia de las consultas

Las consultas analíticas sobre la tabla de hechos con índices deben devolver resultados en **menos de 5 segundos**; las consultas particionadas por año, en **menos de 1 segundo**.

**Métrica de verificación:** `EXPLAIN ANALYZE` de cada consulta de RF-07 a RF-13 y de las vistas de RF-13.

### RNF-03 — Consumo eficiente de recursos

El sistema debe operar dentro de los recursos de la máquina objetivo —15,3 GB de RAM, 12 núcleos, 129 GB de disco libre— ocupando **menos de 46 GB de disco** en el peor caso (19,71 GiB del CSV más 26 GiB de la base de datos), y debe configurarse `postgresql.conf` con `shared_buffers = 4GB`, `work_mem = 64MB`, `maintenance_work_mem = 1GB` y `effective_cache_size = 10GB`.

**Métrica de verificación:** espacio ocupado en disco tras la carga y consumo de memoria durante la carga y las consultas.

## 2.2 Responsable: Kerin — Analista de Datos

### RNF-04 — Escalabilidad del proceso de carga

El sistema debe soportar el crecimiento del dataset, estimado en **+1,7M a +2,0M registros por año** (5,8× entre 2014 y 2025), sin rehacer el proceso de carga. El particionado por año debe permitir añadir el año 2028 creando **una sola partición nueva**, sin migrar los 13.005.402 registros existentes.

**Métrica de verificación:** añadir una partición de prueba y comprobar que las consultas sobre los años anteriores no se degradan.

### RNF-05 — Fidelidad de los datos de origen

La carga debe preservar la totalidad de la información del origen: los **22 campos** deben estar representados, la codificación debe ser **UTF-8** sin pérdida de tildes, ñ y símbolos (el dataset contiene textos con caracteres como "Fonaguacute" y "Lntilde" correctamente codificados), y la suma de `valor_contrato` debe cuadrar con el total del origen salvo los valores centinela documentados.

**Métrica de verificación:** suma de `valor_contrato` por año contra la consulta equivalente a la API, con diferencia de solo los valores cero y centinela.

### RNF-06 — Trazabilidad y reproducibilidad de la documentación

Toda cifra declarada en la documentación debe ser **verificable y reproducible**: o bien proviene de una consulta a la API o a la base de datos, o bien es una proyección con la fórmula explícita y la fuente de sus parámetros. Ninguna cifra puede estimarse sin justificación.

**Métrica de verificación:** cada tabla de la volumetría y de los análisis indica si es **medida** o **proyectada**, y las proyecciones incluyen el método de cálculo.

## 2.3 Responsable: Isabella — QA / Visualización

### RNF-07 — Codificación y compatibilidad regional

La base de datos debe crearse con codificación **UTF-8** y con configuración regional coherente con Colombia, y la documentación debe distinguir correctamente los caracteres acentuados en todas las consultas de ejemplo.

**Métrica de verificación:** crear la base de datos y ejecutar una consulta de prueba con acentos, ñ y diéresis, comprobando que no hay errores de codificación.

### RNF-08 — Verificación automatizada de integridad

El sistema debe incluir un procedimiento de verificación ejecutable tras cada carga, que compruebe como mínimo: conteo de filas, proporción de nulos por columna, duplicados de clave natural, distribución por origen, rango de fechas válido y tamaño real por tabla e índice.

**Métrica de verificación:** el procedimiento se ejecuta sin error y produce un reporte con los valores medidos que se contrastan contra las proyecciones de la volumetría.

### RNF-09 — Usabilidad y documentación reproducible

La documentación del proyecto (README más `docs/`) debe permitir que **un tercero sin conocimiento previo** monte el entorno completo —PostgreSQL, DBeaver, descarga, carga, índices y consultas— siguiendo los pasos documentados, y debe permitir interpretar correctamente el tablero de Power BI y las capturas del Entregable 5.

**Métrica de verificación:** una persona del equipo sigue la guía sin asistencia y logra ejecutar al menos una consulta de cada requisito funcional.

### RNF-10 — Mantenibilidad

El código de descarga y de carga debe ser modular, con argumentos claros —lote, número de conexiones, base de datos, tabla destino, tamaño de lote—, de modo que permita actualizar los datos mensualmente y refrescar el tablero de Power BI sin cambios de código. Las credenciales deben leerse de variables de entorno y **nunca** escribirse en el repositorio.

**Métrica de verificación:** cambiar el tamaño de lote y el número de conexiones se hace solo con argumentos, y ninguna contraseña está versionada.

---

# 3. Trazabilidad: requisito → entregable → evidencia

| Requisito | Entregable | Evidencia esperada |
|---|---|---|
| RF-01, RF-02 | **E4 · ETL** | `sql/ETL/README_ETL.md` §Descarga, §Carga + `sql/ETL/01_cargar_bronce.sql` |
| RF-03, RF-04, RF-05 | **E4 · ETL** | `sql/ETL/README_ETL.md` §Mapeo de tipos, §Sanidad de fechas, §Tipificación |
| RF-06 | **E2 · Modelo** | `modelo_relacional.md` §Modelo lógico + `sql/02_modelo_gold.sql` |
| RF-07 a RF-13 | **E2 · Modelo** | `consultas_ejemplos.md` + vistas en `sql/02_modelo_gold.sql` |
| RF-14 | **E1 · Volumetría** + QA | `calidad_datos.md` + reporte de integridad de `docs/plan_Entrega.md` §S5 |
| RF-15 a RF-18, RF-20 | **E5 · Fotos** | Tablero Power BI + capturas en `docs/imagenes/` |
| RF-19 | **E1 · Volumetría** §8 | `calidad_datos.md` |
| RNF-01, RNF-02, RNF-03 | **E4 · ETL** | `sql/ETL/README_ETL.md` §Rendimiento + `postgresql.conf` documentado |
| RNF-04 | **E2 · Modelo** | `decisiones_tecnicas.md` §Particionamiento |
| RNF-05, RNF-06 | **E1 · Volumetría** | `volumetria.md` §1 (medido vs proyectado) + RNF-04 |
| RNF-07 | **E4 · ETL** | `instalacion-postgresql-dbeaver.md` §Codificación |
| RNF-08 | **E5 · Fotos** | Procedimiento de verificación en `sql/ETL/README_ETL.md` |
| RNF-09 | Todos | `README.md` + `docs/README.md` |
| RNF-10 | **E4 · ETL** | Argumentos CLI documentados + `.gitignore` de credenciales |

---

# 4. Roles, actividades y definición de "hecho"

| Miembro | Rol | Actividades principales | Entregable | Criterio de aceptación |
|---|---|---|---|---|
| **José** | ETL / Administrador de PostgreSQL | Implementar la descarga paginada y la carga por lotes (RF-01, RF-02), definir los tipos (RF-03), el saneamiento de fechas (RF-04) y la tipificación de categorías (RF-05), construir el modelo físico (RF-06), documentar Medallion y el ETL (Entregables 3 y 4), afinar índices y particionado (RNF-01 a RNF-04) | `sql/ETL/README_ETL.md`, `sql/02_modelo_gold.sql` | 16.025.993 filas en bronce y 13.005.402 en plata, cargadas y verificadas; `count(*)` coincide con la API; consultas < 5 s; ocupa < 46 GB |
| **Kerin** | Analista de Datos | Medir y documentar la volumetría (RF-06, RNF-05, RNF-06), construir el modelo conceptual y lógico de la bodega (Entregable 2), escribir las consultas analíticas de RF-07 a RF-13 y las vistas de RF-13 | `volumetria.md`, `modelo_relacional.md`, `consultas_ejemplos.md` | Volumetría con 4 proyecciones y 8 consultas de verificación; modelo con 2 diagramas PlantUML y DDL; ≥ 15 consultas verificadas |
| **Isabella** | QA / Visualización | Validar la integridad de la carga (RF-14, RNF-08), medir la calidad de datos (RF-19, RNF-07), construir el tablero de Power BI con KPIs, evolución, mapa, concentración y filtros (RF-15 a RF-18, RF-20), y capturar las evidencias gráficas (Entregable 5), documentar la reproducibilidad (RNF-09) | Tablero Power BI, `docs/imagenes/`, `calidad_datos.md` | Los KPIs coinciden con el SQL; las 4 clases de anomalías están cuantificadas; ≥ 5 PNG en alta resolución |

**Definición de "hecho" común:** un requisito se marca como completado cuando su evidencia existe, se verifica con datos reales (no estimaciones) contra la fuente, y es revisado por los otros dos miembros mediante revisión cruzada comentada en el repositorio. Ningún requisito se completa con una proyección: la volumetría proyecta, pero la entrega exige medir.

---

# 5. Requisitos de datos y no negociables

Estos requisitos derivan directamente de la medición del origen y **no admitenatatamiento silencioso**:

| # | Requisito | Valor medido |
|---|---|---|
| D-01 | Volumen mínimo de registros | **16.025.993** (> 10.000.000 exigido) |
| D-02 | Grano de la tabla de hechos | 1 fila = 1 contrato registrado, sin colapsar los 4.621.012 repetidos |
| D-03 | Fidelidad de columnas | Los 22 campos de origen representados; ningún campo eliminado sin documentar |
| D-04 | Nulos | Los nulos solo pueden estar en las 3 columnas de fecha; cualquier otro nulo es un error de carga |
| D-05 | Rango de fechas | Solo años en [1994, 2026] en las vistas analíticas; el rango real de firma es 2000–2026 |
| D-06 | Valores de contrato | Excluir `= 0` (medido: **802.977**) y centinelas `>= 1e12` (medido: **597**) de todo KPI monetario |
| D-07 | Departamentos | 38 valores crudos → 35 categorías (33 departamentos reales + `No Definido` + `Colombia` inválido) |
| D-08 | Dimensiones | Medido en la carga completa: **15.928** entidades, **2.508.996** proveedores, 33 departamentos, 18 tipos documentales. `dim_ubicacion` se eliminó (ver `decisiones_tecnicas.md` §2) |
| D-09 | Plataforma de origen | Preservar SECOP I (14.603.263) y SECOP II (8.066.765) como atributo, no colapsarlos |
| D-10 | Licencia y atribución | Los datos son CC BY-SA 4.0 de Colombia Compra Eficiente y deben llevar atribución en toda la documentación |

---

# 6. Referencias

| Documento | Contenido |
|---|---|
| [volumetria.md](volumetria.md) | **Entregable 1** — mediciones que respaldan los requisitos de datos D-01 a D-10 |
| [Plan_Entrega.md](Plan_Entrega.md) | Calendario de las 6 sesiones, roles y actividades por persona |
| modelo_relacional.md | Entregable 2 — RF-06, RNF-04 |
| sql/ETL/README_ETL.md | Entregables 3 y 4 — RF-01 a RF-05, RNF-01 a RNF-03 |
| consultas_ejemplos.md | RF-07 a RF-13 |
| calidad_datos.md | RF-14, RF-19, RNF-07 |
| visualizaciones.md + imagenes/ | Entregable 5 — RF-15 a RF-18, RF-20 |
| instalacion-postgresql-dbeaver.md | RNF-07, RNF-09 |
| decisiones_tecnicas.md | RNF-04, RNF-10 |
