# Decisiones técnicas

Registro de las decisiones de diseño que no son obvias, con el motivo y las alternativas descartadas. Está pensado para que alguien más pueda retomar el proyecto y entender **por qué** el modelo es como es, no solo **qué** es.

Las cifras de cardinalidad y tamaño son **medidas** sobre el corte vigente `secop_dw` (16.025.993 filas en bronce, 13.005.402 en plata). Donde algo no está medido, el documento lo dice en vez de estimarlo.

> Este documento se reescribió al cambiar de corte de datos. Las decisiones del modelo anterior sobre `secop_integrado` ya no aplican y no se conservan aquí. Las **lecciones** que siguen valiendo se conservaron: sección 7 (el bug de las particiones en `public`) y sección 10 (zona horaria).

---

## 1. Arquitectura de tres capas

| Capa | Contenido | Tabla |
|---|---|---|
| `bronze` | Copia literal del CSV, 16 columnas `text` | `bronze.secop_raw` |
| `silver` | Tipos nativos, fechas validadas, normalizado, deduplicado | `silver.contratos` |
| `gold` | Modelo en estrella, 7 dimensiones, 13 particiones | `gold.*` |

**El nombre volvió a ser `bronze`, y antes se había decidido que no.** El corte anterior usaba `staging` en lugar de `bronze` porque ya existía un proyecto `PlacspBigData` con una capa `bronze` de otro dominio, y el mismo nombre para cosas distintas confunde al leer consultas entre bases.

El nombre se revierte porque el problema era la **coexistencia en la misma instancia**, y la solución fue otra: `secop_dw` es una base separada. El choque de nombres desapareció sin renunciar a `bronze`, que además es el nombre que usa la arquitectura Medallion que el proyecto sigue. Documentar el camino y la reversión es parte de la decisión: si alguien vuelve a pensar en `staging`, ya sabe por qué se descartó.

**Las tres capas coexisten.** Es el precio de poder auditar una cifra de `gold` hasta el CSV de origen. Ver sección 8.

---

## 2. Siete dimensiones, no nueve

La especificación original pedía nueve. El modelo tiene **siete** (+1 tabla de hechos). Dos eliminaciones, con motivos distintos:

### 2.1 `dim_ubicacion` → eliminada (atributo de `dim_entidad`)

`dim_entidad` ya tiene `departamento` y `municipio` como columnas. Con 1.131 municipios medidos en el corte anterior y 15.928 entidades, la ubicación es un **atributo** de la entidad contratante, no una dimensión de primer nivel.

Una dimensión aparte habría:

- duplicado el dato sin aportar granularidad nueva,
- obligado a un `JOIN` extra en cada consulta geográfica (RF-11),
- y multiplicado por dos el riesgo de desincronización entre dos copias de la misma verdad.

### 2.2 `dim_tipo_documento` → eliminada (atributo de `dim_proveedor`)

El tipo documental (`NIT`, `CC`, `CE`, `NIT de persona natural`…) describe **al proveedor**, no es una dimensión independiente. Como tabla aparte tendría entre 13 y 19 filas y una cardinalidad tan baja que ningún `JOIN` adicional aportaría nada.

En `dim_proveedor` queda como `tipo_documento`, y de ahí se deriva el atributo calculado `es_persona_natural`.

**Efecto secundario útil:** RF-12 pide perfilar contratistas por persona natural vs jurídica, y eso ahora es una columna booleana en la dimensión del proveedor, sin `JOIN` adicional.

---

## 3. `dim_tiempo`: clave natural, sin `-1`, de 1900 a 2030

Esta decisión tiene tres partes y conviene no separarlas.

### 3.1 El rango 1900-2030 (47.847 días)

`dim_tiempo` va de **1900-01-01 a 2030-12-31**, sin huecos ni repetidos.

El motivo es la sección 4: `fecha_firma` es clave de partición **y** clave foránea contra `dim_tiempo`, y las filas sin fecha válida usan `1900-01-01` como centinela. Si el rango empezara en 2000, esas filas no tendrían a qué apuntar y la clave foránea las rechazaría.

El rango termina en 2030 y no en 2026 para que un año de consultas más no exija un `CREATE TABLE` de partición.

**El `::timestamp` del `generate_series` no es cosmético.** Si se pasa un `DATE` tal cual, PostgreSQL resuelve `generate_series` contra la sobrecarga de `TIMESTAMPTZ`, y con zona `America/Bogota` sumar `'1 day'` preserva la hora local: al cruzar un cambio de horario la hora se desvía, la deriva se acumula y la serie termina **antes** de tiempo. Medido en el modelo anterior: terminaba el 2030-12-30 con 14.974 filas en vez de 14.975, dejando fuera el 2030-12-31, y como `fecha_firma` es clave foránea ese día habría hecho fallar la carga.

### 3.2 Clave natural en vez de llave sustituta

`dim_tiempo` es **la única** de las siete que **no usa llave sustituta**: su clave primaria es `fecha`. No tiene `id_tiempo`.

Es una desviación consciente de la especificación, y el motivo es una restricción de PostgreSQL: **la clave de partición tiene que ser una columna o expresión de la propia tabla, nunca una referencia a otra tabla.**

Si `dim_tiempo` tuviera `id_tiempo`, la FK sería `id_tiempo → dim_tiempo.id_tiempo`, y para que `fecha_firma` fuera a la vez clave de partición y clave foránea habría que **duplicar la fecha en la tabla de hechos**, guardarla dos veces, y perder la garantía de que ambas copias coinciden.

Ponerle `id` no costaría mucho por sí solo (47.847 filas y una secuencia más), pero el coste real es la duplicación de la columna de partición. Se descarta.

### 3.3 Sin registro `-1`

El `-1` de las otras seis dimensiones responde a *"no sé qué valor es"*. En el calendario, la ausencia de fecha **ya tiene un valor propio y explícito**: `1900-01-01`, con su bandera `es_centinela`.

Usar los dos sería peor que usar uno: dos símbolos para la misma idea, y el riesgo de que una consulta use el que no toca. Se usa solo `1900-01-01`.

---

## 4. El centinela `1900-01-01`

Las filas sin fecha de firma válida existen porque la regla R4 de plata rechaza las fechas imposibles (`< 2000`, `> 2060`, posteriores a la descarga) y las pone en `NULL` con `flag_fecha_invalida`.

La decisión es **no perder esas filas**. Se les asigna `fecha_firma = 1900-01-01` y se marcan con `fecha_firma_es_centinela = true`. No se pueden distinguir entre sí tres motivos distintos —nula en origen, imposible, o no parseable— y el modelo no finge hacerlo: el texto crudo de la fecha rechazada **no está en plata** (R4 lo borró), así que oro **no guarda `fecha_firma_original`**.

> **El modelo anterior sí guardaba `fecha_firma_original`, porque su plata conservaba el texto crudo.** En `secop_dw` esa columna ya no tiene de dónde copiarse: guardarla en oro sería una copia de `fecha_firma` con otro nombre, costaría 52 MB y no recuperaría nada. El original vive en `bronze.secop_raw`, al que se llega por `id_fila`. Esa es exactamente la razón por la que `id_fila` se hereda en vez de generarse (sección 9).

**El centinela cumple además una función de almacenamiento:** la partición `fact_contrato_pre2000` (1900-01-01 → 2000-01-01) es una **cuarentena** que concentra todas las filas sin fecha válida.

**Alternativa descartada:** dejar `fecha_firma` nula. Rompería la clave de partición y la clave foránea, y PostgreSQL no admite `NULL` en ninguna de las dos. Además perderíamos las filas.

**Por qué 1900 y no otra fecha:** 1900 está fuera del rango que acepta la validación de fechas de plata (`>= 2000-01-01`), así que es **imposible** confundirlo con una fecha real. Si `fecha_firma` vale `1900-01-01`, es porque no había fecha, siempre.

---

## 5. La normalización ocurre en plata, no en el índice

Este es el punto que más confunde al leer el código, porque **la normalización de texto no ocurre en la base de datos al cargar oro**. Ocurrió antes, en plata.

El modelo anterior relied de una collation no determinista (`und-u-ks-level2`, `COLLATE secop_ci`) en el índice `UNIQUE` para que `Compraventa`, `compraventa` y `COMPRAVENTA` fueran **la misma clave**. Medido: `tipo_de_contrato` tenía 31 valores crudos y producía 29 filas, y esa diferencia de 2 la absorbía el `ON CONFLICT` gracias a la collation, no la función de limpieza.

**Ese mecanismo se eliminó.** En `secop_dw` la normalización es determinista y ocurre en plata:

| Regla | Qué hace |
|---|---|
| R1 | Mayúsculas, sin tildes, sin espacios dobles, sin barras `\|` sueltas en los bordes |
| R2 | Nulos disfrazados (`NO DEFINIDO`, `N/A`, `SIN DESCRIPCION`) → `NULL` |
| R3 | Homologación de nombres equivalentes, catálogo `silver.homologacion` con **17 reglas** |
| R8 | NIT y documentos solo con dígitos; el NIT se valida con el dígito de verificación de la DIAN |

Resultado: `nivel_entidad` pasa de **7 variantes a 3** (+ vacío), y los 38 valores crudos de departamento quedan en 35 categorías (33 departamentos reales + `No Definido` + el inválido `Colombia`).

**Consecuencia en el modelo de oro:** como la normalización ya ocurrió, los `UNIQUE` de las claves naturales son **planos**, sin collation. Y eso es una mejora, no una simplificación: el `UNIQUE` deja de depender del comportamiento de una collation no determinista y pasa a ser una garantía que se puede razonar.

**Regla general que sale de esto:** una dimensión con `UNIQUE` en la clave natural exige que la normalización sea determinista y previa. Si se deja para el `INSERT`, el modelo depende de una collation y la deduplicación se vuelve invisible.

---

## 6. `UNIQUE` en las claves naturales: qué resuelve y qué exige

Las seis dimensiones categóricas tienen `UNIQUE` en su clave natural. Es lo que hace que la carga sea **idempotente**:

- **`INSERT ... ON CONFLICT DO NOTHING`** agrega las claves nuevas y no toca las que ya estaban. Sin el `UNIQUE`, un `ON CONFLICT DO NOTHING` **no tendría contra qué chocar** y la segunda ejecución duplicaría la dimensión entera.
- El **`UPDATE` posterior** refresca los atributos. Sin él, un nombre de proveedor que llegó en mayúsculas en la tanda 1 y con una barra suelta en la tanda 2 se quedaría con el valor viejo. (Ese caso es real: `02b_correccion_barras.sql` corrige 538 nombres.)

`dim_entidad` y `dim_proveedor` se cargan con `GROUP BY` y no con `SELECT DISTINCT`, porque pueden traer filas con **el mismo código y atributos distintos**: el mismo código de entidad con dos nombres, o el mismo documento con dos razones sociales. `max()` elige uno, que es una decisión consciente y no un dato perdido: los atributos originales siguen en `silver.contratos` y se recuperan por `id_fila`.

---

## 7. Particionado: 13 particiones, y el bug de las 28 en `public`

### 7.1 Las 13 particiones

| Tipo | Rango | Cantidad |
|---|---|---:|
| Anual | 2017 … 2027 | **11** |
| Cuarentena `pre2000` | 1900-01-01 → 2000-01-01 | 1 |
| Por defecto `resto` | el resto | 1 |

El rango 2017-2026 viene del corte vigente: 10 archivos CSV, uno por año.

**La PK es compuesta** `(fecha_firma, id_fila)` porque PostgreSQL no admite una PK ni un `UNIQUE` que no incluyan la clave de partición.

**Alternativa evaluada y rechazada:** tabla sin particionar, para permitir `PK (id_fila)`. Con 15,3 GB de RAM y una tabla de 13 millones de filas, el `VACUUM` completo y los índices no caben cómodamente. Se particiona y se acepta la PK compuesta.

**Efecto lateral útil:** como la PK empieza por `fecha_firma`, los rangos de fecha quedan cubiertos y no hace falta un B-tree extra sobre la fecha.

### 7.2 El bug: 28 particiones creadas en `public`

**El error más importante que se encontró en el proyecto, y conviene documentar para que no se repita.**

El bucle del DDL que crea las particiones anuales usaba un `%I` con el nombre sin cualificar:

```sql
-- MAL: el nombre sale sin esquema y search_path lo pone en public
EXECUTE format('CREATE TABLE IF NOT EXISTS %I PARTITION OF gold.fact_contrato ...',
               'fact_contrato_y' || v_anio);
```

Resultado: solo `fact_contrato_pre2000` y `fact_contrato_resto` quedaron en `gold`. Las **28 particiones anuales se crearon en `public`**, con datos dentro.

Por qué importa de verdad: los permisos en PostgreSQL son **por esquema**, y `public` tiene `USAGE` concedido a `PUBLIC` por defecto. La tabla de hechos quedaba accesible a cualquier rol que conectara, que es justo lo que el diseño de `gold` como única superficie de lectura quería evitar.

Cómo se detectó: al medir tamaños, la suma por esquema daba 1.487 MB para `gold` pero los índices por partición daban 20 GB. La contradicción no cuadraba y la consulta que la resolvió fue recorrer `pg_inherits` **con el esquema de cada hijo**:

```sql
SELECT n.nspname, c.relname FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE i.inhparent = 'gold.fact_contrato'::regclass;
```

**Corrección aplicada en dos sitios:** el DDL usa `%I.%I` con el esquema como primer argumento, y las particiones de la base viva se movieron con `ALTER TABLE ... SET SCHEMA gold`, que solo toca metadatos y conservó las filas. Después se reaplicó el `GRANT SELECT` y se comprobó con `has_table_privilege` que quedan **0 tablas sin permiso** para `secop_lectura`.

**La consulta de verificación quedó en el DDL** (bloque 9, consulta 9.4) precisamente para que un rebuild no vuelva a cometerlo en silencio.

**Lección:** un `CREATE TABLE` dentro de `EXECUTE format()` con `%I` sin esquema es un `public` silencioso. En este proyecto, `public` no debe tener objetos propios.

---

## 8. Reducción de espacio: el plan que queda pendiente

Las tres capas coexisten para poder auditar. El precio es que la base ocupa la suma de las tres.

Decisión tomada: **no se implementa ahora.** Se deja documentado con el intercambio explícito para que quien lo implemente sepa qué gana y qué pierde.

| Palanca | Ganancia | Coste |
|---|---|---|
| Truncar `bronze` tras construir `silver` | ~40% de la base | No se puede reconstruir `gold` sin repetir la carga |
| **Streaming de la descarga a `COPY`** | Evita escribir los CSV en disco | Requiere que el orden de columnas del CSV coincida con el de la tabla |
| Cargar sin capa intermedia, con `UNLOGGED` | Máxima ahorro | Se pierde la capa donde vive la limpieza |

El **streaming** es la palanca más interesante y no se ha aplicado. Como el orden de columnas del CSV coincide con el de la tabla, cada página puede entrar directa a `COPY ... FROM STDIN` sin escribir nada a disco. El tiempo de muro no mejora (la red manda), pero se ahorra el CSV completo. Además `cursor.rowcount` daría el conteo exacto de cada página, lo que arregla de paso cualquier conteo por número de líneas que esté inflado por saltos de línea internos del CSV.

---

## 9. La trazabilidad hereda el `id` y eso tiene precio

`gold.fact_contrato.id_fila` es **la misma clave** que `silver.contratos.id_fila` y que `bronze.secop_raw.id_fila`. Oro no genera una identidad nueva.

**La razón:** es lo que permite auditar una cifra de `gold` hasta el CSV de origen con un solo `JOIN`, sin tabla puente. Como `id_fila` se asigna de forma correlativa por archivo de descarga (2017 = filas 1 a 1.498.976), la ruta completa es:

```sql
SELECT ... FROM gold.fact_contrato f
JOIN silver.contratos s USING (id_fila)
JOIN bronze.secop_raw b USING (id_fila);
```

**El precio, que hay que conocer:** el `id` queda ligado al orden de carga de bronce. Si bronce se recarga con otro orden, hay que reconstruir oro. Es un intercambio consciente —la trazabilidad vale más que la independencia del `id`— y el DDL lo documenta en la cabecera de `fact_contrato`.

Es también lo que hace que la sección 4 sea inevitable: como el original de una fecha rechazada no está en plata, el único camino para recuperarlo es `gold.id_fila → bronze.id_fila`.

---

## 10. Zona horaria

La conversión de fechas usa el literal `TIMESTAMP '2000-01-01'`, que es **independiente de la zona horaria**: un `date` nunca lleva zona, así que no hay desplazamiento posible. Por eso `2011-09-16` da `2011-09-16` siempre, en cualquier servidor y con cualquier `TimeZone`.

La función además **no lanza excepciones** ante entradas inválidas: valida el formato con una expresión regular antes de convertir. Se verificó con casos reales y de prueba.

> **Consecuencia que se spécifieó al construir oro:** si la conversión hubiera depended de la zona, el `generate_series` del calendario habría derivado con los cambios de horario (sección 3.1). Los dos bugs son el mismo bug.

---

## 11. Decisiones sobre índices

| Índice | Tipo | Por qué se queda |
|---|---|---|
| `fact_contrato_pk` | B-tree `(fecha_firma, id_fila)` | PK compuesta obligatoria por el particionado. Cubre los rangos de fecha, así que no hace falta un índice aparte por `fecha_firma` |
| `ix_fact_anio_valor` | B-tree `(fecha_firma, valor_ajustado)` | Fecha y valor: la consulta más frecuente del proyecto |
| `ix_fact_num_contrato` | B-tree | Búsquedas y detección de contratos repetidos |
| `ix_fact_proveedor` | B-tree | FK más usada: análisis de contratistas (RF-07, RF-12) |
| `ix_fact_entidad` | B-tree | FK de entidad, segunda más usada |
| `ix_fact_fecha_brin` | **BRIN** | Alternativa al B-tree de fecha: **×1/160 del tamaño**, adecuado porque `fecha_firma` crece de forma monótona |

**Índices que se decidió NO crear, y por qué:**

| Índice descartado | Motivo |
|---|---|
| B-tree sobre `es_atipico` | 33.928 en `true` sobre 13 millones. Un índice sobre el 99,7% de falsos no lo usa nadie |
| B-tree sobre `valor_ajustado` suelto | Redundante con `ix_fact_anio_valor`, que ya lo cubre con la fecha delante. En el modelo anterior ocupaba 639 MB sin que ninguna consulta lo usara |
| B-tree sobre cada `codigo` natural de dimensión | El `UNIQUE` **ya es** un índice. Crear otro encima duplicaría el espacio sin ganancia |

**El BRIN merece la comparación explícita**, porque es counterintuitive: en el modelo anterior se midió 2,1 MiB proyectados y 2,1 MiB medidos, contra los ~344 MiB que ocupaba el B-tree equivalente. Es la misma respuesta a la misma pregunta con casi un cuarto de mil de diferencia, y es la razón de que BRIN sea la opción por defecto para columnas de fecha en este proyecto.

---

## 12. Desnormalización deliberada y su límite

Las seis dimensiones categóricas llevan dos columnas agregadas: `contratos` y `valor_total`, con `valor_total` calculado sobre `valor_ajustado` **excluyendo `es_atipico`**.

Esto **rompe 3NF a propósito**: `valor_total` es derivable de los hechos. El motivo es de consumo, no de corrección: la alternativa es un `SUM` sobre 13 millones de filas por cada tarjeta de un tablero, y RF-15 a RF-18 muestran una tarjeta por entidad, por proveedor y por modalidad.

**Cómo se evita que se desactualice:** se recalculan con seis `UPDATE` en cada ejecución de la carga, inmediatamente antes de insertar los hechos. Nunca "a mano", nunca entre ejecuciones. No van en la misma transacción que el `INSERT` de hechos: `psql` corre cada sentencia en autocommit, y envolver 13 millones de filas en una sola transacción no cabría en los 8 GB de `shared_buffers` de este clúster. El costo es acotado: si el `INSERT` fallara, los agregados de las dimensiones ya quedaron confirmados y se relanza la carga, que es idempotente para las dimensiones.

**El límite que impone esta decisión:** los hechos **no se corrigen en sitio**. Si se modificara un hecho sin pasar por la carga, las dos columnas quedarían desincronizadas y nadie lo detectaría. Es el precio de la desnormalización y por eso el DDL no expone esas columnas como editables.

---

## 13. Carga idempotente por tramos

`fact_contrato` no se carga en una sola sentencia sino por rangos de `id_fila`, controlados con las variables de psql `lote_desde` y `lote_hasta`.

**El razonamiento es una consecuencia directa de la sección 12 y la 6.** Un `INSERT ... SELECT` de 13 millones de filas en una sola transacción mantiene WAL y bloqueos hasta el final. Para cargar de verdad por lotes hay que ejecutar el script **una vez por tramo**, lo que significa que los bloques anteriores (DDL, calendario, seis dimensiones) se vuelven a correr 27 veces.

Eso obliga a que todo lo anterior sea idempotente. No es elegancia gratuit: es el requisito que hace viable el recorrido por tramos. Por eso el DDL usa `CREATE TABLE IF NOT EXISTS`, `ON CONFLICT DO NOTHING` y `UPDATE`, y no `CREATE TABLE` a secas.

**Consecuencia que hay que conocer:** `TRUNCATE gold.fact_contrato` no reinicia las secuencias de las dimensiones, porque son `CREATE SEQUENCE` y no columnas `GENERATED ... AS IDENTITY`. Si se trunca a mano hay que hacer `ALTER SEQUENCE gold.seq_* RESTART WITH 1`, y hay que volver a crear los seis registros `-1`. Por eso el camino previsto es `-v recrear=1`, que rehace todo en orden.

---

## 14. Roles y superficie de lectura

`secop_lectura` ve `gold` y nada más. En `bronze` y `silver` no se concede nada, y como un esquema recién creado no da privilegios a `PUBLIC`, el rol de lectura **no ve siquiera la existencia** de las capas anteriores.

El `ALTER DEFAULT PRIVILEGES` lleva `FOR ROLE secop_etl` explícito. Sin él se aplica a los objetos del rol que ejecuta el script, y las tablas de `gold` se quedan sin permiso: **un fallo que no da error en ninguna parte**. La base funciona y Power BI no ve nada.

---

## 15. Resumen de desviaciones respecto a la especificación

| # | Especificación | Modelo | Motivo |
|---|---|---|---|
| 1 | 9 dimensiones | **7** (+1 tabla de hechos) | `dim_ubicacion` y `dim_tipo_documento` eliminadas: sus atributos viven ya en `dim_entidad` y `dim_proveedor` (sección 2) |
| 2 | 7 dimensiones con llave sustituta | **6** con `id`; `dim_tiempo` con clave natural | La clave de partición debe ser columna de la propia tabla (sección 3.2) |
| 3 | Registro `-1` en las 7 | **6** registros `-1`; `dim_tiempo` usa el centinela `1900-01-01` | La ausencia de fecha ya tiene un valor explícito (sección 3.3) |
| 4 | Grano por contrato | Grano por **versión** de contrato | SECOP II publica cada modificación como fila; conservarlo es lo que pide RF-08 |
| 5 | Capa `staging` | Capa **`bronze`** | `secop_dw` es una base separada, así que el choque de nombres con otro proyecto desapareció (sección 1) |

---

## 16. Referencias

| Documento | Contenido |
|---|---|
| [`modelo_relacional.md`](modelo_relacional.md) | Entregable 2 · modelo conceptual, lógico, normalización y DDL |
| [`volumetria.md`](volumetria.md) | Volumetría medida del corte vigente y riesgo de capacidad |
| [`requerimientos.md`](requerimientos.md) | RF-01 a RF-20, RNF-01 a RNF-10 |
| [`sql/02_modelo_gold.sql`](../sql/02_modelo_gold.sql) | DDL ejecutable, con el motivo de cada decisión en los comentarios |
| [`bitacora_sesiones.md`](bitacora_sesiones.md) | Errores encontrados durante la carga y cómo se resolvieron |