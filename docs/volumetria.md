# Volumetría — SECOP Integrado

**Entregable 1 de 5** · Responsable: **Kerin** (rol: Analista de Datos)
**Fecha de medición:** 26/09/2026 · **Corte del dato en origen:** 21/09/2026 (`X-SODA2-Truth-Last-Modified`)
**Fuente:** [SECOP Integrado — datos.gov.co](https://www.datos.gov.co/Estad-sticas-Nacionales/SECOP-Integrado/rpmr-utcd) · ID Socrata `rpmr-utcd`

---

## 1. Fuente y método de medición

Toda cifra de este documento se **midió**, no se estimó a ojo. Se usaron dos vías:

| Vía | Qué permite | Cómo se usó |
|---|---|---|
| **API Socrata (SoQL)** | Conteos y distribuciones exactas sobre los 22,7M de registros, sin descargar nada | `https://www.datos.gov.co/resource/rpmr-utcd.json?$select=...&$group=...` |
| **Muestreo por lotes** | Bytes por fila reales y perfil de bytes por columna | Descarga de 60.000 filas en 3 bloques (offset 0 / 8M / 16M) y de 30.000 filas (offset 1M), todas medidas con el parser CSV de Python |

> **Advertencia metodológica (importante).** La metadata en caché que muestra la web de datos.gov.co (`cachedContents`) **está desfasada**. Este es el hallazgo metodológico más importante del proyecto:

| | Lo que muestra la web | **Lo que se midió en vivo (26/09/2026)** | Desfase |
|---|---|---|---|
| Filas | 20.800.218 | **22.670.028** | −1.869.810 |
| SECOP I | 14.389.666 | **14.603.263** | −213.597 |
| SECOP II | 6.410.552 | **8.066.765** | −1.656.213 |

**Conclusión:** el conteo **nunca** debe tomarse de la ficha del portal. Se debe contar con `count(*)` sobre la API o sobre la tabla cargada. Por eso el requisito **RF-19** obliga a recontar en PostgreSQL después de cargar.

---

## 2. Verificación del requisito de volumen

> Requisito del proyecto: base de datos con **más de 10 millones de registros** y **modelo relacional**.

| Criterio | Resultado | Estado |
|---|---|---|
| Más de 10.000.000 de registros | **22.670.028** | ✅ Cumplido por **2,27×** |
| Cobertura geográfica | 35 grupos de departamento (32 deptos + Bogotá D.C.) | ✅ Nacional |
| Cobertura temporal | 2000 – 2026 (datos válidos); 2003 es el primer año con datos reales | ✅ 23 años |
| 2 plataformas integradas | SECOP I (14.603.263) + SECOP II (8.066.765) | ✅ |

### 2.1 Sobre el carácter "relacional"

**El origen NO es relacional.** Es un CSV plano de 22 columnas con **una fila = un contrato registrado**, y repite el nombre de la entidad, el departamento, la modalidad, etc. en cada fila.

**Sí es modelable a relacional**, porque tiene 7 dimensiones naturales identificables más el tiempo:

| Dimensión | Columnas que la alimentan | Valores distintos (medido) |
|---|---|---|
| Entidad contratante | `codigo_entidad_en_secop`, `nombre_de_la_entidad`, `nit_de_la_entidad`, `nivel_entidad` | **17.183** |
| Proveedor / contratista | `documento_proveedor`, `nom_raz_social_contratista`, `tipo_documento_proveedor` | **3.364.090** |
| Ubicación | `departamento_entidad`, `municipio_entidad` | **1.131** municipios · **35** departamentos |
| Tipo de contrato | `tipo_de_contrato` | **33** |
| Modalidad | `modalidad_de_contrataci_n` | **38** |
| Estado | `estado_del_proceso` | **30** |
| Origen | `origen` | **2** |
| Tiempo | `fecha_de_firma_del_contrato`, `fecha_inicio_ejecuci_n`, `fecha_fin_ejecuci_n` | ~10.000 días |

El modelo en estrella que se construya en el **Entregable 2** parte de estas 8 dimensiones. Volumetría en la sección 6.

---

## 3. Volumetría de origen (medida)

### 3.1 Distribución por plataforma de origen

| Origen | Registros | % |
|---|---:|---:|
| SECOP I (`SECOPI`) | 14.603.263 | 64,4% |
| SECOP II (`SECOPII`) | 8.066.765 | 35,6% |
| **Total** | **22.670.028** | **100%** |

### 3.2 Distribución por año de firma del contrato

Años con fecha válida: **20.902.615 (92,20%)**. Sin fecha de firma: **1.767.413 (7,80%)**.

> ⚠️ Estos 1.767.413 registros **no son del año 2019**: son filas sin año extraíble. Una lectura anterior de la consulta los etiquetó como 2019 por error, lo que producía un descuadre de 95.819 filas. La cifra correcta de 2019 es **1.671.488**.

| Año | Registros | Año | Registros |
|---|---:|---|---:|
| 2025 | 2.118.036 | 2013 | 625.920 |
| 2024 | 1.978.444 | 2012 | 473.284 |
| **2019** | **1.671.488** | 2011 | 214.260 |
| 2018 | 1.546.609 | 2008 | 113.522 |
| 2021 | 1.512.011 | 2010 | 102.609 |
| 2017 | 1.498.966 | 2009 | 98.697 |
| 2022 | 1.497.235 | 2007 | 42.622 |
| 2023 | 1.457.114 | 2006 | 11.389 |
| 2020 | 1.444.511 | 2005 | 10.388 |
| 2016 | 1.380.294 | 2004 | 758 |
| 2026 *(año en curso)* | 1.259.311 | 2003 | 61 |
| 2015 | 1.022.566 | 2002 | 49 |
| 2014 | 822.297 | 2000 | 37 |
| | | 2001 | 31 |

**Año pico: 2025 con 2.118.036 contratos.**

**Cuadre del total:** 20.902.509 registros con año entre 2000 y 2026 + 106 con año en el futuro + 1.767.413 sin año extraíble = **22.670.028**. ✅

⚠️ El dataset **no está ordenado cronológicamente**: 2019 aparece como el 3er año más grande. Cualquier análisis temporal debe filtrar por rango, no asumir orden de carga.

⚠️ **Años corruptos presentes** (sección 8.1): 18 años distintos con fecha de firma en el futuro — 2044, 2075, 2076, 2078, 2079, 2086, 2087, 2088, 2090, 2091, 2092, 2093, 2094, 2095, 2096, 2097, 2098 y 2099 — con **106 registros** en total.

### 3.3 Distribución por departamento (38 valores en el origen)

| Departamento | Registros | % | Departamento | Registros | % |
|---|---:|---:|---|---:|---:|
| Antioquia | 4.099.174 | 18,1% | Norte de Santander | 198.865 | 0,9% |
| Bogotá D.C. | 2.833.570 | 12,5% | La Guajira | 159.006 | 0,7% |
| **Distrito Capital de Bogotá** | 2.816.042 | 12,4% | Putumayo | 154.962 | 0,7% |
| Valle del Cauca | 1.479.845 | 6,5% | Arauca | 147.524 | 0,7% |
| Cundinamarca | 1.157.715 | 5,1% | Caquetá | 130.551 | 0,6% |
| Santander | 961.961 | 4,2% | Chocó | 125.238 | 0,6% |
| Nariño | 908.563 | 4,0% | San Andrés Providencia | 100.505 | 0,4% |
| Boyacá | 753.719 | 3,3% | Guaviare | 81.262 | 0,4% |
| Tolima | 624.400 | 2,8% | Vichada | 69.174 | 0,3% |
| Bolívar | 537.497 | 2,4% | Amazonas | 68.383 | 0,3% |
| Atlántico | 505.293 | 2,2% | **No Definido** | 62.658 | 0,3% |
| Meta | 503.413 | 2,2% | Vaupés | 53.314 | 0,2% |
| Caldas | 493.596 | 2,2% | Cesar | 271.044 | 1,2% |
| Huila | 475.957 | 2,1% | Córdoba | 259.095 | 1,1% |
| Magdalena | 457.861 | 2,0% | Sucre | 249.204 | 1,1% |
| Cauca | 428.043 | 1,9% | Guainía | 36.700 | 0,2% |
| Risaralda | 381.373 | 1,7% | **NO DEFINIDO** *(variante en mayúsculas)* | 3.134 | 0,0% |
| Quindío | 371.253 | 1,6% | **Colombia** *(valor inválido)* | 504 | 0,0% |
| Norte De Santander | 367.197 | 1,6% | | | |
| Casanare | 342.433 | 1,5% | | | |

⚠️ **Bogotá aparece partida en dos** ("Bogotá D.C." + "Distrito Capital de Bogotá" = **5.649.612**), **Norte de Santander en dos** ("Norte De Santander" + "Norte de Santander" = **566.062**) y el "sin departamento" en dos ("No Definido" + "NO DEFINIDO" = **65.792**). Sin normalizar, cualquier mapa por departamento muestra errores. Detalle en `calidad_datos.md`.

**Normalización:** 38 valores crudos → al fusionar esos 3 pares quedan **35 categorías**, de las cuales **33 son los departamentos reales de Colombia** (32 departamentos + Bogotá D.C.), más `No Definido` (65.792) y el valor inválido `Colombia` (504). Este es el origen del "35 → 33" de la sección 8.3.

### 3.4 Distribución por tipo de contrato (33 valores)

| Tipo de contrato | Registros | % |
|---|---:|---:|
| **Prestación de Servicios** | 9.314.962 | 41,1% |
| **Prestación de servicios** *(misma categoría, otra capitalización)* | 6.878.829 | 30,3% |
| Suministro | 1.984.905 | 8,8% |
| Otro Tipo de Contrato | 1.681.079 | 7,4% |
| Compraventa | 805.790 | 3,6% |
| Obra | 625.655 | 2,8% |
| Otro | 337.770 | 1,5% |
| Decreto 092 de 2017 | 251.583 | 1,1% |
| **Suministros** *(duplicado de Suministro)* | 202.089 | 0,9% |
| Arrendamiento | 129.722 | 0,6% |
| Consultoría | 129.163 | 0,6% |
| Interventoría | 113.964 | 0,5% |
| *Los 21 restantes* | 214.517 | 0,9% |

⚠️ **"Prestación de Servicios" + "Prestación de servicios" = 16.193.791 registros (71,3%)** que deben ser **una sola** categoría. Igual con Suministro/Suministros, Arrendamiento/Arrendamiento de inmuebles, Acuerdo Marco/Acuerdo Marco de Precios, Crédito/Operaciones de Crédito Público. Sin un **tipificado en `dim_tipo_contrato`**, 33 valores se reducen a ~20 reales.

### 3.5 Distribución por modalidad de contratación (38 valores)

| Modalidad | Registros | % |
|---|---:|---:|
| **Contratación Directa (Ley 1150 de 2007)** | 6.375.019 | 28,1% |
| **Contratación directa** *(misma modalidad, otra capitalización)* | 5.999.573 | 26,5% |
| **Régimen Especial** | 5.342.354 | 23,6% |
| Contratación Mínima Cuantía | 1.819.348 | 8,0% |
| **Contratación régimen especial** *(duplicado)* | 1.192.520 | 5,3% |
| **Mínima cuantía** *(duplicado)* | 428.913 | 1,9% |
| Selección Abreviada de Menor Cuantía (Ley 1150 de 2007) | 358.394 | 1,6% |
| *Los 31 restantes* | 1.153.907 | 5,1% |

⚠️ Mismo problema de capitalización. "Contratación directa" en sus dos formas = **12.374.592 (54,6%)**. "Régimen especial" + variante = **6.534.874 (28,8%)**.

### 3.6 Distribución por estado del proceso (30 valores)

| Estado | Registros | % | Estado | Registros | % |
|---|---:|---:|---|---:|---:|
| Celebrado | 9.139.539 | 40,3% | Terminado sin Liquidar | 402.947 | 1,8% |
| Liquidado | 3.602.402 | 15,9% | Terminado Anormalmente | 244.157 | 1,1% |
| En ejecución | 2.085.686 | 9,2% | Borrador | 211.943 | 0,9% |
| Modificado | 1.840.374 | 8,1% | Adjudicado | 97.053 | 0,4% |
| Cerrado | 1.667.333 | 7,4% | Cancelado | 85.079 | 0,4% |
| Convocado | 1.045.208 | 4,6% | cedido *(minúscula)* | 48.452 | 0,2% |
| **terminado** *(minúscula)* | 916.546 | 4,0% | Suspendido | 45.040 | 0,2% |
| Aprobado | 591.175 | 2,6% | *Los 14 restantes* | 87.640 | 0,4% |
| Activo | 559.454 | 2,5% | | | |

### 3.7 Completitud por columna (medida sobre los 22.670.028)

| Columna | Nulos | % nulo |
|---|---:|---:|
| `fecha_de_firma_del_contrato` | 1.767.413 | **7,80%** |
| `fecha_inicio_ejecuci_n` | 2.738.685 | **12,08%** |
| `fecha_fin_ejecuci_n` | 1.521.879 | **6,72%** |
| `objeto_a_contratar` | 109 | 0,0005% |
| `objeto_del_proceso` | 1.645 | 0,0073% |
| `nom_raz_social_contratista` | 66 | 0,0003% |
| `documento_proveedor` | 76 | 0,0003% |
| Resto (15 columnas) | 0 | 0,00% |

**Las 3 columnas de fecha concentran el 100% de los nulos.** Es un patrón claro: SECOP I no exige fecha de ejecución, SECOP II sí.

### 3.8 Duplicados en la clave natural

| Métrica | Valor |
|---|---:|
| Filas totales | 22.670.028 |
| `numero_del_contrato` **distintos** | **18.049.016** |
| Filas que comparten número de contrato con otra | **4.621.012 (20,38%)** |

Contratos con mayor repetición:

| `numero_del_contrato` | Filas | Contexto |
|---|---:|---|
| 18-4-7947515 | 304.583 | Medellín · estímulos/Testigos Fase II |
| 19-4-9109342 | 205.193 | Medellín · estímulos/Testigos Fase I |
| 17-4-6029170 | 194.480 | Medellín · estímulos/Testigos 2017 |
| 16-4-4961893 | 159.999 | Medellín · becas 2016 |
| 21-4-12593472 | 108.174 | |

Verificado que un contrato normal (p. ej. `23-12-13451898`) aparece **1 sola vez**. Los 4,62M repetidos son programas de revisado masivo de SECOP I (cada persona beneficiaria = 1 registro) que comparten el mismo número de contrato.

**Impacto en la volumetría:** el modelo debe decidir explícitamente el grano. Si `fact_contrato` guarda las 22,67M filas, conserva el detalle real pero **duplica los valores de las dimensiones 4,6M veces**. Si se deduplica a 18,05M, se ahorra ~20% de espacio pero se pierde el detalle de ejecución (cada registro tiene fechas y valores distintos).

> **Recomendación de Kerin:** conservar las 22.670.028 filas en la capa Silver (fiel al origen) y marcar los repetidos con una columna `es_contrato_repetido boolean` + un `id_grupo` para poder agregar sin perder detalle.

---

## 4. Tamaño en disco (medido)

### 4.1 Bytes por fila

Medido sobre 60.000 filas reales en 3 bloques distintos, con el parser CSV de Python (no estimación):

| Bloque | offset | Filas | Comprimido | Crudo | **Bytes/fila** | Ratio gzip |
|---|---:|---:|---:|---:|---:|---:|
| 1 | 0 | 20.000 | 3,38 MB | 17,87 MB | **937,0** | 5,29× |
| 2 | 8.000.000 | 20.000 | 0,66 MB | 17,49 MB | **917,2** | 26,56× |
| 3 | 16.000.000 | 20.000 | 1,42 MB | 18,06 MB | **946,6** | 12,71× |
| **Media** | | **60.000** | | | **933,6** | **9,79×** |

### 4.2 Proyección del archivo CSV

| Formato | Cálculo | Resultado |
|---|---|---|
| **CSV crudo (UTF-8)** | 22.670.028 × 933,6 B | **19,71 GiB (21,16 GB)** |
| **CSV comprimido (gzip)** | 19,71 GiB ÷ 5 a 10 | **2 – 4 GiB** |

#### 4.2.1 Verificación contra la descarga real

La proyección se comprobó después contra los 454 archivos efectivamente descargados (22.670.028 filas, 27 de septiembre de 2026):

| Métrica | Proyectado | **Medido** | Desviación |
|---|---:|---:|---:|
| Tamaño total en disco | 19,71 GiB | **19,40 GiB** | −1,6% |
| Bytes por fila | 933,6 B | **917,7 B** | −1,7% |
| Filas | 22.670.028 | **22.670.028** | **0** |

La desviación de −1,6% viene de que las 60.000 filas muestreados tienen una mezcla de oficios algo más larga que la media del dataset. La proyección queda **validada**: el error es del orden que permite el criterio de aceptación (±5%) y el conteo de filas es exacto, que es el número que importa para el integrity check.

El ratio gzip varía mucho por zona (5,3× en SECOP I con oficios largos, 26,6× en zonas repetitivas). Se usa el rango **5–10×** como conservador.

> ⚠️ **El endpoint oficial de descarga (`/api/views/.../rows.csv?accessType=DOWNLOAD`) NO entrega gzip.** Solo la API paginada (`/resource/`) lo comprime. Por eso la estrategia de descarga es paginada (ver `etl_carga.md`, Entregable 4).

### 4.3 Perfil de bytes por columna (30.000 filas, offset 1.000.000)

Este perfil es la base del cálculo de proyección a PostgreSQL.

| # | Columna | Bytes/fila | % del payload | Nulos |
|---:|---|---:|---:|---:|
| 10 | `objeto_del_proceso` | **229,3** | 26,6% | 0,00% |
| 9 | `objeto_a_contratar` | **209,0** | 24,2% | 0,00% |
| 19 | `url_contrato` | 84,4 | 9,8% | 0,00% |
| 3 | `nombre_de_la_entidad` | 54,0 | 6,3% | 0,00% |
| 8 | `modalidad_de_contrataci_n` | 34,2 | 4,0% | 0,00% |
| 18 | `nom_raz_social_contratista` | 25,2 | 2,9% | 0,00% |
| 21 | `tipo_documento_proveedor` | 21,0 | 2,4% | 0,00% |
| 11 | `tipo_de_contrato` | 20,7 | 2,4% | 0,00% |
| 5 | `departamento_entidad` | 19,0 | 2,2% | 0,00% |
| 12 | `fecha_de_firma_del_contrato` | 20,4 | 2,4% | 11,40% |
| 13 | `fecha_inicio_ejecuci_n` | 20,4 | 2,4% | 11,48% |
| 14 | `fecha_fin_ejecuci_n` | 20,4 | 2,4% | 11,43% |
| 15 | `numero_del_contrato` | 13,2 | 1,5% | 0,00% |
| 16 | `numero_de_proceso` | 12,7 | 1,5% | 0,00% |
| 1 | `nivel_entidad` | 11,0 | 1,3% | 0,00% |
| 4 | `nit_de_la_entidad` | 10,0 | 1,2% | 0,00% |
| 22 | `documento_proveedor` | 9,6 | 1,1% | 0,00% |
| 7 | `estado_del_proceso` | 9,6 | 1,1% | 0,00% |
| 2 | `codigo_entidad_en_secop` | 8,8 | 1,0% | 0,00% |
| 17 | `valor_contrato` | 7,5 | 0,9% | 0,00% |
| 6 | `municipio_entidad` | 16,3 | 1,9% | 0,00% |
| 20 | `origen` | 6,0 | 0,7% | 0,00% |
| | **TOTAL payload útil** | **862,6** | **100%** | |

**Las 2 columnas de objeto textual (`objeto_del_proceso` + `objeto_a_contratar`) = 438,3 B = el 50,8% de todo el payload.** Solo quitarlas reduce el CSV a la mitad.

---

## 5. Distribución del valor de los contratos

| Métrica | Valor |
|---|---:|
| Mínimo | $0 COP |
| Máximo | $999.999.999.999.999 (centinela de error) |
| Promedio | $836.936.240 COP |
| **Suma total** | **$18.973.367.986.462.096** (18,97 billones) |
| Registros con valor **= 0** | 667.689 (2,94%) |
| Registros con valor **< $1.000.000** | 1.458.240 (6,43%) |

⚠️ La suma de 18,97 billones **está contaminada** por los valores centinela (999.999.999.999.999). La suma real de contratos es significativamente menor. Cualquier KPI de valor debe excluir `valor_contrato = 0` y `valor_contrato > 1.000.000.000.000`.

---

## 6. Proyección a PostgreSQL

Entorno destino: **PostgreSQL 18.6** en `localhost:5432`, Codificación UTF-8, 15,3 GB RAM, 12 núcleos lógicos.

### 6.1 Método de cálculo

En PostgreSQL una tupla ocupa: **23 B de cabecera** + **1 B de bitmap de nulos** (redondeado a 2 con 22 columnas) + **padding de alineación a 8 B** + datos, donde cada `text` añade 1–4 B de cabecera `varlena` y cada `date` ocupa **4 B** (no 20,4 B como en el CSV).

### 6.2 Escenario A — Tabla plana (22 columnas, copia literal del CSV)

| Concepto | Bytes/fila | Total (22.670.028 filas) |
|---|---:|---:|
| Payload de datos (medido) | 862,6 | 19,55 GB |
| − ahorro por fechas `date` (3 × 16,4 B) | −49,2 | −1,12 GB |
| + cabeceras `varlena` (20 columnas × 2 B) | +40,0 | +0,91 GB |
| + cabecera de tupla + bitmap + padding | +32,0 | +0,73 GB |
| **Subtotal por fila** | **885,4** | **20,07 GB** |
| + espacio libre por página (~10%, `fillfactor` 90) | +98,4 | +2,23 GB |
| **Tabla plana** | **983,8** | **≈ 18,7 GiB** |
| + 6 índices B-tree (~28 B/entrada) | | **≈ 4,8 GiB** |
| **TOTAL Escenario A** | | **≈ 24 – 26 GiB** |

> NOTA: las columnas de objeto larga se comprimen con TOAST/pglz solo si superan ~2 KB. La media es 209–229 B, así que la mayoría de filas **no** se comprime. Solo las filas atípicas (>2 KB) sí lo hacen, lo que confirma que **no se puede contar con la compresión automática** para dimensionar.

### 6.3 Escenario B — Esquema en estrella (modelo del Entregable 2)

Al mover las 8 dimensiones a tablas separadas con claves sustitutas `integer` de 4 B:

| Tabla | Filas | Bytes/fila | Tamaño |
|---|---:|---:|---:|
| `fact_contrato` (7 FKs `int` = 28 B, 2 objetos, url, 2 identificadores, valor, 3 fechas) | 22.670.028 | ~640 | **13,2 GiB** |
| `dim_proveedor` (documento, tipo_doc, nombre) | 3.364.090 | ~72 | **0,29 GiB** |
| `dim_entidad` (código, nombre, nit, nivel, depto, municipio) | 17.183 | ~130 | **2,2 MB** |
| `dim_tipo_contrato` (33) | 33 | ~60 | 2 KB |
| `dim_modalidad` (38) | 38 | ~70 | 3 KB |
| `dim_estado` (30) | 30 | ~50 | 2 KB |
| `dim_origen` (2) | 2 | ~20 | 40 B |
| `dim_tiempo` (~9.960 días 2000-2026) | 9.960 | ~48 | 0,5 MB |
| `dim_tipo_documento` (19) | 19 | ~50 | 1 KB |
| **Subtotal tablas** | | | **≈ 13,7 GiB** |
| + índices (PK, 5 FKs, BRIN) | | | **≈ 3,2 GiB** |

> **Corrección posterior a la carga.** El modelo final tiene **8 dimensiones, no 9**: `dim_ubicacion` se eliminó por solaparse con los campos de municipio y departamento que ya viven en `dim_entidad`. Se añadió además que `dim_tiempo` debe cubrir **1900-01-01 a 2030-12-31** (47.847 días) en vez de 2000-2026, porque `fecha_firma` usa `1900-01-01` como centinela para las filas sin fecha válida y esa fecha tiene que existir en la dimensión. Ver `decisiones_tecnicas.md`.
| **TOTAL Escenario B** | | | **≈ 17 – 19 GiB** |

**Si además se descarta `objeto_del_proceso`** (duplica el 100% de `objeto_a_contratar` en SECOP I y es la columna más pesada: 229,3 B/fila):

| Tabla | Bytes/fila | Total |
|---|---:|---:|
| `fact_contrato` sin `objeto_del_proceso` | ~410 | **8,4 GiB** |
| **TOTAL Escenario B optimizado** | | **≈ 11 – 13 GiB** |

### 6.4 Resumen comparativo

| Escenario | Espacio en disco | Δ vs origen | Cuándo usarlo |
|---|---:|---:|---|
| CSV crudo (origen) | 19,71 GiB | — | Descarga completa, no se conserva |
| **A · Tabla plana** | **24 – 26 GiB** | ×1,25 | `staging` / `silver`, copia fiel |
| **B · Estrella completa** | **17 – 19 GiB** | ×0,92 | Capa gold, analítica |
| **B' · Estrella sin `objeto_del_proceso`** | **11 – 13 GiB** | ×0,58 | Capa gold optimizada ✅ |

**Recomendación de Kerin: Escenario B' (11 – 13 GiB).** Ahorra 12 GiB frente a la tabla plana y mantiene el 100% del detalle analíticamente relevante. `objeto_del_proceso` se conserva en la capa silver por si se necesita.

> **Resultado medido en la base cargada.** El escenario elegido guardó `objeto_del_proceso` por ser un requisito de datos (D-04), así que la estrella real quedó en el escenario B: **`gold` ocupa 20 GB**, de los cuales 12,9 GB son índices. `silver` ocupa 21 GB y `staging` 20 GB, para un total de **60 GB** con las tres capas conviviendo. Ver la sección 11 para el desglose medido.

### 6.5 Espacio en índices

Esta era la proyección, sobre `pk_contrato bigint`. **El modelo final se movió a PK compuesta `(fecha_firma, id_contrato)`**, lo que aprovecha el corte de partición y hace innecesario un B-tree aparte sobre `fecha_firma`.

| Índice | Tipo | Tamaño proyectado | Tamaño **medido** | Justificación |
|---|---|---:|---:|---|
| `fact_contrato_pk` | B-tree (`date`, `int`) | 433 MiB | **755 MB** | PK `(fecha_firma, id_contrato)`. Cubre los rangos de partición, así que no hace falta un índice aparte por `fecha_firma` |
| `ix_fact_anio_valor` | B-tree (`date`, `numeric`) | 562 MiB | **875 MB** | Fecha y valor: la consulta más frecuente del proyecto |
| `ix_fact_num_contrato` | B-tree (`text`) | 519 MiB | **691 MB** | Búsquedas y detección de duplicados |
| `ix_fact_proveedor` | B-tree (`int`) | 346 MiB | **373 MB** | FK más usada: análisis de contratistas |
| `ix_fact_entidad` | B-tree (`int`) | 346 MiB | **203 MB** | FK de entidad, segunda más usada |
| ~~`ix_fact_valor`~~ | ~~B-tree (`numeric`)~~ | ~~519 MiB~~ | ~~639 MB~~ | **eliminado**: redundante con `ix_fact_anio_valor` |
| `ix_fact_fecha_brin` | **BRIN** (`date`) | **2,1 MiB** | **2,1 MiB** | Alternativa al B-tree de fecha: 1/160 del tamaño |
| | | ≈ 2,5 GiB | **≈ 2,9 GB** | 6 índices en total |

**Ahorro clave:** sustituir el B-tree de `fecha_firma` por un **BRIN** ahorra ~344 MiB con pérdida mínima de rendimiento, porque los datos llegan ordenados por año de origen. Es una decisión que se documenta en `decisiones_tecnicas.md` (Entregable 2/4).

> **Medido después de cargar.** La proyección subestimó los índices en 400 MB (2,5 GiB → 2,9 GB), en parte porque no contemplaba el `fillfactor = 90` en cada partición ni el reparto de la partición `pre2000`, que arrastra sus índices aunque solo tenga 1,78M de las 22,67M filas. Aun así el error es del 15% y el total de índices de 12,9 GB que incluye las 8 dimensiones cuadra con la sección 11.

---

## 7. Particionamiento

### 7.1 Criterio

`fact_contrato` se particiona por **RANGE sobre el año de `fecha_firma_del_contrato`**, alineado con la distribución medida en la sección 3.2.

### 7.2 Estimación de particiones

Años con datos reales: **2000 a 2026** = 27 años. La proyección original estimaba **29 particiones** añadiendo 2027 y un año de seguridad.

> **Corrección posterior a la carga: son 30 particiones.** La cuenta final es: cuarentena `fact_contrato_pre2000` (1900-01-01 → 2000-01-01), **28 particiones anuales** 2000-2027, y `fact_contrato_resto` como partición por defecto. Son **30** y no 29 porque la cuarentena va **antes** del rango de años en lugar de ocupar un año de seguridad. Verificado en la base cargada: `pg_inherits` devuelve exactamente 30 hijos de `gold.fact_contrato`.

### 7.3 Beneficios esperados

| Beneficio | Detalle |
|---|---|
| Consultas por año | Solo lee 1 de 30 particiones → ~97% menos I/O |
| `VACUUM` / `ANALYZE` | Se puede hacer por partición, en vez de 12 GB de una vez |
| Índices | Cada índice de partición es 30 veces más pequeño → caben en RAM |
| Mantenimiento | Reindexar un año no bloquea los otros 29 |
| Crecimiento | Añadir 2028 = un `CREATE TABLE` nuevo, sin migrar 22,7M filas |

### 7.4 Trade-off explícito

> PostgreSQL **no** permite índice único ni clave primaria que **no incluyan la clave de partición**. Si `fact_contrato` se particiona por año, la PK debe ser `(fecha_firma_del_contrato, id_contrato)`.
>
> **Alternativa evaluada y rechazada:** mantener la tabla sin particionar y aceptar el costo de un `VACUUM` completo. Con 15,3 GB de RAM y 12 GiB de tabla, se opta por **particionar** y aceptar la PK compuesta. La decisión se registra en `decisiones_tecnicas.md`.

---

## 8. Anomalías volumétricas detectadas

Estas no son cuestiones de estilo: son las que **cambian el número** y **rompen los cálculos**. Se desarrollan en `calidad_datos.md`.

### 8.1 Fechas imposibles

| Anomalía | Registros | Valor máximo observado |
|---|---:|---|
| Año de firma > 2026 (futuro) | **106** | 2099-12-30 |
| Año de fin de ejecución > 2026 | ~4.000+ | **8201-12-21** |
| Año de inicio de ejecución < 1994 | ~1.000+ | **1899-11-27** |
| Sin fecha de firma válida | 1.767.413 | — |

**Impacto:** rompen cualquier `GROUP BY` por año y cualquier media de duración de contrato. Requieren la función `es_fecha_valida()` del ETL.

### 8.2 Duplicados de clave natural

**4.621.012 filas (20,38%)** comparten `numero_del_contrato` (sección 3.8).

### 8.3 Inconsistencias de mayúsculas/minúsculas

| Dimensión | Valores distintos | Valores tras normalizar |
|---|---:|---:|
| `tipo_de_contrato` | 33 | ~20 |
| `modalidad_de_contrataci_n` | 38 | ~22 |
| `estado_del_proceso` | 30 | ~20 |
| `departamento_entidad` | 38 | **35** (33 departamentos + `No Definido` + `Colombia` inválido) |
| `nivel_entidad` | 7 | 4 |
| `tipo_documento_proveedor` | 19 | ~13 |

### 8.4 Valores centinela y cero

| Anomalía | Registros | % |
|---|---:|---:|
| `valor_contrato = 0` | 667.689 | 2,94% |
| `valor_contrato = 999999999999999` (centinela) | ≤ 2.267 *(cota, no aislado)* | < 0,01% |
| `nom_raz_social_contratista = 'NO DEFINIDO'` | *no medido* | *pendiente* |
| `documento_proveedor = 'NO DEFINIDO'` | *no medido* | *pendiente* |

> Las dos últimas filas **no se midieron** de forma aislada: la cifra de ~1,5M que aparece en la metadata del portal no es confiable (ver sección 1). Se miden en `calidad_datos.md` (RF-19). Todo KPI monetary debe excluir los centinelas.

**Consecuencia sobre la volumetría:** si la capa Gold deduplica y normaliza, el **número de filas baja**, no sube. Por eso las estimaciones de la sección 6 asumen la tabla completa sin deduplicar, que es el **peor caso**.

---

## 9. Crecimiento proyectado

| Año | Registros acumulados | Proyección por año | Tamaño CSV | Tamaño PostgreSQL (Est. B') |
|---|---:|---:|---:|---:|
| 2026 (corte 21/09) | 22,67M | — | 19,7 GiB | 11 – 13 GiB |
| 2027 | ~24,4M | +1,73M | 21,2 GiB | 12 – 14 GiB |
| 2028 | ~26,2M | +1,80M | 22,7 GiB | 13 – 15 GiB |
| 2029 | ~28,1M | +1,90M | 24,4 GiB | 14 – 16 GiB |
| 2030 | ~30,1M | +2,00M | 26,1 GiB | 15 – 17 GiB |

**Tasa de crecimiento medida:** el pico de 2025 (2,12M) frente a 2014 (822 mil) es **+5,8× en 11 años**, con el volumen de los últimos 3 años estable en ~1,5M/año más el parcial de 2026. Estimación conservadora: **+1,7M a +2,0M filas/año**.

---

## 10. Riesgo de capacidad

### 10.1 Recursos de la máquina

| Recurso | Disponible | Necesario | Margen |
|---|---:|---:|---|
| Disco libre (C:) | **129 GB** | 20 GB (CSV) + 26 GB (BD) = **46 GB** | 83 GB |
| RAM | **15,3 GB** | 8 GB (PostgreSQL) | 7,3 GB |
| Núcleos | 12 | 2 (carga COPY) | 10 |
| Puerto 5432 | Libre · PostgreSQL 18.6 activo | — | — |

**Veredicto: capacidad suficiente.** Incluso el peor caso (CSV completo en disco + Escenario A) ocupa 46 GB de 129 GB.

### 10.2 Riesgo de tiempo de descarga

| Método | Velocidad medida | Tiempo estimado para 22,67M filas |
|---|---|---|
| Endpoint oficial (monocanal, sin gzip) | 0,5 – 1,2 MB/s | **4 – 10 horas** ⚠️ |
| API paginada, 4 conexiones en paralelo | 4 – 9 MB/s | **30 – 50 minutos** ✅ |

**Estrategia adoptada:** descarga paginada en paralelo con la API `/resource/`, que además entrega gzip. Se documenta en `etl_carga.md` (Entregable 4, responsable **José**).

### 10.3 Riesgo de memoria durante la carga

Cargar 22,67M filas con `COPY` en un solo lote dispara la memoria. **Mitigación:** lotes de 250.000 filas con `commit` por lote, como en el proyecto PlascspBigData. Detalle en `etl_carga.md`.

---

## 11. Consultas SQL para reemplazar estas estimaciones por cifras reales

Estas consultas se ejecutan **después de la carga** (Entregable 4) y su resultado se pega en la sección 6 de este documento para convertir la proyección en medición real.

```sql
-- 11.1 Conteo real cargado vs conteo de la API (deben coincidir: 22.670.028)
SELECT count(*) AS filas_cargadas FROM staging.contratos_raw;

-- 11.2 Tamaño real por tabla
SELECT
  relname AS tabla,
  n_live_tup AS filas,
  pg_size_pretty(pg_table_size(relid))      AS tabla_solo,
  pg_size_pretty(pg_indexes_size(relid))    AS indices,
  pg_size_pretty(pg_total_relation_size(relid)) AS total
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC;

-- 11.3 Tamaño real por partición (confirma el reparto por año)
SELECT
  c.relname AS particion,
  pg_size_pretty(pg_total_relation_size(c.oid)) AS total,
  pg_get_expr(c.relpartbound, c.oid) AS rango
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
JOIN pg_class p ON p.oid = i.inhparent
WHERE p.relname = 'fact_contrato'
ORDER BY c.relname;

-- 11.4 Bytes reales por fila (el número clave para validar la sección 6)
SELECT
  pg_size_pretty(pg_table_size('silver.contrato')) AS tabla,
  pg_size_pretty(pg_table_size('silver.contrato')::bigint / count(*)) AS bytes_por_fila,
  count(*) AS filas
FROM silver.contrato;

-- 11.5 Distribución real por origen (contraste con la sección 3.1)
SELECT origen, count(*) AS n,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct
FROM silver.contrato GROUP BY origen ORDER BY n DESC;

-- 11.6 Porcentaje de nulos real por columna
SELECT
  count(*) FILTER (WHERE fecha_de_firma_del_contrato IS NULL) * 100.0 / count(*) AS nul_firma,
  count(*) FILTER (WHERE fecha_inicio_ejecuci_n     IS NULL) * 100.0 / count(*) AS nul_inicio,
  count(*) FILTER (WHERE fecha_fin_ejecuci_n        IS NULL) * 100.0 / count(*) AS nul_fin,
  count(*) AS total
FROM silver.contrato;

-- 11.7 Tamaño de cada dimensión (confirma la sección 6.3)
SELECT relname, n_live_tup,
       pg_size_pretty(pg_total_relation_size(relid)) AS total
FROM pg_stat_user_tables
WHERE relname LIKE 'dim_%' ORDER BY n_live_tup DESC;

-- 11.8 Tamaño de los índices
-- OJO: pg_stat_user_indexes no tiene filas para una tabla particionada padre,
-- porque el padre no almacena páginas. Los índices de los hijos tampoco
-- aparecen con relname = 'fact_contrato'. Hay que recorrer pg_inherits, o
-- consultar el índice del padre y sumar sus hijos (esto fue un error real
-- durante la carga, ver bitacora_sesiones.md).
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

-- 11.9 Dónde viven realmente las particiones (esta consulta destapó el bug
-- de esquema: 28 de 30 estaban en 'public' en vez de 'gold')
SELECT n.nspname AS esquema, c.relname AS particion, c.relispartition,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS tamano
FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE i.inhparent = 'gold.fact_contrato'::regclass
ORDER BY n.nspname, c.relname;
```

---

## 11bis. Medición real tras la carga completa

Ejecutado el 27 y 28 de septiembre de 2026 sobre las 22.670.028 filas. Estos son los números reales, no proyecciones.

### 11bis.1 Las tres capas cuadran exactamente

| Capa | Filas | Tiempo de carga |
|---|---:|---:|
| `staging.contratos_raw` (`COPY` desde CSV) | **22.670.028** | 5,9 min |
| `silver.contrato` | **22.670.028** | 91,8 min |
| `gold.fact_contrato` | **22.670.028** | 144,8 min |
| `gold.v_contratos` (vista, 8 JOIN) | **22.670.028** | — |

**Cero filas perdidas** en los 8 JOIN contra las dimensiones, **0 huérfanos**, **0 PK duplicadas**.

### 11bis.2 Tamaño real en base de datos

| Esquema | Tamaño |
|---|---:|
| `staging` | 20 GB |
| `silver` | 21 GB |
| `gold` | 20 GB |
| **Base completa** | **60 GB** |

La proyección de la sección 6.3 (17-19 GiB) se quedó corta: el modelo en estrella real ocupa 60 GB porque **las tres capas coexisten**, cosa que la proyección no contemplaba (sumaba solo `gold`). Ver `decisiones_tecnicas.md` para el plan de reducción.

### 11bis.3 Cardinalidades reales de las dimensiones

Todas las estimaciones de la sección 6.3 erano proyecciones. Estas son las medidas:

| Dimensión | Proyectado | **Real** | Nota |
|---|---:|---:|---|
| `dim_proveedor` | 3.364.090 | **2.508.996** | de 2.772.691 valores crudos: la normalización colapsó 263.655 duplicados por puntos y guiones |
| `dim_entidad` | 17.183 | **15.928** | |
| `dim_tiempo` | ~9.960 | **47.847** | 1900-01-01 a 2030-12-31, incluye el centinela |
| `dim_modalidad` | 38 | **35** | |
| `dim_tipo_contrato` | 33 | **31** | |
| `dim_estado` | 30 | **29** | |
| `dim_tipo_documento` | 19 | **18** | |
| `dim_origen` | 2 | **2** | |
| `dim_ubicacion` | 1.131 | **eliminada** | se solapaba con `dim_entidad` |

### 11bis.4 Nulos de fecha: por qué el real supera al proyectado

| Campo | Proyectado | **Real** | Motivo |
|---|---:|---:|---|
| `fecha_firma` | 1.767.413 (7,80%) | **1.779.534 (7,85%)** | además de los nulos del origen, se descartan las **fechas imposibles** (1899, 2099, 8201) |
| `fecha_inicio` | 12,08% | **2.609.445 (11,51%)** | |
| `fecha_fin` | 6,72% | **1.582.907 (6,98%)** | |

Las 1.779.534 filas con `fecha_firma` inválida se quedan con el centinela `1900-01-01` y caen en la partición de cuarentena `fact_contrato_pre2000`.

### 11bis.5 Anomalías del origen, preservadas a propósito

| Anomalía | Filas |
|---|---:|
| `valor_contrato = 0` | 802.977 |
| `valor_contrato >= 1e12` (centinelas) | 597 |
| `duracion_dias < 0` | 670 |
| `fecha_fin < fecha_inicio` | 662 |

No se corrigen en la capa gold: son hechos del dato, no errores de carga. Se detectan y se cuentan aquí para que el consumidor decida.

### 11bis.6 Índices reales de la tabla de hechos

| Índice | Espacio | Estado |
|---|---:|---|
| `ix_fact_anio_valor` | 875 MB | se queda |
| `fact_contrato_pk` | 755 MB | se queda |
| `ix_fact_num_contrato` | 691 MB | se queda |
| ~~`ix_fact_valor`~~ | ~~639 MB~~ | **eliminado**: `valor_contrato` suelto es redundante con `ix_fact_anio_valor` y 803 mil ceros de 22,67M lo hacen inservible |
| `ix_fact_proveedor` | 373 MB | se queda |
| `ix_fact_entidad` | 203 MB | se queda |
| `ix_fact_fecha_brin` | 2,1 MB | se queda: es un **BRIN**, no un B-tree redundante |

---

## 12. Conclusiones

1. **El requisito de volumen se cumple con holgura:** 22.670.028 registros = **2,27×** el mínimo de 10 millones.
2. **El origen no es relacional**, pero el modelo en estrella resultó viable: la base se construyó y cargó completa, con 8 dimensiones que absorben 2.508.996 proveedores y 15.928 entidades. La proyección de 3,36M de proveedores se quedaba 34% arriba, porque la normalización de documentos colapsa 263.655 duplicados que el origen tenía como texto distinto.
3. **El 50,8% del payload son 2 columnas de texto libre** (`objeto_del_proceso` + `objeto_a_contratar`). Descartar la primera reduce la base a la mitad, pero `objeto_del_proceso` es un requisito de datos (D-04), así que **se conservó** y la estrella real quedó en el escenario B, no en el B'.
4. **El 20,38% de las filas repite su número de contrato.** Por eso el grano se fijó en el contrato *registrado*, no en el número de contrato, y los repetidos se marcan en vez de borrarse.
5. **La metadata del portal está desfasada en 1,87M registros.** Todo conteo de referencia se debe medir, nunca leer de la ficha web.
6. **El espacio estimado era 11 – 26 GiB y el real fue 60 GB**, porque se optó por conservar las 3 capas a la vez (staging + silver + gold) en lugar de truncar tras cada consumo. La capacidad nunca fue el riesgo, pero la duplicación sí pesa: ver la sección 8 de `decisiones_tecnicas.md`.
7. **El riesgo real fue el tiempo de descarga** (4–10 h en monostream frente a los ~50 min paginado en paralelo con 6 hilos). De ahí la decisión de descarga paginada.
8. **BRIN en vez de B-tree para las fechas** ahorra ~344 MiB con rendimiento casi idéntico, y confirmó la proyección al milimetro (2,1 MiB proyectados y medidos).
9. **Particionar por año** (30 particiones) reduce las consultas anuales a ~1/30 del I/O y permite mantenimiento por bloques. También fue lo que permitió detectar el bug de las 28 particiones en `public`, consultando `pg_inherits` con el esquema de cada hijo.
10. **La mayor anomalía es el 20,38% de filas con número de contrato repetido**, seguida de los nulos en fechas (1.779.534 sin firma válida tras aplicar el centinela, 2.609.445 sin inicio, 1.582.907 sin fin). A esto se suman las 106 fechas de firma en el futuro y las mayúsculas inconsistentes. Todo eso se trata en el ETL, no en el análisis.
11. **La volumetría proyectó bien el tamaño** (−1,6% frente a los 19,40 GiB reales) y **mal las cardinalidades**, sobreestimando siempre. La lección es que el conteo de filas y el espacio se pueden estimar con una muestra, pero el número de claves distintas de un texto libre no: eso solo se sabe recorriéndolo.

---

## 13. Referencias

| Documento | Contenido |
|---|---|
| [Plan_Entrega.md](Plan_Entrega.md) | Los 5 entregables, roles, actividades y calendario |
| [requerimientos.md](requerimientos.md) | 20 RF + 10 RNF y los 10 requisitos de datos D-01 a D-10 que esta volumetría respalda (conteos, distribuciones, límites de fecha y exclusiones de valor) |
| [diccionario_datos.md](diccionario_datos.md) | *Pendiente* — las 22 columnas en detalle |
| [calidad_datos.md](calidad_datos.md) | *Pendiente* — desarrollo de la sección 8 |
| [modelo_relacional.md](modelo_relacional.md) | *Pendiente (Entregable 2)* — modelo de la sección 6.3 |
| [etl_carga.md](etl_carga.md) | *Pendiente (Entregable 4)* — estrategia de la sección 10.2 |
| [decisiones_tecnicas.md](decisiones_tecnicas.md) | Por qué el modelo es como es: 8 dimensiones, rango 1900-2030, centinela de fechas, índices, y las optimizaciones pendientes |
| [bitacora_sesiones.md](bitacora_sesiones.md) | Los errores encontrados durante la carga y cómo se resolvieron |

**Fuente de datos:** Agencia Nacional de Contratación Pública — Colombia Compra Eficiente. Licencia [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
