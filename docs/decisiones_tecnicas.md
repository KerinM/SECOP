# Decisiones técnicas

Registro de las decisiones de diseño que no son obvias, con el motivo y las alternativas descartadas. Está pensado para que alguien más pueda retomar el proyecto y entender **por qué** el modelo es como es, no solo **qué** es.

Las cifras son **medidas** sobre el corte vigente `secop_dw` (16.025.993 filas en bronce, 13.005.402 en plata y en oro). Cada cifra se marca como **medida**, **definida** (regla de negocio) o **pendiente**.

> **Este documento se reescribió tras las correcciones del profesor.** El modelo pasó de 7 a **5 dimensiones**, se derivó de los requerimientos de negocio (RQ01-RQ14) y se añadieron las reglas `tipo_persona`, `es_competitiva`, `agrupacion_estado` y `valor_gastado`. Las decisiones del modelo anterior que ya no aplican se marcan como **revertidas**, con su motivo, para que nadie las vuelva a proponer sin saberlo. Las **lecciones** que siguen valiendo se conservaron: el bug de las particiones en `public` (sección 10) y la zona horaria (sección 16).

---

## 1. Arquitectura de tres capas

| Capa | Contenido | Tabla |
|---|---|---|
| `bronze` | Copia literal del CSV, columnas `text` | `bronze.secop_raw` |
| `silver` | Tipos nativos, fechas validadas, normalizado, deduplicado | `silver.contratos` |
| `gold` | Modelo en estrella, 5 dimensiones, 13 particiones | `gold.*` |

**El nombre volvió a ser `bronze`.** El corte anterior usaba `staging` porque en la misma instancia existía otro proyecto con una capa `bronze` de otro dominio. El problema era la coexistencia, y se resolvió con una base separada (`secop_dw`), sin renunciar al nombre de la arquitectura Medallón.

**Las tres capas coexisten.** Es el precio de poder auditar una cifra de `gold` hasta el CSV de origen (sección 11). Ver sección 17 para el plan de reducción de espacio.

---

## 2. El modelo sale de los requerimientos

**Corrección del profesor:** «a partir de los requerimientos se debe crear el modelo estrella».

El orden de trabajo se invirtió. Primero se redactaron los **14 requerimientos de negocio** (RQ01-RQ14, `requerimientos.md` §1) y de cada uno se dedujo qué dimensión y qué medida necesita:

| RQ | Necesita | Resuelto en |
|---|---|---|
| RQ01, RQ03, RQ07 | quién contrata | `dim_entidad` |
| RQ05 | dónde | `dim_ubicacion` |
| RQ04, RQ10 | a quién | `dim_proveedor` (`tipo_persona`) |
| RQ03, RQ06, RQ08, RQ11, RQ13 | cómo es el contrato | `dim_contrato` |
| RQ02, RQ09 | cuándo | `dim_tiempo` |
| RQ14 | cuánto se gastó | medida `valor_gastado` |

**Consecuencia de método:** una columna entra al modelo solo si algún RQ la necesita. Por eso se quitó el tipo de documento (sección 3.2) y las columnas agregadas de las dimensiones (sección 13).

---

## 3. Cinco dimensiones

### 3.1 `dim_ubicacion` separada de `dim_entidad` — **revertida**

El modelo anterior la había eliminado y absorbido en `dim_entidad`. Se vuelve a separar por dos motivos:

- **RQ05** es un requerimiento geográfico en sí mismo («departamentos y municipios con mayor valor»). Con la dimensión aparte, ese análisis no depende de la entidad.
- Es la estructura que ya muestran las diapositivas del grupo.

Una fila es un par `(departamento, municipio)`; los `NULL` se guardan como `NO REGISTRA` para que el `UNIQUE` funcione. **Costo asumido:** un `JOIN` más en las consultas geográficas y una FK más en el hecho (`sk_ubicacion`). **Medido:** 1.176 pares nuevos, más el registro `-1`.

> Limitación conocida: la ubicación es la **de la entidad contratante**, no la del lugar de ejecución. La fuente no trae lugar de ejecución.

### 3.2 `tipo_documento` eliminado

**Corrección del profesor:** eliminar «tipo de documento» del modelo.

Se eliminó como dimensión (ya lo estaba) y como atributo. Ningún RQ pide analizar por tipo documental; el único uso real era separar personas naturales de jurídicas (RQ10), y eso se resume en **`tipo_persona`** dentro de `dim_proveedor` (regla en sección 8.1). La columna sigue existiendo en bronce y plata; no llega a oro.

### 3.3 `dim_contrato`: modalidad, tipo, estado y origen en una sola dimensión

El modelo anterior tenía cuatro dimensiones pequeñas (`dim_tipo_contrato`, `dim_modalidad`, `dim_estado`, `dim_origen`), cada una con una FK en el hecho. Se funden en **una**, `dim_contrato`, con una fila por combinación existente.

| | Cuatro dimensiones | `dim_contrato` |
|---|---|---|
| FK en el hecho | 4 | **1** |
| `JOIN` por consulta | hasta 4 | **1** |
| Filas | decenas cada una | **1.005 combinaciones** (medido) + el `-1` |

**Por qué cabe en una:** los cuatro atributos describen cómo es el contrato y se consultan juntos (RQ03, RQ06, RQ08, RQ11, RQ13). Con solo 1.005 combinaciones reales, la dimensión es mínima.

**Costo asumido:** si aparece un valor nuevo en cualquiera de los cuatro atributos, nace una combinación nueva. Es aceptable: el `INSERT ... ON CONFLICT` de la carga las agrega solas.

**`origen` no es llave degenerada:** es un atributo con dos valores (`SECOPI`, `SECOPII`) y se conserva separado dentro de `dim_contrato` (RQ11), porque cada plataforma usa un vocabulario de estados distinto.

### 3.4 Qué se quitó del modelo anterior

| Se quitó | Motivo |
|---|---|
| `contratos` y `valor_total` en las dimensiones | Se calculan en las vistas (sección 13) |
| `objeto_contrato` y `url_contrato` del hecho | Texto libre que ningún RQ usa; se recupera por `id_fila` desde plata |
| `es_persona_natural`, `es_terminado`, `es_minima_cuantia` | Reemplazados por `tipo_persona`, `agrupacion_estado` y `es_competitiva` |

---

## 4. Llaves degeneradas: qué son y cuáles quedan

**Corrección del profesor:** corregir las llaves degeneradas teniendo en cuenta contratos y modalidades.

**Qué es una llave degenerada.** Es un identificador que vive en la tabla de hechos y **no tiene tabla de dimensión propia**, porque no tiene atributos que describir. El ejemplo clásico es el número de factura en un modelo de ventas: identifica la transacción, sirve para agrupar sus líneas y para volver al documento, pero «la factura 4471» no tiene nada más que decir.

**Para qué sirve aquí:**

- `id_contrato` agrupa las versiones de un mismo contrato: `COUNT(DISTINCT id_contrato)` da contratos y `COUNT(*)` da versiones.
- `id_proceso` identifica el proceso de contratación de cada versión (en SECOP II, el código `CO1.PCCNTR…`).
- Permiten bajar al detalle sin atravesar una dimensión.

**Por qué no son dimensiones:** `id_contrato` tiene **12.147.523 valores distintos** (medido) en 13.005.402 filas. Una dimensión de ese tamaño sería casi tan grande como el hecho y no aportaría ningún atributo.

**Qué estaba mal antes.** El modelo anterior trataba como si fueran identificadores sueltos atributos que sí describen al contrato (modalidad, tipo, estado, origen). Esos tienen pocos valores y se usan para agrupar, así que son **dimensión** (`dim_contrato`), no llave degenerada.

**Resultado final:** las únicas llaves degeneradas son **`id_contrato` e `id_proceso`**.

> `id_fila` no es una llave degenerada en el sentido de Kimball: es la **clave técnica de trazabilidad** (sección 11) y forma parte de la clave primaria.

---

## 5. `dim_tiempo`: 2000-2060, clave entera y registro `-1`

**Esta sección reemplaza por completo a la anterior** («clave natural, sin `-1`, de 1900 a 2030»), que queda revertida.

### 5.1 Rango 2000-2060 (22.281 días + el `-1` = 22.282 filas)

Plata deja `fecha_firma` en `[2000-01-01, fecha de descarga]` y `fecha_inicio`/`fecha_fin` en `[2000-01-01, 2060-12-31]` (regla R4). Toda fecha válida de plata tiene fila en el calendario. Se abandona el rango 1900-2030, que solo existía para alojar el centinela `1900-01-01`.

`22.281 = 61 años × 365 + 16 bisiestos` (2000, 2004, …, 2060). **Medido:** `filas_ok`, `sin_fecha_ok` y `sin_huecos` dan `t`.

### 5.2 Clave entera `sk_tiempo` = AAAAMMDD

La clave es un entero con forma de fecha (`20180315`). Es legible y PostgreSQL acepta un entero como **clave de partición**.

> **Esto invalida la justificación anterior.** El modelo viejo defendía que `dim_tiempo` debía usar la fecha como clave natural, porque la clave de partición tenía que ser una columna de la propia tabla de hechos y una FK a un `id_tiempo` obligaba a duplicar la fecha. Con una clave entera **que es a la vez** la FK y la columna de partición (`sk_fecha_firma`), no hay duplicación y la objeción desaparece. `dim_tiempo` ahora es como las otras dimensiones: clave sustituta entera, clave natural (`fecha`) con `UNIQUE`.

### 5.3 Registro `-1` «SIN FECHA»

La ausencia de fecha se representa con `sk_tiempo = -1` (`fecha` NULL, `es_sin_fecha = true`), igual que el miembro desconocido de las demás dimensiones. Reemplaza al centinela `1900-01-01` y a su bandera `es_centinela`.

Con esto el modelo es uniforme: **todas** las dimensiones tienen un `-1` y **todas** las FK del hecho son `NOT NULL DEFAULT -1`.

### 5.4 Tres roles de la misma dimensión

`fact_contrato` referencia a `dim_tiempo` **tres veces**: `sk_fecha_firma`, `sk_fecha_inicio` y `sk_fecha_fin`. Es la técnica de *role-playing dimension*: una sola tabla física con tres papeles. `v_contratos` la une tres veces con alias distintos.

### 5.5 El `::timestamp` del `generate_series` no es cosmético

Si se pasa un `DATE` tal cual, PostgreSQL resuelve `generate_series` contra la sobrecarga de `TIMESTAMPTZ`; con zona `America/Bogota`, sumar `'1 day'` preserva la hora local y un cambio de horario puede desviar la serie y hacerla terminar antes de tiempo. Se detectó en el modelo anterior (terminaba un día antes y dejaba fuera el último). Se conserva el cast, y la verificación 9.12 comprueba que no haya huecos.

---

## 6. El miembro desconocido `-1`

Las 5 dimensiones llevan un registro `sk = -1` con `NO REGISTRA` (`SIN FECHA` en tiempo). Resuelve tres problemas:

1. Las FK del hecho son `NOT NULL`; sin el `-1` habría que descartar filas.
2. El `DEFAULT -1` hace que la carga no pueda morir a mitad de camino por una categoría ausente.
3. «¿Cuántos contratos no traen entidad?» es un `WHERE sk_entidad = -1`, no un `IS NULL` disperso.

**Por qué `-1` y no `0`:** el `0` se confunde con un valor real. **Por qué no `NULL`:** el `NULL` real se conserva en plata, que es la capa de auditoría.

**Medido (verificación 9.8):** el `-1` mide el vacío del origen, no un error del modelo. Ejemplos: 48.932 filas sin ubicación, 895.006 sin fecha de inicio y 3 sin fecha de firma, que coinciden con los vacíos de plata.

El `-1` **no se excluye** de los agregados generales, para que el total del tablero cuadre con las filas de plata; solo se excluye cuando la pregunta es sobre entidades o proveedores.

---

## 7. La normalización ocurre en plata, no en el índice

La normalización de texto no ocurre al cargar oro. Ocurrió antes, en plata, y es **determinista**:

| Regla | Qué hace |
|---|---|
| R1 | Mayúsculas, sin tildes, sin espacios dobles, sin barras `\|` sueltas en los bordes |
| R2 | Nulos disfrazados (`NO DEFINIDO`, `N/A`, `SIN DESCRIPCION`) → `NULL` |
| R3 | Homologación de nombres equivalentes, catálogo `silver.homologacion` (17 reglas) |
| R8 | NIT y documentos solo con dígitos; el NIT se valida con el dígito de verificación de la DIAN |

El modelo anterior se apoyaba en una collation no determinista (`COLLATE secop_ci`) para que `Compraventa` y `COMPRAVENTA` fueran la misma clave. Ese mecanismo se eliminó: los `UNIQUE` de oro son **planos**, sin collation, y su comportamiento se puede razonar.

**Regla general:** una dimensión con `UNIQUE` en la clave natural exige normalización determinista y previa. Si se deja para el `INSERT`, el modelo depende de una collation y la deduplicación se vuelve invisible.

---

## 8. Reglas de negocio derivadas

Las cuatro reglas siguientes **no son mediciones**: son definiciones del proyecto. Cada una vive en una función SQL o en un `UPDATE` del DDL, de modo que cambiarla es cambiar un solo sitio y volver a correr la carga de dimensiones.

### 8.1 `tipo_persona` (RQ10) — definida

`gold.clasificar_persona(tipo_doc, documento)` devuelve `NATURAL`, `JURIDICA` o `NO CLASIFICADO`.

| tipo_persona | Criterio |
|---|---|
| NATURAL | Cédula de ciudadanía, NIT de persona natural, cédula de extranjería, pasaporte, tarjeta de identidad, registro civil, NUIP, carné diplomático, permisos de protección temporal y de permanencia |
| JURIDICA | NIT de persona jurídica, sociedades extranjeras, número de fideicomiso, y `NIT` genérico con documento de 9 dígitos que empieza por 8 o 9 |
| NO CLASIFICADO | NIT de extranjería, otro, nulos y `NIT` genérico que no cumple la heurística |

**Heurística del `NIT` genérico:** de los 262.530 `NIT` genéricos, 248.143 (**94,5 %**, medido) tienen 9 dígitos y empiezan por 8 (103.207) o 9 (144.936). Se documenta como **heurística, no medición**.

**La clasificación es por documento, no por fila.** En `dim_proveedor` hay una fila por documento. Si un mismo documento aparece con tipos distintos, **JURIDICA gana sobre NATURAL, y NATURAL sobre NO CLASIFICADO**.

**Medido (verificación posterior a la carga):**

| | Valor |
|---|---:|
| Documentos con tipos contradictorios | **83.765** |
| Filas de esos documentos | **2.554.879** (19,6 % de 13.005.402) |

Efecto sobre el reparto **por fila** de `fact_contrato`:

| tipo_persona | Clasificando cada fila por separado | **Clasificando por documento (modelo)** |
|---|---:|---:|
| NATURAL | 10.372.323 | **9.979.286** |
| JURIDICA | 1.909.481 | **2.903.235** |
| NO CLASIFICADO | 723.598 | **122.881** |
| Total | 13.005.402 | 13.005.402 |

La primera columna se midió clasificando cada fila con su propio tipo de documento; la segunda es lo que queda en oro tras asignar un tipo único a cada documento. La diferencia entre ambas es el efecto de los 83.765 documentos contradictorios.

**Se acepta esta regla** porque un proveedor es una persona o una sociedad, no una persona distinta en cada versión del contrato, y porque resuelve la mayor parte de los tipos nulos (697.080 filas) con la información de otras filas del mismo documento. **Riesgo que hay que conocer:** como JURIDICA gana, un único `NIT` mal registrado en una fila puede convertir a un proveedor natural en jurídico, lo que infla JURIDICA. No hay medición de cuántos casos son así. Para RQ10 el efecto es aceptable, pero cualquier presentación debe decir que la proporción es **por documento y con prioridad JURIDICA**.

> **Pendiente (no medido):** la *causa* de cada contradicción (por ejemplo, `NIT` frente a `NIT DE PERSONA NATURAL`, o tipo nulo frente a tipo informado) no se ha desglosado; se puede medir agrupando los tipos de los 83.765 documentos.

### 8.2 `es_competitiva` (RQ03) — definida por decisión del grupo

| es_competitiva | Modalidades |
|---|---|
| **FALSE** (no competitiva) | `CONTRATACION DIRECTA`, `OTRAS FORMAS DE CONTRATACION DIRECTA`, `REGIMEN ESPECIAL` |
| **TRUE** | Todas las demás (licitación pública, selección abreviada, concurso de méritos, mínima cuantía, etc.) |
| NULL | Modalidad desconocida (`NO REGISTRA`) |

**El régimen especial cuenta como no competitivo.** Es una decisión del grupo: el régimen especial no exige un proceso competitivo abierto, aunque jurídicamente no sea «contratación directa».

**Consecuencia medida:** CONTRATACION DIRECTA (8.177.358) + REGIMEN ESPECIAL (3.487.229) + OTRAS FORMAS (2) = 11.664.589 filas, o **≈ 89,7 %** de 13.005.402. Con un porcentaje tan alto, un único indicador agregado esconde la diferencia entre ambas modalidades; **en Power BI el indicador debe mostrarse desglosado por modalidad** (RF-08).

### 8.3 Ciclo de vida del contrato: `agrupacion_estado` y `rango_estado` (RQ13) — definida, provisional

**Corrección del profesor:** analizar anulaciones (contratos activos, anulados, etc.).

**Hallazgo medido:** el estado **«ANULADO» no existe** en la fuente. Lo más parecido es `CANCELADO` (74) más `TERMINADO ANORMALMENTE…` (10) = **84 filas (0,0006 %)**. El requisito se reformuló como **«estado del contrato»** (RQ13) y se informará al profesor. Los estados precontractuales suman 4.262 filas.

`gold.rango_estado()` ordena los estados en una escala única, porque SECOP I y SECOP II usan vocabularios distintos:

| Rango | Agrupación |
|---:|---|
| 1 | PRECONTRACTUAL |
| 2 | INICIO |
| 3 | VIGENTE |
| 4 | SUSPENDIDO O CEDIDO |
| 5 | TERMINADO |
| 6 | CERRADO |
| 7 | CANCELADO |
| 0 | NO REGISTRA (estado desconocido o no mapeado) |

**Qué está respaldado por datos:** en bronce hay **1.169.445 grupos** idénticos en contrato, proceso, proveedor, valor y fecha de firma con estados distintos; los choques dominantes son avances del ciclo de vida (Cerrado frente a En ejecución, 292.076; Cerrado frente a Modificado, 181.635; En ejecución frente a Terminado, 135.197), no contradicciones, y ninguno incluye una anulación. De ahí que `CERRADO` > `EN EJECUCION` y `MODIFICADO`, y `TERMINADO` > ambos.

**Qué es juicio y no medición:** el orden de `SUSPENDIDO` y `CEDIDO` (rango 4). Está marcado como provisional.

**El patrón `TERMINADO ANORMALMENTE%`** cubre el nombre truncado del estado de SECOP I (`TERMINADO ANORMALMENTE DESPUES DE CONVOCA…`). La verificación 9.14 comprueba que ningún estado quede sin agrupar.

### 8.4 `valor_gastado` (RQ14) — definida, **pendiente de confirmar con el profesor**

**Corrección del profesor:** añadir la métrica «gastado».

La fuente **no trae valor pagado ni ejecutado**. Por eso `valor_gastado` es el **valor contratado vigente**:

```text
valor_gastado = valor_ajustado   si  NOT es_atipico
                                 y   agrupacion_estado NOT IN ('PRECONTRACTUAL', 'CANCELADO', 'NO REGISTRA')
              = 0                en cualquier otro caso
```

**Nunca debe llamarse «dinero pagado».** Los estados precontractuales quedan fuera porque aún no hay contrato; los cancelados, porque ya no hay obligación.

**Por qué 0 y no NULL:** con `0`, `SUM(valor_gastado)` funciona sin filtros y no hay que recordar excluir filas en cada medida de Power BI. **Costo:** un promedio de `valor_gastado` incluiría esos ceros; para promedios hay que filtrar `valor_gastado > 0`. Si el profesor prefiere NULL, se cambia en el bloque 6.2 del DDL.

**Invariante verificada (9.16):** `valor_gastado > valor_ajustado` da 0 filas. La verificación 9.9 comprueba además que `billones_gastado ≤ billones_limpio` en todos los años.

### 8.5 Otras métricas añadidas

**Corrección del profesor:** añadir métricas.

| Medida | Qué es | Notas |
|---|---|---|
| `valor_gastado` | Valor contratado vigente | Sección 8.4 |
| `contrato_unidad` | Constante 1 por fila | Permite contar versiones con `SUM`, útil en Power BI |
| `duracion_dias` | `fecha_fin − fecha_inicio` | Se calcula en la carga (no es columna generada); NULL si falta una fecha. Las duraciones negativas están marcadas con `es_fechas_incoherentes` |

Las demás cifras (valor promedio, % no competitivo, participación de SECOP II, % de valor atípico) **no se almacenan**: se derivan en las vistas de Power BI (`sql/04_vistas.sql`), que es donde se calcula lo agregado.

---

## 9. `UNIQUE` en las claves naturales: qué resuelve y qué exige

Las cuatro dimensiones categóricas tienen `UNIQUE` en su clave natural (`codigo_entidad`, `(departamento, municipio)`, `documento_proveedor`, `(modalidad, tipo, estado, origen)`). Es lo que hace la carga **idempotente**:

- **`INSERT ... ON CONFLICT DO NOTHING`** agrega las claves nuevas y no toca las existentes. Sin el `UNIQUE`, no habría contra qué chocar y una segunda ejecución duplicaría la dimensión.
- El **`UPDATE` posterior** refresca los atributos derivados. Si cambia una regla de negocio (sección 8), basta volver a correr ese `UPDATE`.

`dim_entidad` y `dim_proveedor` se cargan con `GROUP BY` y no con `SELECT DISTINCT`, porque una misma clave puede traer atributos distintos (el mismo código de entidad con dos nombres, el mismo documento con dos razones sociales). `max()` elige uno: es una decisión consciente, no un dato perdido, porque los atributos originales siguen en `silver.contratos` y se recuperan por `id_fila`.

**Medido en la carga:** 15.821 entidades y 2.181.586 proveedores nuevos (más el `-1` en cada una). El conteo real de `dim_proveedor` es **2.181.587**; los 2.188.690 que mostraba `pg_stat_user_tables` eran una estimación de `n_live_tup`, que no es exacta tras un `UPDATE` masivo.

---

## 10. Particionado: 13 particiones, y el bug de las 28 en `public`

### 10.1 Las 13 particiones

| Tipo | Rango de `sk_fecha_firma` | Cantidad |
|---|---|---:|
| Cuarentena `pre2017` | `MINVALUE` → 20170101 (incluye el `-1`) | 1 |
| Anuales 2017 … 2027 | 20170101 → 20280101 | **11** |
| Por defecto `resto` | el resto | 1 |

**Particionado por un entero.** La clave de partición es `sk_fecha_firma` (AAAAMMDD), no una fecha. Un entero con forma de fecha ordena igual que la fecha, y es a la vez la FK a `dim_tiempo`.

**La cuarentena ahora absorbe el `-1`.** Antes la partición `pre2000` recibía el centinela 1900; ahora `pre2017` recibe las filas sin fecha de firma (`-1`) y cualquier firma anterior a 2017. Se espera con muy pocas filas (3 sin fecha en plata).

**La PK es compuesta** `(sk_fecha_firma, id_fila)` porque PostgreSQL no admite una PK ni un `UNIQUE` que no incluyan la clave de partición. Como empieza por la fecha, también cubre los rangos de fecha.

**Alternativa evaluada y rechazada:** tabla sin particionar, para permitir `PK (id_fila)`. Con 15,3 GB de RAM y 13 millones de filas, el `VACUUM` completo y los índices no caben cómodamente.

**Añadir 2028** es un `CREATE TABLE ... PARTITION OF`, sin migrar filas (RNF-04).

### 10.2 El bug: 28 particiones creadas en `public`

**El error más importante del proyecto, documentado para que no se repita.** En el modelo anterior, el bucle del DDL usaba un `%I` sin cualificar el esquema:

```sql
-- MAL: el nombre sale sin esquema y search_path lo pone en public
EXECUTE format('CREATE TABLE IF NOT EXISTS %I PARTITION OF gold.fact_contrato ...',
               'fact_contrato_y' || v_anio);
```

Las 28 particiones anuales se crearon en `public`, con datos dentro. No era cosmético: los permisos son por esquema y `public` tiene `USAGE` concedido a `PUBLIC`, así que la tabla de hechos quedaba accesible a cualquier rol que conectara.

Se detectó porque la suma por esquema daba 1.487 MB para `gold` mientras los índices por partición daban 20 GB. La consulta que lo resolvió recorre `pg_inherits` con el esquema de cada hijo:

```sql
SELECT n.nspname, c.relname FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE i.inhparent = 'gold.fact_contrato'::regclass;
```

**Corrección:** el DDL usa `%I.%I` con el esquema como primer argumento. **Verificado en la carga del modelo actual (consulta 9.4): las 13 particiones están en `gold`.**

**Lección:** un `CREATE TABLE` dentro de `EXECUTE format()` con `%I` sin esquema es un `public` silencioso. En este proyecto `public` no debe tener objetos propios.

---

## 11. La trazabilidad hereda el `id_fila` y eso tiene precio

`gold.fact_contrato.id_fila` es **la misma clave** que `silver.contratos.id_fila` y `bronze.secop_raw.id_fila`. Oro no genera una identidad nueva. La ruta completa de una cifra es:

```sql
SELECT ... FROM gold.fact_contrato f
JOIN silver.contratos  s USING (id_fila)
JOIN bronze.secop_raw  b USING (id_fila);
```

Como `id_fila` es correlativo por archivo (2017 = filas 1 a 1.498.976), también identifica el CSV de origen.

**El precio:** el `id` queda ligado al orden de carga de bronce. Si bronce se recarga con otro orden, hay que reconstruir oro. Es un intercambio consciente: la trazabilidad vale más que la independencia del `id`.

**Consecuencia para las fechas rechazadas:** plata pone en `NULL` las fechas imposibles (R4) y borra el texto original, así que oro no puede guardar `fecha_firma_original`. Guardarla sería una copia de `fecha_firma` con otro nombre. El original se recupera por `id_fila` en bronce.

---

## 12. Decisiones sobre índices

`fact_contrato` tiene la clave primaria y **siete índices adicionales**:

| Índice | Tipo | Por qué se queda |
|---|---|---|
| `fact_contrato_pk` | B-tree `(sk_fecha_firma, id_fila)` | PK compuesta obligatoria por el particionado; cubre los rangos de fecha |
| `ix_fact_fecha_brin` | **BRIN** | Alternativa al B-tree de fecha, mucho más pequeña; adecuada porque la carga ordena por año |
| `ix_fact_anio_valor` | B-tree `(sk_fecha_firma, valor_ajustado)` | La consulta más frecuente: valor por año |
| `ix_fact_proveedor` | B-tree | RQ04, RQ10 |
| `ix_fact_entidad` | B-tree | RQ01, RQ03, RQ12 |
| `ix_fact_ubicacion` | B-tree | RQ05 |
| `ix_fact_contrato` | B-tree | Filtros por clasificación (RQ03, RQ06, RQ13) |
| `ix_fact_id_contrato` | B-tree | Agrupar versiones por contrato |

**Índices que se decidió NO crear:**

| Descartado | Motivo |
|---|---|
| Sobre `es_atipico` | 33.938 en `true` sobre 13 millones; un índice sobre el 99,7 % de falsos no lo usa nadie |
| Sobre `valor_ajustado` suelto | Redundante con `ix_fact_anio_valor`. En el modelo anterior ocupaba 639 MB sin que ninguna consulta lo usara |
| Sobre cada clave natural de dimensión | El `UNIQUE` ya es un índice |

**El BRIN merece la comparación explícita:** en el modelo anterior ocupó ~2 MiB frente a ~344 MiB del B-tree equivalente, y es la opción por defecto para columnas de fecha en este proyecto. La tabla de tamaños del modelo actual se mide con la consulta 9.2 y la 9.6 de `volumetria.md`.

---

## 13. Sin columnas agregadas en las dimensiones — **revertida la desnormalización anterior**

El modelo anterior guardaba `contratos` y `valor_total` en cada dimensión, a propósito, rompiendo 3FN para evitar un `SUM` sobre 13 millones de filas por cada tarjeta del tablero.

**Se eliminan.** Motivos:

- Eran derivables de los hechos y podían quedar **desactualizadas** sin que nadie lo notara, si se modificaba un hecho fuera de la carga.
- Obligaban a seis `UPDATE` masivos en cada carga.
- La necesidad de rendimiento se cubre mejor con **vistas materializadas** (`sql/04_vistas.sql`), que se refrescan con `CALL gold.refrescar_vistas()` y se pueden reconstruir sin tocar las dimensiones.

Con esto las dimensiones solo contienen **atributos descriptivos**; todo número agregado vive en la capa de consumo.

**Lo que sí se desnormaliza, y es deliberado:** dentro de `dim_contrato`, `es_competitiva`, `agrupacion_estado` y `rango_estado` se derivan de `modalidad` y `estado_proceso`. Es la práctica habitual de una dimensión en un esquema en estrella (se guardan los atributos ya calculados para agrupar sin funciones). Se recalculan con un `UPDATE` al final de la carga de dimensiones, así que no se desincronizan.

---

## 14. Carga idempotente por tramos

`fact_contrato` puede cargarse por rangos de `id_fila` con las variables de psql `lote_desde` y `lote_hasta`. Un `INSERT ... SELECT` de 13 millones de filas en una sola transacción mantiene WAL y bloqueos hasta el final; para cargar por tramos hay que ejecutar el script **una vez por tramo**, lo que repite los bloques anteriores (funciones, calendario, dimensiones).

Eso obliga a que todo lo anterior sea idempotente: por eso el DDL usa `CREATE TABLE IF NOT EXISTS`, `ON CONFLICT DO NOTHING` y `UPDATE`.

**Consecuencias que hay que conocer:**

- `TRUNCATE gold.fact_contrato` **no** reinicia las secuencias de las dimensiones (son `CREATE SEQUENCE`, no `IDENTITY`), y borra los registros `-1` de las dimensiones solo si se truncan estas.
- El camino previsto para reconstruir es `-v recrear=1`, que borra **solo gold** (incluye tablas del modelo anterior de 7 dimensiones), reinicia las secuencias y rehace todo en orden.
- Se usan `SEQUENCE` y no `GENERATED ... AS IDENTITY` para poder insertar el `-1` explícitamente.
- No hay transacción alrededor de la carga: `psql` corre cada sentencia en autocommit, porque sostener 13 millones de filas en una sola transacción no cabe en los recursos del clúster. Si el `INSERT` de hechos fallara a mitad de camino, se relanza con `recrear=1`.

**Error corregido durante la ejecución:** el `INSERT ... SELECT DISTINCT` de `dim_contrato` fallaba con un `NULL` sin tipo, que PostgreSQL resolvía como `text` y no podía asignar a `es_competitiva` (boolean). Se resolvió con `NULL::boolean`. **Lección:** en un `SELECT DISTINCT`, los literales `NULL` necesitan cast explícito.

---

## 15. Roles y superficie de lectura

`secop_lectura` ve `gold` y nada más. En `bronze` y `silver` no se concede nada, y como un esquema nuevo no da privilegios a `PUBLIC`, el rol **no ve siquiera la existencia** de las capas anteriores. **Verificado (9.17):** `ve_gold = t`, `ve_silver = f`.

El `ALTER DEFAULT PRIVILEGES` lleva `FOR ROLE secop_etl` explícito. Sin él se aplica a los objetos del rol que ejecuta el script y las tablas de `gold` se quedan sin permiso: **un fallo silencioso**, porque la base funciona y Power BI no ve nada.

El DDL añade además `GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA gold`, para que las vistas que usan las funciones de reglas funcionen con `secop_lectura`.

---

## 16. Zona horaria

La conversión de fechas es independiente de la zona horaria: un `date` nunca lleva zona, así que no hay desplazamiento posible, y `2011-09-16` da `2011-09-16` en cualquier servidor. `gold.sk_fecha()` es `IMMUTABLE` y extrae año, mes y día del `date`. El único punto sensible es el `generate_series` del calendario (sección 5.5): los dos riesgos son el mismo.

---

## 17. Reducción de espacio: el plan que queda pendiente

Las tres capas coexisten para poder auditar. Decisión: **no se implementa ahora**; se documenta el intercambio.

| Palanca | Ganancia | Costo |
|---|---|---|
| Truncar `bronze` tras construir `silver` | ~40 % de la base | No se puede reconstruir `gold` sin repetir la carga |
| Cargar con `COPY` directo desde la descarga, sin CSV en disco | Evita escribir los CSV | Exige que el orden de columnas coincida |
| Cargar sin capa intermedia con `UNLOGGED` | Máximo ahorro | Se pierde la capa donde vive la limpieza |

---

## 18. Decisiones abiertas

| # | Tema | Estado |
|---|---|---|
| 1 | **Corregir R5** para que conserve el estado de mayor rango y no el menor `id_fila`. Plata ya borró los duplicados, que solo existen en bronce; hay que decidir entre reconstruir plata (más limpio, 1,5-2 h) o un script puntual `02d` (más pesado de diseñar). **Hay que hablar con José antes: plata es suya.** Cuando se corrija, hay que **repetir la carga de oro**: el conteo no cambia (13.005.402) pero cambia qué fila se conserva y, con ello, `estado_proceso`, `valor_gastado` y la verificación 9.15 | Pendiente |
| 2 | Confirmar con el profesor que «gastado» = valor contratado vigente (no pagado) | Pendiente |
| 3 | Informar al profesor que «ANULADO» no existe (84 filas de cancelaciones) | Pendiente |
| 4 | Orden de `SUSPENDIDO` y `CEDIDO` en el ranking | Juicio del equipo |
| 5 | `valor_gastado` = 0 o NULL en las filas que no cuentan | Asumido 0 |
| 6 | Desglosar la causa de los 83.765 documentos con tipos contradictorios | No medido |
| 7 | 16 frente a 22 columnas de origen: varios documentos dicen 16, pero `bronze.secop_raw` tiene 22 columnas de datos | Verificar contra los CSV |

---

## 19. Resumen de desviaciones y cambios respecto al modelo anterior

| # | Antes | Ahora | Motivo |
|---|---|---|---|
| 1 | 7 dimensiones | **5** | El modelo se deriva de los RQ (sección 2) |
| 2 | `dim_ubicacion` absorbida en `dim_entidad` | **`dim_ubicacion` separada** | RQ05 es geográfico (3.1) |
| 3 | `dim_tipo_contrato`, `dim_modalidad`, `dim_estado`, `dim_origen` | **`dim_contrato`** | Una FK en vez de cuatro (3.3) |
| 4 | Atributos de tipo de documento | **`tipo_persona`** | Corrección del profesor (3.2, 8.1) |
| 5 | `dim_tiempo` 1900-2030, clave natural, centinela 1900 | **2000-2060, clave entera AAAAMMDD, registro -1** | El entero sirve de clave de partición (5) |
| 6 | 1 FK de tiempo | **3 roles** (firma, inicio, fin) | RQ06 necesita duración (5.4) |
| 7 | `contratos` y `valor_total` en dimensiones | **Eliminadas** | Se calculan en vistas (13) |
| 8 | Sin métrica de gasto | **`valor_gastado`** | RQ14 (8.4) |
| 9 | Régimen especial como competitivo | **No competitivo** | Decisión del grupo (8.2) |
| 10 | Sin estado del contrato | **`agrupacion_estado`** | RQ13 (8.3) |
| 11 | Partición `pre2000` por fecha | **`pre2017` por entero** | Nuevo rango y clave (10.1) |
| 12 | Grano por contrato (diapositiva 9: `id_contrato + documento_proveedor`) | **Grano por versión** | SECOP II publica cada modificación como fila |

---

## 20. Referencias

| Documento | Contenido |
|---|---|
| [`modelo_relacional.md`](modelo_relacional.md) | Entregable 2: modelo conceptual, lógico, normalización y DDL |
| [`requerimientos.md`](requerimientos.md) | RQ01-RQ14, RF y RNF |
| [`volumetria.md`](volumetria.md) | Volumetría del corte vigente |
| [`medicion_estados_y_documentos.md`](medicion_estados_y_documentos.md) | Medición de estados y tipos de documento |
| [`sql/02_modelo_gold.sql`](../sql/02_modelo_gold.sql) | DDL ejecutable, con el motivo de cada decisión en los comentarios |
| [`bitacora_sesiones.md`](bitacora_sesiones.md) | Errores encontrados y cómo se resolvieron |