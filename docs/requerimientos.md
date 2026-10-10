# Requerimientos del Proyecto — SECOP Integrado

**Proyecto:** Data Warehouse de contratación pública de Colombia (SECOP I + SECOP II) sobre datos abiertos oficiales, con arquitectura Medallón en PostgreSQL.
**Fuente:** [SECOP Integrado](https://www.datos.gov.co/Estad-sticas-Nacionales/SECOP-Integrado/rpmr-utcd) · ID Socrata `rpmr-utcd` · Agencia Nacional de Contratación Pública — Colombia Compra Eficiente.
**Corte vigente:** descargado el 29/09/2026 · contratos firmados 2017-2026 · 10 CSV (uno por año).
**Volumetría:** **16.025.993** filas en `bronze` → **13.005.402** en `silver` tras eliminar **3.020.591** duplicados exactos (18,85 %). Detalle en [`volumetria.md`](volumetria.md).
**Motor:** PostgreSQL 18.6 + DBeaver 26.2.0 + Python 3.14 + Power BI Desktop.
**Entrega:** miércoles 14 de octubre de 2026.

**Equipo (3):**

| Miembro | Rol | Responsabilidades |
|---|---|---|
| **Kerin** | Analista de Datos / arquitecto del modelo | Volumetría, modelo conceptual y lógico, métricas, consultas analíticas y vistas de soporte |
| **José** | ETL / Administrador de PostgreSQL | Descarga, carga, capas bronce y plata, Medallón, índices, particionado y tuning |
| **Isabella** | QA / Visualización | Calidad de datos, validación de integridad, tableros en Power BI y evidencias gráficas |

**Reparto:** José → RF-01 a RF-06 y RNF-01 a RNF-04 · Kerin → RF-07 a RF-13, RF-21, RF-22 y RNF-05 a RNF-07 · Isabella → RF-14 a RF-20 y RNF-08 a RNF-10.

> **Cómo se organiza este documento.** Los **requerimientos de negocio (RQ)** dicen qué necesita saber un usuario del dato. Los **requerimientos funcionales (RF)** dicen qué debe hacer el sistema para entregarlo. Los **no funcionales (RNF)** dicen con qué calidad. **El modelo en estrella se deriva de los RQ** (sección 1.2).

---

# 1. Requerimientos de negocio (RQ)

## 1.1 Enunciados

| RQ | Enunciado |
|---|---|
| RQ01 | Valor y número de contratos por entidad y año |
| RQ02 | Evolución anual del número de contratos y del valor, 2017-2026 |
| RQ03 | Porcentaje de contratación directa por entidad |
| RQ04 | Proveedores con mayor concentración de contratos y valor, y número de entidades con las que contratan |
| RQ05 | Departamentos y municipios con mayor valor contratado |
| RQ06 | Duración promedio de los contratos por tipo y modalidad |
| RQ07 | Distribución de valor y contratos entre entidades del orden nacional y territorial |
| RQ08 | Valor total y valor promedio por tipo de contrato |
| RQ09 | Estacionalidad mensual y trimestral de contratos y valor |
| RQ10 | Proporción del valor contratado con personas naturales y jurídicas |
| RQ11 | Participación anual de SECOP II frente a SECOP I |
| RQ12 | Entidades con mayor concentración de contratos atípicos |
| RQ13 | Estado de los contratos: vigentes, terminados, suspendidos, cedidos y cancelados |
| RQ14 | Valor gastado (contratado vigente) por entidad, año y tipo |

**Sobre RQ13.** El profesor pidió analizar anulaciones. La medición ([`medicion_estados_y_documentos.md`](medicion_estados_y_documentos.md)) muestra que **el estado «ANULADO» no existe** en la fuente: lo más cercano son `CANCELADO` y `TERMINADO ANORMALMENTE…`, **84 filas (0,0006 %)**. Por eso el requisito se formula como estado del contrato.

**Sobre RQ14.** La fuente **no trae valor pagado ni ejecutado**. «Gastado» es una **definición derivada**: el valor contratado vigente (ver RF-21). Nunca debe presentarse como dinero pagado.

## 1.2 Trazabilidad RQ → modelo → RF

| RQ | Se responde con | RF que lo soporta |
|---|---|---|
| RQ01 | `dim_entidad` + `dim_tiempo` | RF-07 |
| RQ02 | `dim_tiempo` (año) | RF-10 |
| RQ03 | `dim_entidad` + `es_competitiva` de `dim_clasificacion_contrato` | RF-08 |
| RQ04 | `dim_proveedor` y `COUNT(DISTINCT sk_entidad)` | RF-07 |
| RQ05 | `dim_ubicacion` | RF-11 |
| RQ06 | `duracion_dias` por `tipo_contrato` y `modalidad` | RF-09 |
| RQ07 | `nivel_entidad` de `dim_entidad` | RF-07 |
| RQ08 | `tipo_contrato` de `dim_clasificacion_contrato` | RF-07 |
| RQ09 | mes y trimestre de `dim_tiempo` | RF-10 |
| RQ10 | `tipo_persona` de `dim_proveedor` | RF-12 |
| RQ11 | `origen` de `dim_clasificacion_contrato`, por año | RF-10 |
| RQ12 | `es_atipico` por entidad | RF-07, RF-19 |
| RQ13 | `agrupacion_estado` | RF-22 |
| RQ14 | medida `valor_gastado` | RF-21 |

## 1.3 Modelo en estrella derivado de los RQ

**Grano:** una fila de `gold.fact_contrato` = **una versión de contrato** = una fila de `silver.contratos`. SECOP II publica cada modificación como una fila nueva; el grano es la versión, no el contrato.

**5 dimensiones:**

| Dimensión | Atributos principales | Responde |
|---|---|---|
| `dim_tiempo` | `sk_tiempo` (entero AAAAMMDD), fecha, año, semestre, trimestre, mes, día, `es_sin_fecha` | RQ02, RQ09 |
| `dim_entidad` | `sk_entidad`, `codigo_entidad` (clave natural), nit, nombre, nivel | RQ01, RQ03, RQ07 |
| `dim_ubicacion` | `sk_ubicacion`, departamento, municipio | RQ05 |
| `dim_proveedor` | `sk_proveedor`, `documento_proveedor` (clave natural), nombre, **`tipo_persona`** | RQ04, RQ10 |
| `dim_clasificacion_contrato` | `sk_clasificacion`, modalidad, `es_competitiva`, tipo de contrato, estado, **`agrupacion_estado`**, origen | RQ03, RQ06, RQ08, RQ11, RQ13 |

**Hecho:** llaves foráneas a las 5 dimensiones (tiempo con 3 roles: firma, inicio y fin); llaves degeneradas **solo `id_contrato` e `id_proceso`**; medidas `valor_contrato` (no se suma), `valor_ajustado` (la que se suma), **`valor_gastado`**, `duracion_dias`, `contrato_unidad`; las 8 banderas de calidad. **Particionada por RANGE sobre `sk_fecha_firma`: 13 particiones** (cuarentena + 2017-2027 + por defecto).

> **Decidido:** `dim_tiempo` va de 2000 a 2060, con clave entera AAAAMMDD y el registro -1 «SIN FECHA», como en las diapositivas. La dimensión de clasificación se llama `dim_contrato`.

---

# 2. Requisitos funcionales (RF)

## 2.1 Responsable: José — ETL / Administrador de PostgreSQL

### RF-01 — Descarga íntegra del dataset

El sistema debe obtener la totalidad de los contratos firmados 2017-2026 desde la API oficial de Socrata, en **10 archivos CSV, uno por año**, sin depender de la ficha web del portal, cuyo conteo está desfasado.

**Criterio de aceptación:** `count(*)` sobre `bronze.secop_raw` = **16.025.993** y cada archivo coincide con su conteo (2017 = 1.498.976 filas, … 2026 = 1.291.923).

### RF-02 — Carga por `COPY` y trazabilidad

El sistema debe cargar los 10 CSV en `bronze.secop_raw` con `COPY`, todo en texto, para que ninguna fila se rechace por tipo. Cada fila lleva `id_fila` (identificador correlativo), `fecha_carga` y `archivo_origen`.

**Criterio de aceptación:** los 10 archivos quedan con rangos de `id_fila` consecutivos, terminando en 16.025.993, y la bitácora `bronze.log_cargas` tiene una fila por archivo.

### RF-03 — Mapeo de tipos a esquema nativo

La capa plata debe convertir las columnas de texto a tipos nativos: fechas a `date`, `valor_contrato` a `numeric(18,2)` y el resto a `text`; NIT y documentos quedan solo con dígitos.

**Criterio de aceptación:** `information_schema.columns` en `silver.contratos` refleja los tipos esperados y ninguna fecha queda como `text`.

### RF-04 — Validación y saneamiento de fechas

La regla R4 debe pasar a `NULL` y marcar con `flag_fecha_invalida` toda fecha de firma anterior a 2000-01-01 o posterior a la fecha de descarga, y toda fecha de inicio o fin fuera de 2000-2060. Las fechas incoherentes entre sí (fin anterior a inicio) se **marcan, no se corrigen**.

**Criterio de aceptación:** la prueba 1 de `05_qa_silver.sql` da 0 en las tres pruebas de rango de fechas y en «fin antes del inicio sin marcar».

### RF-05 — Normalización, homologación y deduplicación

El sistema debe:

1. Normalizar los textos (R1: mayúsculas, sin tildes, sin espacios dobles ni barras sueltas) y convertir los nulos disfrazados en `NULL` (R2).
2. Unificar nombres equivalentes con el catálogo `silver.homologacion`, de 17 reglas (R3).
3. **Eliminar los duplicados exactos (R5) conservando el registro con el estado de mayor avance del ciclo de vida** (ranking de RF-22), y no el de menor `id_fila`. El dataset no trae fecha de modificación, de modo que `id_fila` no permite decidir el estado vigente. En bronce hay **1.169.445 grupos** idénticos en contrato, proceso, proveedor, valor y fecha de firma con estados distintos.

**Criterio de aceptación:** plata sin duplicados (prueba 2 de QA = 0) y, para los grupos con estados distintos, la fila conservada es la de mayor rango.

### RF-06 — Modelo en estrella con claves primarias y foráneas

El sistema debe construir el modelo de la sección 1.3 a partir de `silver.contratos`:

- **1 tabla de hechos** `fact_contrato` y **5 dimensiones** (`dim_tiempo`, `dim_entidad`, `dim_ubicacion`, `dim_proveedor`, `dim_clasificacion_contrato`).
- Claves sustitutas enteras en las 5 dimensiones, claves naturales con `UNIQUE`, y llaves foráneas explícitas.
- Registro **-1 «NO REGISTRA»** en cada dimensión; en `dim_tiempo`, «SIN FECHA».
- `fact_contrato` particionada por rango sobre `sk_fecha_firma`, **13 particiones**. La clave primaria es compuesta (`sk_fecha_firma`, `id_fila`) porque PostgreSQL exige que incluya la clave de partición.
- `id_fila` heredado de plata y bronce, para auditar una cifra hasta el CSV de origen.
- **No existe `dim_tipo_documento`**: el tipo documental no se modela (se resume en `tipo_persona`).

**Criterio de aceptación:** 0 filas huérfanas por cada FK, `count(*)` de `fact_contrato` = 13.005.402, 13 particiones, todas en el esquema `gold`.

## 2.2 Responsable: Kerin — Analista de Datos

### RF-07 — Concentración y distribución del contrato público

El sistema debe permitir medir valor y número de contratos por entidad y año (RQ01), la concentración por proveedor con ranking, porcentaje acumulado, HHI y número de entidades con las que contrata (RQ04), la distribución entre nivel nacional y territorial (RQ07), valor total y promedio por tipo de contrato (RQ08) y las entidades con más contratos atípicos (RQ12).

**Criterio de aceptación:** las consultas devuelven el top 20 de entidades y de proveedores con su porcentaje acumulado. Todo valor monetario usa `valor_ajustado` excluyendo `es_atipico`.

### RF-08 — Contratación directa, régimen especial y mínima cuantía

El sistema debe calcular, por entidad, el porcentaje de contratos por modalidades **no competitivas** (`es_competitiva = false`): contratación directa, otras formas de contratación directa y régimen especial (RQ03). Debe poder mostrarse desglosado por modalidad, para distinguir cuánto es contratación directa y cuánto régimen especial. También debe permitir detectar posibles fraccionamientos: entidades con muchos contratos de mínima cuantía al mismo proveedor en ventanas de 30 y 90 días.

**Criterio de aceptación:** la consulta devuelve el ranking de entidades por porcentaje no competitivo, con su desglose por modalidad, y el listado de entidad-proveedor con mayor número de contratos de mínima cuantía por ventana.

### RF-09 — Duración de los contratos

El sistema debe analizar `duracion_dias` por tipo de contrato y modalidad (RQ06), con promedio, mediana y percentiles, excluyendo los contratos con `es_fechas_incoherentes` o `es_fecha_invalida`.

**Criterio de aceptación:** el reporte devuelve promedio, mediana y percentiles 25/50/75/95 por tipo y por modalidad.

### RF-10 — Evolución y estacionalidad

El sistema debe analizar la serie anual de contratos y valor 2017-2026 con variación interanual (RQ02), la estacionalidad mensual y trimestral (RQ09) y la participación anual de SECOP II frente a SECOP I (RQ11). **El año 2026 es parcial** (llega hasta el 29/09/2026) y debe señalarse como tal en toda comparación.

**Criterio de aceptación:** la serie devuelve 10 años, la variación se calcula contra el año anterior presente, y 2026 aparece marcado como parcial.

### RF-11 — Análisis geográfico

El sistema debe agregar contratos y valor por departamento y municipio (RQ05) usando `dim_ubicacion`, con los nombres ya normalizados por R1 y R3 (Bogotá en una sola categoría).

**Criterio de aceptación:** la suma por departamento cuadra con el total nacional y Bogotá D.C. aparece una sola vez.

### RF-12 — Perfil de proveedores por tipo de persona

El sistema debe clasificar cada proveedor como `NATURAL`, `JURIDICA` o `NO CLASIFICADO` (`tipo_persona`) y calcular la proporción del valor contratado con cada grupo (RQ10).

Regla de clasificación (**definición del proyecto, no medición**):

| tipo_persona | Criterio |
|---|---|
| NATURAL | Cédula de ciudadanía, NIT de persona natural, cédula de extranjería, pasaporte, tarjeta de identidad, registro civil, NUIP, carné diplomático, permiso por protección temporal, permiso especial de permanencia |
| JURIDICA | NIT de persona jurídica, sociedades extranjeras, número de fideicomiso, y `NIT` genérico con documento de 9 dígitos que empieza por 8 o 9 (heurística que cubre el 94,5 % de los `NIT` genéricos) |
| NO CLASIFICADO | NIT de extranjería, otro, nulos y `NIT` genérico que no cumple la heurística |

**Criterio de aceptación:** `NATURAL` 9.979.286 + `JURIDICA` 2.903.235 + `NO CLASIFICADO` 122.881 = 13.005.402 filas (medido en oro); la suma de proporciones del valor es 100 %. La clasificación es **por documento**: si un mismo documento aparece con tipos distintos, JURIDICA gana sobre NATURAL, y NATURAL sobre NO CLASIFICADO (83.765 documentos, 2.554.879 filas).

### RF-13 — Vistas de consumo reutilizables

El sistema debe exponer vistas (y vistas materializadas si el rendimiento lo exige) que sean el origen único de Power BI y de RF-07 a RF-12, sin duplicar la lógica de agregación. La vista de consumo excluye atípicos y fechas inválidas, para que el filtro no dependa del tablero.

**Criterio de aceptación:** Power BI se conecta solo a esas vistas y cada una responde en menos de 5 segundos.

### RF-21 — Métrica `valor_gastado`

El sistema debe calcular `valor_gastado` en cada fila del hecho. Es el **valor contratado vigente**:

- Es igual a `valor_ajustado` cuando `agrupacion_estado` es distinta de `PRECONTRACTUAL` y de `CANCELADO` **y** `es_atipico = false`.
- Es **0** en cualquier otro caso (así el `SUM` no necesita filtros). *Pendiente de confirmar: 0 frente a NULL.*

La fuente **no trae valor pagado ni ejecutado**; esta métrica es una definición derivada y no debe presentarse como dinero pagado. Debe confirmarse su definición con el profesor.

**Criterio de aceptación:** `SUM(valor_gastado)` ≤ `SUM(valor_ajustado)` filtrado por `NOT es_atipico`, y la diferencia equivale exactamente al valor de las filas precontractuales y canceladas.

### RF-22 — Estado del contrato y ciclo de vida

El sistema debe asignar a cada estado de la fuente una `agrupacion_estado` según el siguiente ranking (**regla de negocio provisional, no medición**), que RF-05 usa para decidir qué fila conserva:

| Rango | Agrupación | Estados |
|---:|---|---|
| 1 | PRECONTRACTUAL | BORRADOR, EN APROBACION, ENVIADO PROVEEDOR, CONVOCADO, ADJUDICADO |
| 2 | INICIO | APROBADO, ACTIVO, CELEBRADO |
| 3 | VIGENTE | EN EJECUCION, MODIFICADO, PRORROGADO |
| 4 | SUSPENDIDO / CEDIDO | SUSPENDIDO, CEDIDO |
| 5 | TERMINADO | TERMINADO, TERMINADO SIN LIQUIDAR, LIQUIDADO |
| 6 | CERRADO | CERRADO |
| 7 | CANCELADO | CANCELADO, TERMINADO ANORMALMENTE… (patrón `TERMINADO ANORMALMENTE%`) |

Está respaldado por los datos que `CERRADO` > `EN EJECUCION` y `MODIFICADO`, y `TERMINADO` > ambos. **El orden de SUSPENDIDO y CEDIDO es juicio del equipo, sin medición.** SECOP I y SECOP II usan vocabularios distintos y el mapeo los une en una sola escala.

**Criterio de aceptación:** ningún estado de `silver.contratos` queda sin agrupación (salvo el nulo, que va a `NO REGISTRA`) y el RQ13 se responde con un `GROUP BY agrupacion_estado`.

## 2.3 Responsable: Isabella — QA / Visualización

### RF-14 — Verificación de integridad de la carga

El sistema debe comparar el conteo cargado contra la fuente y reportar discrepancias, sin usar el conteo de la ficha web.

**Criterio de aceptación:** `count(*)` = **16.025.993** en bronce, **13.005.402** en plata y **13.005.402** en `fact_contrato`; la diferencia bronce-plata (3.020.591) queda explicada por R5.

### RF-15 — Panel de KPIs globales

Power BI debe mostrar total de versiones de contrato (13.005.402), total de contratos distintos (554.063 de ellos con versiones), valor contratado, valor gastado, número de entidades, de proveedores y de departamentos.

> Los recuentos de entidades, proveedores y municipios son `count(distinct …)` sobre texto libre y **se miden después de construir oro**; no se estiman.

**Criterio de aceptación:** cada KPI coincide con su consulta SQL equivalente.

### RF-16 — Tablero de evolución temporal

Power BI debe visualizar la evolución 2017-2026 por año, trimestre y mes, por tipo de contrato y modalidad, con variación interanual. **2026 se marca como parcial.**

**Criterio de aceptación:** el gráfico cubre 2017-2026 y coincide con la serie de RF-10.

### RF-17 — Mapa geográfico

Power BI debe representar contratos y valor por departamento y municipio, con drill-down y sin duplicar Bogotá.

**Criterio de aceptación:** el mapa coincide con la agregación de RF-11.

### RF-18 — Panel de concentración y proveedores

Power BI debe presentar el top 20 de proveedores por valor, su participación acumulada, el HHI y la proporción de valor por `tipo_persona`.

**Criterio de aceptación:** el ranking es idéntico al de RF-07 y las proporciones al de RF-12.

### RF-19 — Reporte de calidad de datos

El sistema debe reportar, con cantidad y porcentaje, las anomalías de la fuente: fechas imposibles (R4), duplicados eliminados (R5), valores en cero y de relleno (R6), valores repetidos y versiones (R7, R7b) y valores atípicos y extremos (R9, R9b).

**Criterio de aceptación:** el reporte cubre todas las reglas y las cifras coinciden con `05_qa_silver.sql` y la validación independiente en Python (42/42).

### RF-20 — Filtros interactivos y capturas

El tablero debe filtrar de forma coherente por año, departamento, tipo de contrato, modalidad, estado y nivel de entidad en todas las páginas, y cada vista debe reproducirse como captura PNG de alta resolución.

**Criterio de aceptación:** existen al menos 5 capturas PNG en `docs/imagenes/`, rotuladas con los filtros aplicados.

---

# 3. Requisitos no funcionales (RNF)

## 3.1 Responsable: José

### RNF-01 — Rendimiento de la descarga
La descarga de los 10 archivos debe completarse en menos de 90 minutos con conexiones en paralelo, frente a las 4-10 horas del endpoint de archivo completo.
**Verificación:** tiempo total y MB/s promedio.

### RNF-02 — Latencia de las consultas
Las consultas analíticas con índices deben responder en menos de 5 segundos; las limitadas a un año, en menos de 1 segundo.
**Verificación:** `EXPLAIN ANALYZE` de cada consulta de RF-07 a RF-13.

### RNF-03 — Consumo eficiente de recursos
El sistema debe operar dentro de la máquina objetivo (15,3 GB de RAM, 12 núcleos, 129 GB de disco libre), con `shared_buffers = 4GB`, `work_mem = 64MB`, `maintenance_work_mem = 1GB` y `effective_cache_size = 10GB`.
**Verificación:** espacio en disco tras la carga y uso de memoria en carga y consultas.

### RNF-04 — Escalabilidad
El particionado por `sk_fecha_firma` debe permitir añadir un año nuevo con **una sola partición**, sin migrar los 13.005.402 registros existentes. Se espera un crecimiento de unos 1,7 a 2,0 millones de filas por año (proyección, no medición).
**Verificación:** añadir una partición de prueba sin degradar las consultas de años anteriores.

## 3.2 Responsable: Kerin

### RNF-05 — Fidelidad y separación entre dato y regla
La carga debe preservar la totalidad del origen en bronce, en UTF-8. Toda cifra derivada (`valor_ajustado`, `valor_gastado`, `tipo_persona`, `agrupacion_estado` y su ranking) debe documentarse como **regla de negocio**, distinguida de las mediciones. `valor_contrato` se conserva sin modificar.
**Verificación:** cada definición derivada tiene su regla escrita y `valor_contrato` coincide con bronce.

### RNF-06 — Trazabilidad y reproducibilidad
Toda cifra de la documentación debe ser reproducible: proviene de una consulta, o es una proyección con su fórmula. Cada tabla indica si es **medida**, **definida** (regla) o **proyectada**. Cada fila de oro se rastrea hasta el CSV de origen por `id_fila`.
**Verificación:** el JOIN `gold → silver → bronze` por `id_fila` devuelve la fila original.

### RNF-07 — Codificación y compatibilidad regional
La base se crea en UTF-8 con intercalación `es-CO-x-icu`. El texto dañado en el origen (la `ñ` llega como `���`) no se repara y se documenta como limitación.
**Verificación:** consulta con acentos y eñes sin errores de codificación.

## 3.3 Responsable: Isabella

### RNF-08 — Verificación automatizada
Debe existir un procedimiento ejecutable tras cada carga que compruebe conteos por capa, vacíos por columna, duplicados, rango de fechas, huérfanos por FK y tamaño por tabla.
**Verificación:** `05_qa_silver.sql` (42 pruebas) y `06_validacion_python.py` sin pruebas en REVISAR.

### RNF-09 — Documentación reproducible
El README y `docs/` deben permitir a un tercero montar el entorno completo siguiendo los pasos, e interpretar el tablero y las capturas.
**Verificación:** una persona ajena ejecuta una consulta de cada requisito funcional.

### RNF-10 — Mantenibilidad y seguridad
El código debe aceptar argumentos (lote, base, tabla) y leer credenciales solo de variables de entorno, sin versionar contraseñas. `secop_lectura` ve únicamente `gold`.
**Verificación:** ninguna clave en el repositorio y `has_schema_privilege('secop_lectura','silver','USAGE')` = false.

---

# 4. Trazabilidad: requisito → entregable → evidencia

| Requisito | Entregable | Evidencia |
|---|---|---|
| RQ01-RQ14 | **E2 · Modelo** | Sección 1 de este documento |
| RF-01 a RF-05, RNF-01 a RNF-03 | **E3 y E4 · Medallón y ETL** | `sql/ETL/README_ETL.md`, `sql/ETL/*.sql` |
| RF-06, RF-21, RF-22 | **E2 · Modelo** | `modelo_relacional.md`, `sql/02_modelo_gold.sql` |
| RF-07 a RF-13 | **E2 · Modelo** | `consultas_ejemplos.md`, `sql/04_vistas.sql` |
| RF-14, RF-19, RNF-08 | **E1 · Volumetría** + QA | `sql/ETL/resultado_qa.md`, `sql/ETL/reporte_validacion_python.md` |
| RF-15 a RF-18, RF-20 | **E5 · Fotos** | Tablero y `docs/imagenes/` |
| RNF-04 | **E2 · Modelo** | `decisiones_tecnicas.md` §Particionado |
| RNF-05, RNF-06 | **E1 · Volumetría** | `volumetria.md`, `medicion_estados_y_documentos.md` |
| RNF-07, RNF-09, RNF-10 | **E4 · ETL** | `instalacion-postgresql-dbeaver.md`, `.gitignore` |

---

# 5. Requisitos de datos

| # | Requisito | Valor |
|---|---|---|
| D-01 | Volumen mínimo | **16.025.993** en bronce y **13.005.402** en plata (mínimo exigido: 10.000.000) |
| D-02 | Grano de la tabla de hechos | 1 fila = 1 **versión de contrato** (13.005.402); los duplicados exactos se eliminan, las versiones se conservan |
| D-03 | Fidelidad | Todas las columnas de origen llegan a bronce sin transformar |
| D-04 | Rango temporal | Contratos firmados 2017-2026; 2026 parcial (corte 29/09/2026) |
| D-05 | Dinero | Sumar siempre `valor_ajustado` excluyendo `es_atipico`; nunca `valor_contrato` |
| D-06 | Atípicos | Se marcan, no se borran (R9 y R9b) |
| D-07 | Estados | No existe «ANULADO»; cancelaciones = 84 filas (0,0006 %) |
| D-08 | Valor gastado | Definición derivada (valor contratado vigente); la fuente no trae valor pagado |
| D-09 | Plataformas | SECOP I y SECOP II se conservan como atributo `origen`, con vocabularios de estado distintos |
| D-10 | Licencia | CC BY-SA 4.0, Agencia Nacional de Contratación Pública — Colombia Compra Eficiente; la atribución debe aparecer en la documentación y el tablero |

---

# 6. Referencias

| Documento | Contenido |
|---|---|
| [volumetria.md](volumetria.md) | Entregable 1: volumetría del corte vigente |
| [medicion_estados_y_documentos.md](medicion_estados_y_documentos.md) | Medición de estados y tipos de documento que respalda RQ13, RF-12, RF-21 y RF-22 |
| [Plan_Entrega.md](Plan_Entrega.md) | Calendario, roles y estados |
| [modelo_relacional.md](modelo_relacional.md) | Entregable 2: modelo conceptual y lógico |
| [decisiones_tecnicas.md](decisiones_tecnicas.md) | Por qué el modelo es como es |
| `sql/ETL/README_ETL.md` | Entregables 3 y 4: bronce y plata |