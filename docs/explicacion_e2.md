# Explicación teórica del Entregable 2

**Proyecto:** Data Warehouse SECOP · Capa oro y modelo relacional
**Base de datos:** `secop_dw` · **DDL:** `sql/02_modelo_gold.sql` · **Vistas:** `sql/04_vistas.sql`
**Estado:** actualizado tras las correcciones del profesor y tras corregir la regla R5 en plata

---

## 1. Objetivo del Entregable 2

El Entregable 2 define, documenta y valida la **capa oro** del Data Warehouse `secop_dw`: un **modelo en estrella** construido a partir de los requerimientos de negocio, junto con su modelo relacional conceptual y lógico.

El resultado permite que la información de contratación pública (SECOP I y SECOP II) esté estructurada para el análisis, con trazabilidad hasta el archivo de origen, integridad referencial verificada y lista para ser consumida desde Power BI.

El trabajo asegura la alineación entre tres cosas: la arquitectura Medallón (bronce → plata → oro), la documentación técnica y la implementación física en PostgreSQL.

## 2. El modelo sale de los requerimientos

Una corrección del profesor fue que **el modelo estrella debe crearse a partir de los requerimientos**. Por eso el orden de trabajo fue este:

1. Se redactaron **14 requerimientos de negocio** (RQ01 a RQ14): qué necesita saber un usuario del dato (valor por entidad y año, evolución anual, contratación directa, concentración de proveedores, geografía, duración, estacionalidad, estado de los contratos, valor gastado, entre otros).
2. De cada requerimiento se dedujo qué **dimensión** y qué **medida** necesita.
3. Solo entonces se diseñó el modelo.

Consecuencia de método: **una columna entra al modelo únicamente si algún requerimiento la usa.** Por eso el tipo de documento del proveedor no llega a oro, y el texto libre de los objetos y la URL tampoco.

## 3. Arquitectura Medallón aplicada

| Capa | Contenido | Tabla | Filas |
|---|---|---|---:|
| **Bronce** | Copia literal del CSV, todas las columnas en texto, sin transformar | `bronze.secop_raw` | 16.025.993 |
| **Plata** | Datos limpios, tipados, normalizados y deduplicados (reglas R1 a R9b) | `silver.contratos` | 13.005.402 |
| **Oro** | Modelo en estrella, construido exclusivamente desde plata | `gold.*` | 13.005.402 en el hecho |

La diferencia entre bronce y plata son **3.020.591 duplicados exactos** (18,85 %), eliminados por la regla R5. Es la única regla destructiva del ETL: las demás corrigen, marcan o calculan. Entre plata y oro **no se pierde ninguna fila**.

**Cambio de R5 en esta etapa.** La regla conservaba, entre filas duplicadas, la de menor `id_fila`. Pero el dataset no trae la fecha de cada modificación y, en bronce, hay 1.169.445 grupos con la misma llave y estados distintos (avances del ciclo de vida). Ahora R5 conserva la fila de **mayor rango de estado** y, a igualdad, la de menor `id_fila`. El conteo de plata no cambió (13.005.402); cambió cuál fila sobrevive, y con ello algunos estados, fechas y la clasificación de personas.

## 4. Capa oro: diseño del modelo en estrella

### 4.1 Grano

**Una fila de `fact_contrato` es una versión de contrato**, igual a una fila de `silver.contratos`. No es un contrato ni un registro bruto del CSV.

La razón es que SECOP II publica cada modificación de un contrato como una fila nueva. Por eso `SUM(valor_ajustado)` da el dinero correcto y `SUM(valor_contrato)` no: sumar el valor crudo cuenta cada versión completa y multiplica el dinero (≈ 692 billones en 2018 frente a ≈ 100 oficiales; con `valor_ajustado` la cifra es 102,54).

### 4.2 Cinco dimensiones

| Dimensión | Qué describe | Responde |
|---|---|---|
| `dim_tiempo` | Calendario 2000-01-01 a 2060-12-31 más el registro `-1 SIN FECHA` (22.282 filas) | RQ02, RQ09 |
| `dim_entidad` | Entidad contratante: código, NIT, nombre, nivel | RQ01, RQ03, RQ07 |
| `dim_ubicacion` | Par departamento-municipio de la entidad contratante | RQ05 |
| `dim_proveedor` | Proveedor por documento, con `tipo_persona` | RQ04, RQ10 |
| `dim_contrato` | Combinación de modalidad, tipo, estado y origen, con atributos derivados | RQ03, RQ06, RQ08, RQ11, RQ13 |

Decisiones que conviene conocer:

- **`dim_contrato` reúne cuatro atributos en una sola dimensión.** Modalidad, tipo, estado y origen describen cómo es el contrato y se consultan juntos. Con solo 1.014 combinaciones reales, una dimensión basta y el hecho necesita una clave en lugar de cuatro.
- **`dim_ubicacion` está separada de `dim_entidad`**, porque RQ05 es un requerimiento geográfico en sí mismo.
- **`dim_tiempo` usa una clave entera AAAAMMDD** (`sk_tiempo`) y se usa con **tres roles** en el hecho: firma, inicio y fin. Así RQ06 puede calcular duraciones.
- **Todas las dimensiones tienen un registro `-1` (`NO REGISTRA`, o `SIN FECHA` en tiempo).** Las claves foráneas del hecho son `NOT NULL DEFAULT -1`, de modo que ninguna fila se pierde por una categoría ausente y «¿cuántos contratos no traen entidad?» se responde con un `WHERE`.
- **Los `UNIQUE` de las claves naturales son planos**, sin collation especial: la normalización ocurrió antes, en plata, y es determinista.
- **Se usan secuencias y no `IDENTITY`**, para poder insertar el `-1` de forma explícita.

### 4.3 Tabla de hechos

`fact_contrato`, con una fila por versión de contrato. Sus columnas se agrupan así:

| Categoría | Columnas |
|---|---|
| Claves | `sk_fecha_firma` + `id_fila` (clave primaria compuesta); `sk_fecha_inicio`, `sk_fecha_fin`, `sk_entidad`, `sk_ubicacion`, `sk_proveedor`, `sk_contrato` |
| Llaves degeneradas | `id_contrato`, `id_proceso` |
| Medidas | `valor_contrato` (no se suma), `valor_ajustado` (la que se suma), `valor_gastado`, `duracion_dias`, `contrato_unidad` |
| Banderas de calidad | `es_atipico`, `es_valor_extremo`, `es_valor_cero`, `es_valor_relleno`, `es_valor_repetido`, `es_version_contrato`, `es_fecha_invalida`, `es_fechas_incoherentes` |

**Llaves degeneradas.** Una llave degenerada es un identificador que vive en el hecho y no tiene dimensión propia porque no tiene atributos que describir. Aquí quedan solo `id_contrato` e `id_proceso`: sirven para agrupar las versiones de un contrato y bajar al detalle. Modalidad, tipo, estado y origen **no** son llaves degeneradas, sino atributos de `dim_contrato`.

**`valor_gastado`.** La fuente no trae valor pagado ni ejecutado, así que «gastado» es el **valor contratado vigente**: igual a `valor_ajustado` si el contrato no es atípico y su estado no es precontractual, cancelado ni desconocido; 0 en los demás casos. Nunca debe presentarse como dinero pagado.

**Trazabilidad.** `id_fila` es la misma clave en bronce, plata y oro. Una cifra de oro se audita hasta el CSV de origen con un `JOIN` por `id_fila`.

### 4.4 Reglas de negocio derivadas

No son mediciones, son definiciones del proyecto, y cada una vive en una función o un `UPDATE` del DDL:

- **`tipo_persona`:** NATURAL, JURIDICA o NO CLASIFICADO, según el tipo de documento. El `NIT` genérico se clasifica con una heurística (9 dígitos que empiezan por 8 o 9 son JURIDICA). La asignación es **por documento**: si un documento aparece con tipos distintos, JURIDICA gana sobre NATURAL y NATURAL sobre NO CLASIFICADO.
- **`es_competitiva`:** FALSE para contratación directa, otras formas de contratación directa y régimen especial (decisión del grupo); TRUE para el resto. Como ≈ 89,7 % de las filas son no competitivas, el indicador debe mostrarse desglosado por modalidad.
- **`agrupacion_estado` y `rango_estado`:** ciclo de vida en siete grupos (precontractual, inicio, vigente, suspendido o cedido, terminado, cerrado, cancelado). Es una **regla provisional**; el orden de suspendido y cedido es juicio del equipo.

### 4.5 Particionamiento

`fact_contrato` se particiona por rango sobre `sk_fecha_firma` (un entero con forma de fecha). Son **13 particiones**, todas en el esquema `gold`:

| Tipo | Rango | Cantidad |
|---|---|---:|
| Cuarentena `pre2017` | desde el mínimo hasta 2017 (incluye el `-1`) | 1 |
| Anuales | 2017 a 2027 | 11 |
| Por defecto `resto` | el resto | 1 |

Añadir 2028 requiere únicamente crear una partición nueva, sin migrar las 13 millones de filas (RNF-04, escalabilidad). La clave primaria es compuesta, `(sk_fecha_firma, id_fila)`, porque PostgreSQL exige que incluya la clave de partición; como empieza por la fecha, también cubre los rangos de fecha.

### 4.6 Integridad e índices

- **`UNIQUE`** en las claves naturales de las cuatro dimensiones categóricas, lo que garantiza joins 1:1 sin multiplicar filas y hace la carga idempotente.
- **Claves foráneas** explícitas desde el hecho hacia las cinco dimensiones (tiempo con tres roles).
- **Siete índices adicionales** además de la clave primaria: un BRIN sobre `sk_fecha_firma`, uno compuesto `(sk_fecha_firma, valor_ajustado)` y uno por `sk_proveedor`, `sk_entidad`, `sk_ubicacion`, `sk_contrato` e `id_contrato`.
- **Sin índice** sobre `es_atipico` (booleano casi siempre falso) ni sobre `valor_ajustado` suelto (lo cubre el compuesto).
- **Carga por tramos** (`lote_desde` y `lote_hasta`) e **idempotencia**: con `-v recrear=1` se reconstruye solo oro, sin tocar bronce ni plata.

### 4.7 Capa de consumo

Power BI se conecta **solo** a `gold.v_*` y `gold.mv_*`. El filtro de dinero (`NOT es_atipico AND NOT es_fecha_invalida AND sk_fecha_firma <> -1`) vive en la vista y no en el tablero, porque un filtro de Power BI se puede desactivar con un clic.

| Origen | Objetos |
|---|---|
| `02_modelo_gold.sql` | `v_contratos` (auditoría, con todas las banderas) y `v_contratos_validos` (detalle ya filtrado) |
| `04_vistas.sql` | 8 vistas materializadas y 14 vistas normales, que responden RQ01 a RQ14 |

Las vistas que agrupan por año llevan `es_anio_parcial`, que marca el último año presente en los datos (2026, corte 29/09/2026). La variación interanual de 2026 se calcula igual, pero compara un año incompleto.

## 5. Documentación del Entregable 2

| Documento | Contenido |
|---|---|
| `docs/modelo_relacional.md` | Modelo conceptual y lógico, diagramas PlantUML, normalización, grano, trazabilidad y vistas |
| `docs/decisiones_tecnicas.md` | Por qué el modelo es así, con las alternativas descartadas |
| `docs/requerimientos.md` | RQ01 a RQ14, requisitos funcionales y no funcionales |
| `docs/volumetria.md` | Volumetría del corte vigente (Entregable 1) |
| `docs/medicion_estados_y_documentos.md` | Medición de estados y tipos de documento que respalda las reglas de negocio |
| `docs/bitacora_sesiones.md` | Errores encontrados y cómo se resolvieron |

## 6. Alineación del repositorio con `secop_dw`

El proyecto tuvo dos pipelines en paralelo, y se resolvió cuál alimenta la capa oro:

- **Pipeline archivado** (`sql/retirado/`): `01_esquema.sql`, `descargar_secop.py` y `cargar_secop.py` pertenecen al modelo anterior (`secop_integrado`, `staging`, `silver.contrato` sin deduplicar, 22.670.028 filas). Se movieron con `git mv`, para conservar el historial, y `sql/retirado/README.md` explica por qué se retiraron: con ese modelo, sumar `valor_contrato` daba ≈ 692 billones frente a ≈ 100.
- **Pipeline vigente** (`sql/ETL/`): bronce y plata con `bronze.secop_raw` y `silver.contratos` (deduplicada), alineado a `secop_dw`.
- **Instalación:** `sql/00_instalacion.sql` crea los roles, la base `secop_dw` y los esquemas `bronze`, `silver`, `gold` y `logs`.
- **Inicio rápido:** el README tiene dos rutas (base ya cargada, o montaje desde cero), para evitar ejecutar el DDL legado por error.

## 7. Correcciones del profesor

| # | Corrección | Cómo quedó |
|---|---|---|
| 1 | El modelo sale de los requerimientos | RQ01 a RQ14 y modelo derivado de ellos |
| 2 | Eliminar tipo de documento | Reemplazado por `tipo_persona` |
| 3 | Analizar anulaciones | Reformulado como RQ13 «estado del contrato» |
| 4 | Corregir llaves degeneradas | Solo `id_contrato` e `id_proceso` |
| 5 | Métrica «gastado» | `valor_gastado` |
| 6 | Más métricas | `valor_gastado`, `contrato_unidad`, `duracion_dias` |
| 7 | Introducción sin preguntas | Pendiente |
| 8 | Objetivos específicos más cortos | Pendiente |

**Hallazgo sobre las anulaciones:** el estado «ANULADO» **no existe** en la fuente. Lo más cercano son `CANCELADO` y `TERMINADO ANORMALMENTE…`, que suman **84 filas (0,0006 %)**. Por eso el requisito pasó a ser el estado del contrato en general.

## 8. Validación

La verificación se ejecutó sobre la **carga completa** de oro (13.005.402 filas), no sobre un fixture. Resultados de la verificación 9 del DDL:

| Control | Resultado |
|---|---|
| Objetos de oro (5 dimensiones + 1 hecho) | 6 |
| Particiones, todas en `gold` | 13 |
| Huérfanos por clave foránea (7 claves) | 0 |
| Plata menos oro | 0 (13.005.402 = 13.005.402) |
| Claves primarias duplicadas | 0 |
| `dim_tiempo` | 22.282 filas, sin huecos |
| Estados sin agrupar | 0 |
| `valor_gastado` mayor que `valor_ajustado` | 0 |
| Atípicos | 33.939 (coincide con plata) |
| Dinero de 2018 sin atípicos | **102,54 billones** (oficial ≈ 100) |
| `secop_lectura` | ve `gold`, no ve `silver` |

Cardinalidades medidas (con el registro `-1`): `dim_entidad` 15.822, `dim_ubicacion` 1.177, `dim_proveedor` 2.181.587, `dim_contrato` 1.015 y `dim_tiempo` 22.282.

Además, la plata que alimenta a oro pasó **18 de 18 validaciones en SQL** y **43 de 43 pruebas independientes en Python**, que vuelven a limpiar una muestra de ≈ 100.000 filas con otra herramienta y comparan columna por columna.

Las capas de consumo se verificaron con 24 objetos (8 materializadas y 16 vistas) legibles por el rol de solo lectura, y con el valor total idéntico en las seis fuentes.

## 9. Conclusión

El Entregable 2 queda **cerrado y validado**: el modelo en estrella de cinco dimensiones sale de los requerimientos de negocio, está documentado, cargado con las 13.005.402 filas de plata y verificado contra PostgreSQL. La capa oro queda lista para su consumo exclusivo desde Power BI a través de las vistas `gold.v_*` y `gold.mv_*`.

Lo que sigue abierto no es del modelo sino de decisión: confirmar con el profesor la definición de «gastado» y comunicarle que «ANULADO» no existe en la fuente.