# Bitácora de sesiones

Registro cronológico de lo que se hizo, con los problemas encontrados y cómo se resolvieron. El objetivo es que quien retome el proyecto no tenga que redescubrir los mismos errores.

Todas las cifras son medidas sobre la carga completa de **22.670.028 filas**.

---

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

- Escrito `sql/01_esquema.sql`: staging de 22 columnas `text`, silver de 26, `gold.fact_contrato` de 20 columnas con 30 particiones, 8 dimensiones y la vista `v_contratos`.
- Probada la función `es_fecha_valida` con 11 casos, incluidos los años imposibles.
- Cargadas 3 páginas (150.000 filas) de punta a punta.

### Errores encontrados

1. **` HAVING` sobre un alias que no resuelve.** `HAVING clave IS NOT NULL` en el `INSERT` de `dim_proveedor` daba `UndefinedColumn`. Se movió a `WHERE`, que además se evalúa antes de agrupar.

2. **Un `TRUNCATE` sin `RESTART IDENTITY` dejó la secuencia corrida.** Tras una carga de prueba de 150.000 filas, la carga completa empezó en `id_contrato` 150.001 en vez de 1, y terminó en 22.820.028. No se perdió ninguna fila (el total fue exacto) porque la PK es `(fecha_firma, id_contrato)` y no depende de la secuencia, pero el hueco queda. Se añadió `RESTART IDENTITY` al truncate del script y un aviso que detecta si la secuencia de `silver` no arranca en 1.

3. **Un reemplazo de PowerShell corrompió el código Python.** Sustituyendo texto con `Get-Content`/`Set-Content` se duplicó el prefijo raw de una cadena: quedó `rrSQL_... = """` usándose como `rSQL_...`, lo que dejó un `SyntaxError` de escape inválido. **Regla que queda:** editar con la herramienta de edición de archivos, nunca con round-trip de PowerShell. Antes ya había roto acentos y CJK en otro archivo.

---

## Sesión 4 — Descarga y carga completas

### Descarga

- `scripts/descargar_secop.py`: 454 páginas de 50.000 filas con 6 hilos, reintentos y espera creciente ante 429/503.
- Descarga completa: **19,40 GiB, 22.670.028 filas, diferencia +0** contra el `count(*)` de la API.
- El `count(*)` de la API tarda 196 s, y es el número con el que hay que validar: la ficha del portal está desfasada en 1,87M.

**Dos hallazgos del origen:**

- El CSV **tiene saltos de línea dentro de los campos**, así que contar líneas no sirve. La verificación usa `csv.reader`. El conteo por `contenido.count(b"\n")` que quedó en el script está inflado por eso y está pendiente de corregir.
- Se verificó que el orden de columnas del CSV coincide exactamente con el de la tabla, que es lo que permite emparejar por posición en el `COPY`.

### Carga

| Etapa | Tiempo | Filas |
|---|---:|---:|
| `COPY` a staging | 5,9 min | 22.670.028 |
| staging → silver | 91,8 min | 22.670.028 |
| silver → gold | 144,8 min | 22.670.028 |

Las tres capas cuadran exactamente, con **0 filas perdidas** en los 8 JOIN.

- Nulos de fecha que coinciden con la volumetría proyectada: firma 1.779.534 (7,85%), inicio 2.609.445 (11,51%), fin 1.582.907 (6,98%). La diferencia con lo proyectado son las fechas imposibles (1899, 2099, 8201), que también caen al centinela.
- 802.977 valores en cero, 597 centinelas de un billón, 670 duraciones negativas y 662 con fecha fin anterior al inicio. **Se conservan**: son hechos del dato, no errores de carga.

### El bug de las 28 particiones en `public`

Al medir tamaños apareció una contradicción: la suma por esquema daba 1.487 MB para `gold`, pero los índices por partición daban 20 GB.

La causa: el bucle del DDL que crea las particiones anuales usaba `format('... %I ...', 'fact_contrato_y' || v_anio)` **sin cualificar el esquema**, así que las 28 particiones anuales se crearon en `public` y no en `gold`. Solo `pre2000` y `resto` quedaron donde debían.

No era cosmético: los permisos son por esquema, y `public` tiene `USAGE` concedido a `PUBLIC`, o sea que la tabla de hechos quedaba al alcance de cualquier rol que conectara.

Corregido en el DDL con `%I.%I`, y en la base viva moviendo las 28 con `ALTER TABLE ... SET SCHEMA gold` (solo metadatos, conservó las filas). Verificado después: 30 particiones todas en `gold`, `public` con 0, y **0 tablas de `gold` sin `SELECT`** para `secop_lectura`.

**Dos consultas y engaños que conviene no repetir:**

- `pg_stat_user_indexes` **no devuelve nada** para una tabla particionada padre, porque el padre no almacena páginas. Hay que recorrer `pg_inherits` y agrupar por el índice del padre.
- En PostgreSQL 18 los contadores de checkpoint están en **`pg_stat_checkpointer`**, no en `pg_stat_bgwriter`.

### Rendimiento sin explicar

En gold, los lotes 2 a 5 tardaron ~17 min cada uno y del lote 6 en adelante ~50 s. Son ~68 minutos perdidos. La hipótesis es la presión de checkpoints (`max_wal_size` de 4 GB contra ~64 GB de WAL) más los 196 índices mantenidos durante la carga, pero **no está confirmada**. Queda pendiente medirlo con `pg_stat_checkpointer` antes/después.

### Acciones de limpieza

- Se eliminó el `.env` temporal que contenía la clave real de `secop_etl`. Los scripts leen `PG*` del entorno, así que siguen funcionando sin él.
- Se eliminó el índice `ix_fact_valor` (639 MB, 124 s), redundante con `ix_fact_anio_valor`. La base quedó en 60 GB y las tres capas intactas.
- Quedó una **desviación conocida y aceptada**: `id_contrato` va de 150.001 a 22.820.028 en vez de 1 a 22.670.028, por la carga de prueba de la sesión 3. No afecta la integridad y el script ya está corregido, así que una instalación limpia sale 1..N. Se decidió no renumerar 22,67M filas por estética.

---

## Pendiente

- Renumerar `id_contrato` (opcional, ~1-2 h, solo cosmética).
- Ejecutar `--grupos` para `id_grupo` y `es_contrato_repetido`. Se pospuso porque hace un `UPDATE` sobre 21 GB y podía consumir los 41,6 GB de disco libres. El propio script avisa que puede correr aparte.
- Corregir el conteo de filas por página en `descargar_secop.py`.
- El plan de optimización de carga descrito en `decisiones_tecnicas.md` sección 8 y 9.
