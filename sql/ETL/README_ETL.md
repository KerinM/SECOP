# ETL capas Bronce y Plata · Data Warehouse SECOP Integrado

Scripts del proceso ETL de las capas **bronce** (dato crudo) y **plata** (dato limpio) de la
arquitectura Medallón, en PostgreSQL 18.

- **Fuente:** SECOP Integrado (datos.gov.co, dataset `rpmr-utcd`), contratos firmados entre 2017 y 2026, descargados el 29/09/2026 en 10 archivos CSV (uno por año).
- **Base de datos:** `secop_dw`.
- **Responsable de estas capas:** Jose (Ingeniero ETL).
- **Capa oro:** no se incluye aquí. La construye y la documenta Kerin con `03_gold_modelo.sql`.

---

## Orden de ejecución

| # | Archivo | Capa | Dónde se corre | Tiempo aprox. |
|---|---|---|---|---|
| 1 | `01_cargar_bronce.sql` | Bronce | **psql** (consola), en la carpeta de los CSV | 30–60 min |
| 2 | `01b_trazabilidad_bronce.sql` | Bronce | Query Tool, bloque por bloque | ≈ 1 h 15 min |
| 3 | `02_silver_limpieza.sql` | Plata | psql o PSQL Tool de pgAdmin | 1,5–2 h |
| 4 | `02c_correccion_valores.sql` | Plata | Query Tool, paso por paso | 20–60 min |
| 5 | `eda_perfilado.sql` | Exploración | Query Tool | 5–20 min |
| 6 | `05_qa_silver.sql` | Pruebas | Query Tool, prueba por prueba | ≈ 15 min |

`02b_correccion_barras.sql` **solo se corre en una base que ya tenga plata creada con la versión
anterior de la limpieza.** Si se corre `02_silver_limpieza.sql` desde cero, esa corrección ya va incluida.

`02c_correccion_valores.sql` **siempre se corre** después de `02_silver_limpieza.sql`: sin él, las sumas de dinero
salen infladas.

---

## Qué hace cada archivo

### `01_cargar_bronce.sql`: carga de los 10 CSV
- Crea los esquemas `bronze`, `silver` y `gold`, y la extensión `unaccent` (para quitar tildes).
- Crea `bronze.secop_raw` con las 22 columnas del CSV, **todas en texto**, para que ninguna fila se rechace por un dato mal escrito. La validación se hace en plata.
- Agrega columnas de trazabilidad: `id_fila` (número único de cada fila), `fecha_carga` y `archivo_origen`.
- Carga los 10 archivos (`secop_2017.csv` a `secop_2026.csv`) con `\copy`, uno por año.
- Crea la bitácora `bronze.log_cargas`.
- **Resultado:** 16.025.993 filas en bronce.
- Los 10 CSV van en **una sola tabla** porque son el mismo dataset partido por año, con las mismas 22 columnas.

### `01b_trazabilidad_bronce.sql`: de qué CSV salió cada fila
- Llena `archivo_origen` con el archivo real de cada fila. Cada CSV traía los contratos firmados en un año, así que el año de la fecha de firma identifica el archivo.
- Rehace la bitácora `log_cargas` con una fila por archivo.
- Solo cambia una columna de metadatos; los datos del CSV no se tocan.
- **Resultado:** 10 archivos con rangos de `id_fila` seguidos (2017 = filas 1 a 1.498.976 … 2026 = hasta la 16.025.993).

| Archivo | Filas |
|---|---|
| secop_2017.csv | 1.498.976 |
| secop_2018.csv | 1.546.663 |
| secop_2019.csv | 1.671.680 |
| secop_2020.csv | 1.444.812 |
| secop_2021.csv | 1.512.288 |
| secop_2022.csv | 1.497.582 |
| secop_2023.csv | 1.458.129 |
| secop_2024.csv | 1.980.325 |
| secop_2025.csv | 2.123.615 |
| secop_2026.csv | 1.291.923 |
| **Total** | **16.025.993** |

### `02_silver_limpieza.sql`: limpieza (capa plata)
- Crea las funciones de limpieza en el esquema `silver`.
- Crea `silver.homologacion`, el catálogo de nombres equivalentes (17 reglas).
- Crea `silver.contratos` aplicando las 9 reglas de calidad.
- **Resultado:** 13.005.402 filas en plata.

| Regla | Qué hace | ¿Quita filas? |
|---|---|---|
| R1 | Textos en mayúsculas, sin tildes, sin espacios dobles y sin barras `\|` sueltas en los bordes | No |
| R2 | Nulos disfrazados ("NO DEFINIDO", "N/A", "SIN DESCRIPCION"…) pasan a NULL | No |
| R3 | Homologación: unifica nombres escritos distinto (ej. "DISTRITO CAPITAL DE BOGOTA" → "BOGOTA D.C.") | No |
| R4 | Fechas imposibles (antes de 2000, después de 2060, o firma posterior a la descarga) pasan a NULL y se marcan | No |
| R5 | Elimina duplicados exactos (mismo origen, contrato, proceso, proveedor, valor y fecha de firma) | **Sí** |
| R6 | Valores en cero y valores de relleno (8 o más nueves) se marcan | No |
| R7 | Si un mismo contrato repite su valor en varias filas, el valor se reparte (`valor_ajustado`) | No |
| R8 | NIT y documentos solo con dígitos; el NIT se valida con el dígito de verificación de la DIAN | No |
| R9 | Valores atípicos (regla de Tukey por tipo de contrato) se marcan, no se borran | No |
| R7b | Versiones de un contrato SECOP II: se cuenta una vez, con el promedio de sus versiones (`02c`) | No |
| R9b | Valores imposibles para su entidad (> 1 billón y > 100.000 veces la mediana de la entidad) se marcan como atípicos (`02c`) | No |

### `02b_correccion_barras.sql`: corrección puntual
- Las pruebas de calidad encontraron **538 nombres de proveedor** con una barra `|` suelta al inicio o al final, que venía desde SECOP (ej. `ZARETH OROZCO ESPINOSA|`). La versión anterior de la regla R1 no la quitaba.
- Actualiza la función `limpiar_texto` y corrige **solo esas 538 filas**, sin rehacer toda la limpieza.
- **Resultado esperado:** `UPDATE 538`. Si se corre otra vez, `UPDATE 0`.

### `02c_correccion_valores.sql`: corrección de valores
- **Por qué existe:** al comparar los totales por año con las cifras oficiales de Colombia Compra Eficiente
  (≈ 100 billones de pesos al año), plata sumaba de más. En 2018 daba ≈ 692 billones.
- **Causa 1 (R7b):** en SECOP II un mismo contrato aparece varias veces, una fila por cada modificación
  (estado MODIFICADO), con el mismo proceso y la misma fecha de firma pero valores distintos. Son
  **554.063 contratos en 1.317.098 filas**, que sumaban ≈ 422 billones de más. El dataset no trae la fecha
  de cada modificación, así que el contrato se cuenta **una vez con el promedio de sus versiones**:
  cada fila queda con `valor_contrato / n` en `valor_ajustado` y se marca `flag_version_contrato`.
- **Causa 2 (R9b):** valores imposibles para la entidad que los registra, que R9 no detectaba porque compara
  solo contra el mismo tipo de contrato. Ej.: la Alcaldía de Valledupar con un contrato de $25 billones con
  un banco. Se marcan `flag_valor_extremo` y `flag_valor_atipico`; el valor original no se toca.
- Cada paso tiene un conteo previo; el UPDATE debe dar el mismo número. Si se corre otra vez, da `UPDATE 0`.

### `eda_perfilado.sql`: exploración de bronce
- Consultas que **no cambian nada**. Muestran los problemas que justificaron las reglas: variantes de escritura, porcentaje de vacíos, rangos de fechas y valores, y contratos repetidos.
- Requiere las funciones de `02_silver_limpieza.sql`.

### `05_qa_silver.sql`: pruebas de calidad de plata
- Consultas que **no cambian nada**. Verifican que plata cumple las reglas.

| Prueba | Qué revisa | Resultado obtenido |
|---|---|---|
| 1. Validaciones | 14 revisiones automáticas, una por regla | **14 de 14 en OK** |
| 2. Duplicados | Que no quede ningún contrato repetido | **0** |
| 3. Completitud | % de vacíos por columna | municipio 10,85 %, fecha_inicio 6,88 %, nit_entidad 4,00 %; el resto < 0,4 % |
| 4. Banderas | Filas marcadas por cada regla | ver tabla de hallazgos |
| 5. Categorías | Que los nombres quedaron unificados | nivel_entidad: de 7 variantes a 3 + vacío |
| 6. Antes y después | Ejemplos reales de bronce al lado de plata | ver capturas en `docs/` |
| 7. Corrección de valores | Versiones sin ajustar, sumas fuera de rango y extremos sin marcar | **4 de 4 en OK** |
| 8. Versiones = mismo contrato | Que las versiones de R7b tengan el mismo proceso, fecha de firma y entidad | 554.063 contratos: 0 con distinta entidad, 116 (0,02 %) con distinta fecha de firma, 4.720 (0,85 %) con distinto número de proceso |
| 9. Totales por año | Totales en billones frente a las cifras oficiales, y los 10 valores más altos de un año | 2018: 102,54 (oficial ≈ 100); 2023: 125,33 (oficial ≈ 111 a octubre) |

---

## Hallazgos de calidad

| Hallazgo | Filas | Qué se hizo |
|---|---|---|
| Duplicados exactos | 3.020.591 | Eliminados en plata (R5); siguen en bronce |
| Textos con ` \| ` interno | 171 | Se conservan: así vienen de SECOP |
| Barras sueltas en nombre de proveedor | 538 | Corregidas con `02b` (R1) |
| Valor repetido en varias filas | 148.035 | Valor repartido en `valor_ajustado` (R7) |
| Valor en cero | 80.137 | Marcados (R6) |
| Fecha de fin antes del inicio | 664 | Marcados (R4) |
| Fechas imposibles | 39 | Pasan a NULL y se marcan (R4) |
| Valores de relleno (99999999…) | 94 | Pasan a NULL y se marcan (R6) |
| Valores atípicos | 33.928 | Marcados, no borrados (R9) |
| Versiones de un mismo contrato (SECOP II) | 1.317.098 filas / 554.063 contratos | Se cuenta una vez con el promedio (R7b) |
| Valores imposibles para su entidad | 10 | Marcados como atípicos (R9b) |

Ejemplo de valor imposible: en 2025, el Instituto de Recreación y Deporte de Pasto registra un contrato con la
Fundación Pilto por **$944 billones**, más que todo el presupuesto nacional de un año. Por eso el total de 2025
con atípicos da 1.137 billones y sin atípicos 153. La fila ya estaba marcada por R9 y no entra en las sumas.

Ejemplo de la regla R7: el contrato `18-4-7947515` aparecía en 518 filas de plata (304.583 en bronce).
Sin ajustar, su valor sumaba $3.034.703.000.000; con el ajuste suma $5.858.500.000, que es su valor real.

### Supuestos y limitaciones
- Las pruebas garantizan que se cumplen las reglas definidas, pero **no corrigen errores de contenido de la fuente**, como nombres mal escritos o valores posibles pero incorrectos.
- La regla R6 asume que 8 o más nueves son un valor de relleno. Un contrato real de $99.999.999 quedaría marcado; son 94 filas y el valor original se conserva en bronce.
- La homologación (R3) solo cubre las 17 equivalencias del catálogo.
- R7b usa el **promedio** de las versiones porque el dataset no dice cuál es la última. El valor real
  vigente puede ser algo mayor o menor; cada versión original se conserva en `valor_contrato`.
- R9b puede marcar algunos convenios grandes reales (ej. una cofinanciación de TransMilenio con el
  Ministerio de Hacienda por ≈ $5 billones). Quedan marcados, no borrados, y se pueden revisar uno a uno.
- En 4.720 de los 554.063 contratos con versiones (0,85 %) el número de proceso cambia entre versiones, y en 116
  cambia la fecha de firma. Se tratan igual como un solo contrato, porque el código `CO1.PCCNTR...` lo asigna
  SECOP II y es único, y la entidad es la misma en todos los casos (0 con distinta entidad).
- R9 (Tukey por tipo de contrato) también marca algunos contratos grandes que parecen reales, como la logística
  electoral de la Registraduría para 2026 (≈ $2,2–3,3 billones). Al excluirlos, los totales sin atípicos pueden
  quedar un poco por debajo del valor real. Aun así coinciden con las cifras oficiales (2018: 102,5 frente a ≈ 100).
- **Para sumar dinero hay que usar `valor_ajustado` y excluir `flag_valor_atipico = true`.**
- 2026 llega hasta el 29/09/2026, la fecha de descarga.

---

## Los datos

Los CSV y la base de datos **no están en el repositorio**: pesan varios GB y GitHub no acepta archivos de más de 100 MB.

- **Respaldo de la base (bronce + plata):** [link de Drive]
- **Para restaurarlo:**
  1. Crear una base vacía `secop_dw`.
  2. Correr en ella `CREATE EXTENSION IF NOT EXISTS unaccent;`.
  3. Clic derecho en `secop_dw` → **Restore…** → elegir el archivo.
- **Después de restaurar:** correr `03_gold_modelo.sql` para construir la capa oro desde la plata corregida.
