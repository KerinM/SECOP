# Bitácora de sesiones

Registro cronológico de lo que se hizo, con los problemas encontrados y cómo se resolvieron. El objetivo es que quien retome el proyecto no tenga que redescubrir los mismos errores.

El proyecto tuvo **dos cortes de datos**:

| Corte | Base | Filas | Sesiones |
|---|---|---:|---|
| **Anterior (retirado)** | `secop_integrado` | 22.670.028 | 1 a 4 |
| **Vigente** | `secop_dw` | 16.025.993 en bronce, 13.005.402 en plata y oro | 5 a 7 |

Las sesiones 1 a 4 se conservan como **histórico**: sus cifras son del corte anterior y no valen para el modelo vigente, pero las lecciones técnicas (permisos, particiones, `PowerShell`) siguen siendo válidas. El pipeline de ese corte quedó archivado en `sql/retirado/`.

---

# Parte 1 · Corte anterior (`secop_integrado`, histórico)

Todas las cifras de esta parte son medidas sobre la carga de **22.670.028 filas**.

## Sesión 1 — Infraestructura

Base de datos, roles y cliente.

- Creada la base `secop_integrado` en PostgreSQL 18.6, con los esquemas `staging`, `silver`, `gold` y `logs`, y la collation no determinista `secop_ci`.
- Roles `secop_etl` (escritura) y `secop_lectura` (solo `gold`, con `default_transaction_read_only`).
- `secop_lectura` **no** tiene `USAGE` sobre `staging` ni `silver`, así que no ve siquiera su existencia. Verificado: `ERROR: permiso denegado al esquema staging`.
- DBeaver configurado con `-Xmx3072m`, con las dos conexiones registradas.
- `PlacspBigData` no se tocó.

**Aprendizaje:** el `ALTER DEFAULT PRIVILEGES` necesita `FOR ROLE secop_etl` explícito. Sin eso se aplica a los objetos que crea el rol que ejecuta el script (`postgres`), y Power BI se queda sin ver nada.

---

## Sesión 2 — Tuning

- Creado `scripts/tuning_postgresql.ps1`: se auto-eleva, hace backup de `postgresql.conf`, es idempotente por bloques y deja informe.
- Backup en `postgresql.conf.pre-secop-20260927-211757`.
- 19 valores verificados contra `pg_settings`.
- Se eligió el perfil completo porque había 6 GB libres de 15,3 GB de RAM.

**Aprendizaje:** en PostgreSQL 18 `wal_compression` muestra el valor `pglz`, no el `lz4` que devuelve la documentación de versiones anteriores. Verificar contra `pg_settings` y no contra la memoria.

---

## Sesión 3 — Modelo y carga de prueba

- Escrito `sql/01_esquema.sql` (hoy en `sql/retirado/`): staging de 22 columnas `text`, silver de 26, `gold.fact_contrato` de 20 columnas con 30 particiones, 8 dimensiones y la vista `v_contratos`.
- Probada la función `es_fecha_valida` con 11 casos, incluidos los años imposibles.
- Cargadas 3 páginas (150.000 filas) de punta a punta.

### Errores encontrados

1. **`HAVING` sobre un alias que no resuelve.** `HAVING clave IS NOT NULL` en el `INSERT` de `dim_proveedor` daba `UndefinedColumn`. Se movió a `WHERE`, que además se evalúa antes de agrupar.

2. **Un `TRUNCATE` sin `RESTART IDENTITY` dejó la secuencia corrida.** Tras una carga de prueba de 150.000 filas, la carga completa empezó en `id_contrato` 150.001 en vez de 1, y terminó en 22.820.028. No se perdió ninguna fila porque la PK no dependía de la secuencia, pero el hueco quedó. Se añadió `RESTART IDENTITY` al truncate del script.

3. **Un reemplazo de PowerShell corrompió el código Python.** Sustituyendo texto con `Get-Content`/`Set-Content` se duplicó el prefijo raw de una cadena y quedó un `SyntaxError`. **Regla que queda:** editar con la herramienta de edición de archivos (en este proyecto, VS Code con Ctrl+H), nunca con round-trip de PowerShell. Antes ya había roto acentos y CJK en otro archivo.

---

## Sesión 4 — Descarga y carga completas

### Descarga

- `scripts/descargar_secop.py`: 454 páginas de 50.000 filas con 6 hilos, reintentos y espera creciente ante 429/503.
- Descarga completa: **19,40 GiB, 22.670.028 filas, diferencia +0** contra el `count(*)` de la API.
- El `count(*)` de la API tarda 196 s, y es el número con el que hay que validar: la ficha del portal estaba desfasada en 1,87M.

**Dos hallazgos del origen, que siguen valiendo:**

- El CSV **tiene saltos de línea dentro de los campos**, así que contar líneas no sirve. La verificación usa `csv.reader`.
- El orden de columnas del CSV coincide exactamente con el de la tabla, que es lo que permite emparejar por posición en el `COPY`.

### Carga

| Etapa | Tiempo | Filas |
|---|---:|---:|
| `COPY` a staging | 5,9 min | 22.670.028 |
| staging → silver | 91,8 min | 22.670.028 |
| silver → gold | 144,8 min | 22.670.028 |

Las tres capas cuadraron exactamente, con **0 filas perdidas** en los 8 JOIN.

### El bug de las 28 particiones en `public`

Al medir tamaños apareció una contradicción: la suma por esquema daba 1.487 MB para `gold`, pero los índices por partición daban 20 GB.

La causa: el bucle del DDL que crea las particiones anuales usaba `format('... %I ...', 'fact_contrato_y' || v_anio)` **sin cualificar el esquema**, así que las 28 particiones anuales se crearon en `public` y no en `gold`. No era cosmético: los permisos son por esquema, y `public` tiene `USAGE` concedido a `PUBLIC`, o sea que la tabla de hechos quedaba al alcance de cualquier rol que conectara.

Se corrigió en el DDL con `%I.%I` y, en la base viva, moviendo las 28 con `ALTER TABLE ... SET SCHEMA gold` (solo metadatos).

**Dos consultas y engaños que conviene no repetir:**

- `pg_stat_user_indexes` **no devuelve nada** para una tabla particionada padre, porque el padre no almacena páginas. Hay que recorrer `pg_inherits`.
- En PostgreSQL 18 los contadores de checkpoint están en **`pg_stat_checkpointer`**, no en `pg_stat_bgwriter`.

### Por qué este corte se retiró

Con este modelo, sumar `valor_contrato` daba **≈ 692 billones para 2018** frente a los ≈ 100 oficiales: la base contaba dinero que no existía (duplicados exactos y versiones de un mismo contrato sin ajustar). El problema no era el modelo sino la capa de datos. Ver `sql/retirado/README.md`.

---

# Parte 2 · Corte vigente (`secop_dw`)

Todas las cifras de esta parte son medidas sobre `secop_dw`, salvo que se indique lo contrario.

## Sesión 5 — Cambio de corte: bronce y plata

Se rehízo la base desde los datos, con arquitectura Medallón (`bronze` → `silver` → `gold`).

### Qué se construyó

- **Bronce:** 10 CSV (uno por año, 2017-2026, descargados el 29/09/2026) cargados con `\copy` en `bronze.secop_raw`, todo en texto: **16.025.993 filas**. `01b_trazabilidad_bronce.sql` llenó `archivo_origen` con el año de firma de cada fila y dejó la bitácora `bronze.log_cargas`.
- **Plata:** `silver.contratos` con las reglas R1 a R9, que bajan las filas a **13.005.402** (se eliminan **3.020.591** duplicados exactos, 18,85 %). R5 es la única regla que borra filas; el resto marca o corrige.
- **QA:** `05_qa_silver.sql` (18 validaciones automáticas) y `06_validacion_python.py`, que vuelve a limpiar una muestra de plata con otra herramienta y compara columna por columna.

### Hallazgos

1. **Sumar dinero daba ≈ 692 billones en 2018.** Dos causas, corregidas en `02c_correccion_valores.sql`:
   - **R7b:** en SECOP II un contrato aparece una vez por cada modificación, con valores distintos. Son **554.063 contratos en 1.317.098 filas**. Se cuenta cada contrato una vez, con el promedio de sus versiones.
   - **R9b:** 10 valores imposibles para su entidad (por ejemplo, una alcaldía con un contrato de 25 billones) que R9 no marcaba. Se marcan como atípicos, no se borran.

   Resultado: 2018 queda en **102,54 billones** frente a ≈ 100 oficiales.
2. **538 nombres de proveedor con una barra `|` suelta** al inicio o al final. Se corrigieron con `02b_correccion_barras.sql` y la regla R1 ya las quita.
3. **Texto dañado desde SECOP:** la `ñ` llega como `���`. No se puede reparar con seguridad y solo afecta nombres.
4. **La ficha web del portal está desfasada:** el conteo de referencia es siempre `count(*)` sobre la base.

### Estado al cierre de la sesión

Plata validada: 18 de 18 validaciones en SQL y 42 pruebas en Python, todas en OK. **Esta validación es anterior a la corrección de R5 de la sesión 7.**

---

## Sesión 6 — Correcciones del profesor y rediseño de oro

El profesor devolvió ocho correcciones al modelo. Se trabajó a partir de ellas.

### Las correcciones y qué se hizo

| # | Corrección | Resultado |
|---|---|---|
| 1 | El modelo estrella debe salir de los requerimientos | Se redactaron RQ01 a RQ14 y el modelo se derivó de ellos |
| 2 | Eliminar tipo de documento | Se reemplazó por `tipo_persona` en `dim_proveedor` |
| 3 | Analizar anulaciones | Se reformuló como RQ13 «estado del contrato» (ver hallazgo abajo) |
| 4 | Corregir las llaves degeneradas | Quedan solo `id_contrato` e `id_proceso`; modalidad, tipo, estado y origen van a `dim_contrato` |
| 5 | Añadir la métrica «gastado» | `valor_gastado` (valor contratado vigente) |
| 6 | Más métricas | `valor_gastado`, `contrato_unidad`, `duracion_dias` |
| 7 | Introducción sin preguntas | Pendiente |
| 8 | Objetivos específicos más cortos | Pendiente |

### Modelo resultante

**5 dimensiones** (`dim_tiempo`, `dim_entidad`, `dim_ubicacion`, `dim_proveedor`, `dim_contrato`) y `fact_contrato`, particionada por rango sobre `sk_fecha_firma` (entero AAAAMMDD): **13 particiones**. `dim_tiempo` va de 2000 a 2060 con el registro `-1 SIN FECHA`, y se usa con tres roles: firma, inicio y fin. El grano es **una versión de contrato**, no un contrato.

### Hallazgos de la medición (`docs/medicion_estados_y_documentos.md`, 09/10/2026)

- **El estado «ANULADO» no existe en la fuente.** Lo más cercano son `CANCELADO` (74) y `TERMINADO ANORMALMENTE…` (10): **84 filas, 0,0006 %**.
- **R5 conservaba el menor `id_fila`**, pero en bronce hay **1.169.445 grupos** con la misma llave y estados distintos (avances del ciclo de vida, no contradicciones). Como el dataset no trae fecha de modificación, `id_fila` no dice cuál es el estado vigente. Esto motivó la sesión 7.
- **Tipos de documento:** el `NIT` genérico (262.530 filas) es ambiguo. Se adoptó una heurística: 9 dígitos que empiezan por 8 o 9 → JURIDICA (cubre el 94,5 %). Es heurística, no medición.

### Decisiones de regla de negocio

- **`es_competitiva`:** FALSE para contratación directa, otras formas de contratación directa y **régimen especial** (decisión del grupo). Consecuencia: ≈ 89,7 % de las filas son no competitivas, así que el indicador debe mostrarse desglosado por modalidad.
- **`tipo_persona` se asigna por documento, no por fila:** si un mismo documento aparece con tipos distintos, JURIDICA gana sobre NATURAL y NATURAL sobre NO CLASIFICADO.
- **`valor_gastado`** vale 0 (no NULL) en las filas que no cuentan. Definición derivada: la fuente no trae valor pagado.

### Errores encontrados

1. **`NULL` sin tipo en un `SELECT DISTINCT`.** El `INSERT` de `dim_contrato` fallaba porque PostgreSQL resolvía el `NULL` como `text` y no podía asignarlo a `es_competitiva` (boolean). Se resolvió con `NULL::boolean`. **Lección:** en un `SELECT DISTINCT`, los literales `NULL` necesitan cast explícito.
2. **`n_live_tup` no es una cifra oficial.** `pg_stat_user_tables.n_live_tup` es una estimación y queda inexacta tras un `UPDATE` masivo: el conteo de `dim_proveedor` salió distinto. Para cifras oficiales se usa `count(*)`.

---

## Sesión 7 — R5 corregida, reconstrucción de plata y oro, y capa de consumo

### El cambio de R5

R5 ahora conserva, entre filas duplicadas, la de **mayor rango de estado** (`silver.rango_estado`) y, a igualdad, la de menor `id_fila`. Se eligió **reconstruir plata** y no hacer un `UPDATE` solo del estado, porque en **173.178 de los 1.169.445 grupos (14,8 %)** las filas duplicadas también difieren en `fecha_fin`, y un `UPDATE` habría mezclado el estado de una fila con la fecha de otra.

### Ejecución y orden

1. `02_silver_limpieza.sql` (recrea `silver.contratos`; bronce no se toca).
2. `02c_correccion_valores.sql` (siempre después de `02`). `02b` no hizo falta: la R1 nueva ya quita las barras.
3. `05_qa_silver.sql`.
4. `06_validacion_python.py`, actualizado: C2 ya no exige que la gemela tenga menor `id_fila`, y la prueba nueva C3 comprueba que el sobreviviente tiene un rango de estado mayor o igual al eliminado.
5. `02_modelo_gold.sql` con `-v recrear=1` (reconstruye solo oro).

### Resultado en plata (medido)

| Cifra | Antes de R5 nueva | Después |
|---|---:|---:|
| Filas | 13.005.402 | **13.005.402** |
| Atípicos (R9 + R9b) | 33.938 | **33.939** (33.929 + 10) |
| Fechas inválidas | 30 | **29** |
| Fechas incoherentes | 664 | **616** |
| Vacíos de `fecha_inicio` | 895.006 (6,88 %) | **772.332 (5,94 %)** |
| Vacíos de `fecha_fin` | 125 | **107** |
| Valor en cero / relleno / repetido | 80.137 / 94 / 148.035 | **idénticos** |
| Totales por año (2018 / 2023) | 102,54 / 125,33 | **idénticos** |

Estados de SECOP II (antes → ahora): `CERRADO` 1.174.268 → **1.674.727**, `TERMINADO` 644.692 → **776.995**, `EN EJECUCION` 1.902.281 → **1.570.664**, `MODIFICADO` 1.548.187 → **1.366.712**. Suben los estados avanzados y bajan los intermedios, como se esperaba. Los valores monetarios no cambian porque R5 decide qué fila sobrevive, no cuánto vale.

**Validación:** 18 de 18 validaciones en SQL y **43 de 43 pruebas en Python** (6,5 min), con C2 y C3 en 0 sobre 1.000 filas eliminadas.

### Resultado en oro (medido, verificación 9)

- Plata = oro = **13.005.402**; 0 huérfanos en las 7 claves foráneas; 0 PK duplicadas; 13 particiones, todas en `gold`.
- Cardinalidades, con el registro `-1`: `dim_entidad` 15.822, `dim_ubicacion` 1.177, `dim_proveedor` **2.181.587**, `dim_contrato` **1.015**, `dim_tiempo` 22.282.
- `tipo_persona` por fila: NATURAL **9.979.421**, JURIDICA **2.907.838**, NO CLASIFICADO **118.143**. Hay 83.363 documentos con tipos contradictorios (2.551.616 filas, 19,6 %).
- `valor_gastado` por agrupación de estado (billones): VIGENTE 408,14 · INICIO 383,05 · TERMINADO 257,65 · CERRADO 73,37 · SUSPENDIDO O CEDIDO 29,75 · PRECONTRACTUAL y CANCELADO 0.
- `valor_gastado` nunca supera el valor ajustado, y `secop_lectura` ve `gold` pero no `silver`.

### Capa de consumo (`sql/04_vistas.sql`)

8 vistas materializadas y 14 vistas normales, ejecutadas y leíbles por `secop_lectura` (24 objetos). 2018 suma **102,54 billones**. El top de proveedores lo abre el Consorcio Renting Blindados con 10,219 billones (0,887 % del total), y el HHI global es 79,45.

### Lecciones de esta sesión

1. **`ORDER BY ... DESC` pone los `NULL` primero en PostgreSQL.** El primer ranking de proveedores salió con proveedores de valor `NULL` (8 en `mv_proveedor_valor`) ocupando las 20 posiciones. Se corrigió con `NULLS LAST`. Cualquier `top N` sobre una medida que pueda ser `NULL` debe llevarlo.
2. **Las columnas de bronce en una materializada viven en el alias del CTE** (`bz`), no en el alias de la tabla de hechos.
3. **Atípicos 33.928, 33.929 y 33.939 son tres momentos distintos, no tres errores.** Tras `02` solo está aplicada R9 (33.929 con la R5 nueva); `02c` suma 10 de R9b y da 33.939.
4. **Cerrar la terminal no pierde el trabajo.** `psql -f` confirma cada sentencia, y con `Tee-Object` todo queda en `logs\`. Si un script ya terminó, se lee el log; no se vuelve a correr.
5. **El texto rojo `NativeCommandError` de PowerShell es inofensivo:** son los `NOTICE` de psql, que van por stderr.
6. **`psql` no lee `.env`.** La clave se escribe en el prompt oculto o con `PGPASSWORD` en la sesión; nunca en archivos versionados.
7. **`git pull --rebase` falla con cambios sin commitear:** commit primero, luego `pull --rebase` y `push`.
8. **`contratos_con_versiones` en `mv_kpis_globales` (553.406 `id_contrato` distintos) no coincide con los 554.063 de R7b** (pares contrato-proveedor): un mismo contrato puede aparecer con más de un proveedor.

---

## Pendiente

- Confirmar con el profesor que «gastado» = valor contratado vigente (no pagado), y comunicarle que «ANULADO» no existe (84 filas de cancelaciones).
- Orden de `SUSPENDIDO` y `CEDIDO` en el ranking de ciclo de vida: es juicio del equipo, no medición.
- `valor_gastado` = 0 o NULL en las filas que no cuentan: asumido 0.
- Desglosar la causa de los 83.363 documentos con tipos contradictorios (no medido).
- Unificar «16 frente a 22 columnas de origen»: `bronze.secop_raw` carga 22 columnas de datos.
- Tablero de Power BI y capturas PNG en `docs/imagenes/` (Entregable 5).
- Reescribir la introducción (sin preguntas) y acortar los objetivos específicos.
- Generar la documentación final en PDF.