# Decisiones técnicas

Registro de las decisiones de diseño que no son obvias, con el motivo y las alternativas descartadas. Está pensado para que alguien más pueda retomar el proyecto y entienda **por qué** el modelo es como es, no solo **qué** es.

Las cifras de cardinalidad y tamaño son las **medidas** sobre la carga completa de 22.670.028 filas, no proyecciones.

---

## 1. Arquitectura de tres capas

| Capa | Contenido | Tamaño real |
|---|---|---:|
| `staging` | Copia literal del CSV, 22 columnas `text` | 20 GB |
| `silver` | Tipos nativos, fechas validadas, normalización | 21 GB |
| `gold` | Modelo en estrella, 8 dimensiones, 30 particiones | 20 GB |

El nombre `staging` sustituye a `bronze`, que aparecía en los documentos originales. La razón: en el proyecto ya existe un `PlacspBigData` con una capa `bronze` de otro dominio, y usar el mismo nombre para cosas distintas genera confusión al leer consultas entre bases.

**Las tres capas coexisten y por eso la base ocupa 60 GB.** Es el precio de poder auditar una cifra de `gold` hasta el CSV de origen. Ver la sección 8 para el plan de reducirlo.

---

## 2. Ocho dimensiones, no nueve

`dim_ubicacion` (1.131 municipios) **se eliminó** durante la construcción. `dim_entidad` ya tiene `municipio_entidad` y `departamento_entidad` como columnas, así que una dimensión separada por municipio:

- duplicaba el dato sin aportar granularidad nueva,
- obligaba a un JOIN extra en cada consulta,
- y multiplicaba por dos el riesgo de desincronización entre dos fuentes de la misma verdad.

Con 15.928 entidades y una cardinalidad de municipio muy baja, el municipio es un **atributo** de la entidad, no una dimensión. Se documenta como desviación de la especificación original, que pedía 9.

---

## 3. `dim_tiempo` va de 1900 a 2030, no de 2000 a 2026

`dim_tiempo` tiene **47.847 días** cubriendo 1900-01-01 a 2030-12-31, sin huecos ni repetidos.

El motivo es la sección 4. `fecha_firma` es clave de partición y clave foránea contra `dim_tiempo`, y las filas sin fecha válida usan `1900-01-01` como centinela. Si el rango empezara en 2000, esas 1.779.534 filas no tendrían a qué apuntar y la clave foránea las rechazaría. La dimensión tiene que contener el centinela.

---

## 4. El centinela `1900-01-01`

El 7,85% de las filas (1.779.534) no tiene fecha de firma válida. Hay tres motivos distintos y **no se pueden distinguir entre sí** en el modelo:

1. la fecha viene nula en el origen,
2. la fecha es imposible (aparecen años 1899, 2099 y 8201),
3. la fecha existe pero no se pudo parsear.

La decisión es no perder esas filas. Se les asigna `fecha_firma = 1900-01-01` y se marca con `fecha_firma_es_centinela = true`, conservando además `fecha_firma_original` con el texto crudo cuando existía. Verificado sobre las 22,67M filas: **1.779.534 marcadas, 1.779.534 con fecha 1900-01-01, 0 incoherentes, 0 fechas reales sin su original**.

El centinela cumple además una función de almacenamiento: la partición `fact_contrato_pre2000` (1900-01-01 → 2000-01-01) es una **cuarentena** que concentra todas las filas sin fecha válida, y se verificó que contiene exactamente esas 1.779.534 filas y ni una sola con fecha real.

**Alternativa descartada:** dejar `fecha_firma` nula. Habría roto la clave de partición y la clave foránea, y PostgreSQL no admite NULL en ninguna de las dos.

---

## 5. La normalización de texto y quién colapsa los duplicados

Este es el punto que más confunde al leer el código, porque **la función `normaliza_texto` no es la que colapsa las variantes de mayúsculas**.

Lo que hace cada pieza:

- **`silver.normaliza_texto`** aplica `btrim` y colapsa espacios internos. Deja intacta la caja. Con collation determinista, 31 valores distintos de `tipo_de_contrato` siguen siendo 31.
- **La collation `secop_ci`** (`und-u-ks-level2`, no determinista) es la que hace que `Compraventa`, `compraventa` y `COMPRAVENTA` sean **la misma clave** en el índice `UNIQUE`.

La demostración medida sobre la carga completa: `tipo_de_contrato` tiene 31 valores crudos y produce **29 filas** en `dim_tipo_contrato`; `modalidad_de_contrataci_n` tiene 27 crudos y produce **25**. La diferencia de 2 en cada caso es colapso por caja, y ocurre en el `INSERT ... ON CONFLICT` gracias al índice con `COLLATE secop_ci`, no en la función.

`dim_proveedor` normaliza los documentos quitando puntos y guiones, y ahí sí es la función la que colapsa: de **2.772.691 valores crudos** a **2.509.036 normalizados**, es decir **263.655 duplicados** absorbidos.

---

## 6. Particionado: 30 particiones y `fillfactor` en cada una

La tabla de hechos se reparte en **30** particiones, no 29: cuarentena `pre2000` (1900-01-01 → 2000-01-01), **28 anuales** de 2000 a 2027, y `fact_contrato_resto` como partición por defecto.

La proyección original contaba 29 usando un año de seguridad intermedio. La cuenta final suma 30 porque la cuarentena va **antes** del rango de años en lugar de ocupar un año. Verificado: `pg_inherits` devuelve exactamente 30 hijos.

El `fillfactor = 90` se pone en **cada partición**, no en la tabla padre. Es deliberado: la proyección de espacio de `volumetria.md` asumía `fillfactor` 90, y ponerlo en el padre (que no almacena páginas) habría dado un número real más pequeño que la proyección y no se podría validar el cálculo.

---

## 7. Bug encontrado durante la carga: 28 particiones en `public`

**El error más importante que se encontró, y conviene documentar para que no se repita.**

El bucle del DDL que crea las particiones anuales usaba un `%I` con el nombre sin cualificar:

```sql
-- MAL: el nombre sale sin esquema y search_path lo pone en public
EXECUTE format('CREATE TABLE IF NOT EXISTS %I PARTITION OF gold.fact_contrato ...',
               'fact_contrato_y' || v_anio);
```

Resultado: solo `fact_contrato_pre2000` y `fact_contrato_resto` quedaron en `gold`. Las **28 particiones anuales se crearon en `public`**, con datos.

Por qué importa de verdad: los permisos en PostgreSQL son **por esquema**, y el esquema `public` tiene `USAGE` concedido a `PUBLIC` por defecto. Es decir, la tabla de hechos quedaba accesible a cualquier rol que conectara, que es justo lo que el diseño de `gold` como única superficie de lectura quería evitar.

Cómo se detectó: al medir tamaños, la suma por esquema daba 1.487 MB para `gold`, pero los índices por partición daban 20 GB. La contradicción no cuadraba y la consulta que la resolvió fue recorrer `pg_inherits` **con el esquema de cada hijo**:

```sql
SELECT n.nspname, c.relname FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE i.inhparent = 'gold.fact_contrato'::regclass;
```

**Corrección aplicada en dos sitios:** el DDL ahora usa `%I.%I` con el esquema como primer argumento, y las 28 particiones de la base viva se movieron con `ALTER TABLE ... SET SCHEMA gold`, que solo toca metadatos y conservó las filas. Después se reaplicó el `GRANT SELECT` sobre `gold` y se comprobó con `has_table_privilege` que quedan **0 tablas sin permiso** para `secop_lectura`.

**Lección:** un `CREATE TABLE` dentro de `EXECUTE format()` con `%I` sin esquema es un `public` silencioso. En este proyecto, `public` no debe tener objetos propios.

---

## 8. Reducción de espacio: el plan que queda pendiente

La base ocupa 60 GB y el disco tenía 129 GB. Con `staging` (20 GB) y `silver` (21 GB) truncados tras consumirlos, el pico baja a unos 30 GB, a cambio de no poder reconstruir `gold` sin repetir ~1,7 h de carga.

Decisión tomada: **no se implementa ahora.** Se deja documentado con el intercambio explícito para que quien lo implemente sepa qué gana y qué pierde.

Las otras dos palancas identificadas y no aplicadas:

- **Streaming de la descarga a `COPY`.** Hoy se escriben 454 CSV (19,4 GiB) y luego se copian. Como el orden de columnas del CSV coincide exactamente con el de la tabla, cada página puede entrar directa a `COPY ... FROM STDIN` sin escribir nada a disco. El tiempo de muro no mejora (la red manda: 52 min de descarga frente a 5,9 min de `COPY` local), pero **ahorra 19,4 GiB**. Además `cursor.rowcount` daría el conteo exacto de cada página, lo que arregla de paso el conteo por `count(b"\n")` que hoy está inflado por los saltos de línea internos del CSV.
- **Cargar sin staging ni silver en disco**, con `UNLOGGED`, ya que la fuente de verdad es el CSV.

---

## 9. Rendimiento: lo que se midió y lo que no se explica

Tiempos reales de la carga completa:

| Etapa | Tiempo |
|---|---:|
| `COPY` a staging (454 archivos) | 5,9 min |
| staging → silver | 91,8 min |
| silver → gold (dimensiones + 92 lotes) | 144,8 min |

En la etapa gold hay un episodio sin explicar: **los lotes 2 a 5 tardaron unos 17 minutos cada uno**, y del lote 6 en adelante cada lote tomaba unos 50 segundos. Son del orden de 68 minutos perdidos en una etapa donde mover filas no es el problema.

Hipótesis, **no confirmadas**:

- `max_wal_size` estaba en 4 GB frente a una carga que escribió del orden de 64 GB de WAL, lo que fuerza unos 16 checkpoints.
- Se mantEANían **196 índices** (7 por partición) durante los 92 lotes de inserción.

Lo que sí se hizo al respecto, y es una mejora real: `ix_fact_valor` (639 MB) se eliminó por redundante, dejando 6 índices. Y queda pendiente medir con `pg_stat_checkpointer` — en PostgreSQL 18 los contadores de checkpoint están en esa vista, no en `pg_stat_bgwriter`, que es un error fácil de cometer.

**Pendiente, sin implementar:** un perfil de carga que suba `max_wal_size` a 16 GB y ponga `full_page_writes = off` (en una carga desde cero cada página es nueva, así que la imagen completa de 8 KB que se manda al WAL es descartable), y diferir la construcción de los 4 B-tree de la tabla de hechos hasta después de la carga, creándolos en paralelo entre particiones.

---

## 10. Zona horaria

`silver.es_fecha_valida` convierte `YYYY-MM-DDT00:00:00.000` a `date` con el literal `TIMESTAMP '2000-01-01'`, que es **independiente de la zona horaria**: un `date` nunca lleva zona, así que no hay desplazamiento posible. Por eso `2011-09-16` da `2011-09-16` siempre, en cualquier servidor y con cualquier `TimeZone`.

La función además no lanza excepciones ante entradas inválidas (valida el formato con una expresión regular antes de convertir), lo que se verificó con 11 casos reales y de prueba.

---

## 11. Decisiones sobre índices

| Índice | Espacio | Por qué se queda |
|---|---:|---|
| `fact_contrato_pk` | 755 MB | PK `(fecha_firma, id_contrato)`. Cubre los rangos de partición, así que no hace falta un índice aparte por `fecha_firma` |
| `ix_fact_anio_valor` | 875 MB | Fecha y valor: la consulta más frecuente |
| `ix_fact_num_contrato` | 691 MB | Detección de contratos repetidos |
| `ix_fact_proveedor` | 373 MB | JOIN a `dim_proveedor` |
| `ix_fact_entidad` | 203 MB | JOIN a `dim_entidad` |
| `ix_fact_fecha_brin` | 2,1 MB | **BRIN**, no un B-tree. Adecuado porque `fecha_firma` crece de forma monótona |

`ix_fact_valor` (639 MB) se eliminó: `valor_contrato` suelto es redundante con `ix_fact_anio_valor`, que ya lo cubre con la fecha delante, y 802.977 filas en cero sobre 22,67M no lo hacen útil como punto de entrada.
