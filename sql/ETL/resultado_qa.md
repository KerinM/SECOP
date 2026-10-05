# Reporte de calidad de la capa plata (SQL)

Base de datos: `secop_dw` · Tabla evaluada: `silver.contratos` (13.005.402 filas)
Script que lo genera: `sql/ETL/05_qa_silver.sql`

**Resumen:** 18 de 18 validaciones automáticas en OK (14 de la prueba 1 y 4 de la prueba 7) y 0 grupos duplicados en plata.

| Prueba | Qué revisa | Resultado |
|---|---|---|
| 1 | Validaciones automáticas por regla (R1, R2, R4, R6, R7, R8) | 14 de 14 en OK |
| 2 | Duplicados (R5) | 0 |
| 3 | Completitud: % de vacíos por columna | Se reporta, no se corrige |
| 4 | Banderas de calidad | Filas marcadas por cada regla |
| 5 | Categorías unificadas (R1 + R3) | `nivel_entidad` de 7 variantes a 3 + vacío |
| 6 | Antes y después (bronce vs. plata por `id_fila`) | Ejemplos reales de cada regla |
| 7 | Corrección de valores (R7b y R9b) | 4 de 4 en OK |
| 8 | Las versiones son el mismo contrato (R7b) | 554.063 contratos, 0 con distinta entidad |
| 9 | Totales por año y los 10 valores más altos de 2025 | 2018: 102,54 billones (oficial ≈ 100) |

---

## Prueba 1. Validaciones automáticas

Todas deben dar 0. Si "encontrados" no es 0, la regla dejó algo sin corregir.

| Regla | Prueba | Encontrados | Estado |
|---|---|---:|---|
| R1 | Textos con minúsculas | 0 | OK |
| R1 | Textos con tildes | 0 | OK |
| R1 | Textos con espacios dobles o sobrantes | 0 | OK |
| R1 | Barras \| sueltas al inicio o al final | 0 | OK |
| R2 | Nulos disfrazados (NO DEFINIDO, N/A...) | 0 | OK |
| R4 | Fecha de firma fuera de rango | 0 | OK |
| R4 | Fecha de inicio fuera de rango | 0 | OK |
| R4 | Fecha de fin fuera de rango | 0 | OK |
| R4 | Fin antes del inicio sin marcar | 0 | OK |
| R6 | Valor en cero sin marcar | 0 | OK |
| R6 | Valores de relleno (999...) sin limpiar | 0 | OK |
| R7 | Valor ajustado mayor que el original | 0 | OK |
| R8 | NIT de entidad con caracteres no numéricos | 0 | OK |
| R8 | Documento de proveedor no numérico | 0 | OK |

## Prueba 2. Duplicados (R5)

| grupos_duplicados_en_plata |
|---:|
| 0 |

## Prueba 3. Completitud: porcentaje de vacíos por columna

Un NULL en plata significa que el dato venía vacío, era "NO DEFINIDO" o era imposible. Se reporta, no se inventa.

| Columna | Vacíos | % vacíos |
|---|---:|---:|
| municipio | 1.411.585 | 10,85 |
| fecha_inicio | 895.006 | 6,88 |
| nit_entidad | 519.784 | 4,00 |
| departamento | 48.932 | 0,38 |
| documento_proveedor | 30.709 | 0,24 |
| nombre_proveedor | 3.574 | 0,03 |
| modalidad | 3.073 | 0,02 |
| tipo_contrato | 1.905 | 0,01 |
| codigo_entidad | 900 | 0,01 |
| fecha_fin | 125 | 0,00 |
| valor_contrato | 94 | 0,00 |
| fecha_firma | 3 | 0,00 |
| id_contrato | 0 | 0,00 |

## Prueba 4. Banderas de calidad

| total_plata | fecha_invalida | fechas_incoherentes | valor_cero | valor_relleno | valor_repetido | valor_atipico |
|---:|---:|---:|---:|---:|---:|---:|
| 13.005.402 | 30 | 664 | 80.137 | 94 | 148.035 | 33.938 |

## Prueba 5. Categorías unificadas (R1 + R3)

### `nivel_entidad`

| nivel_entidad | Filas |
|---|---:|
| TERRITORIAL | 10.243.401 |
| NACIONAL | 2.649.793 |
| CORPORACION AUTONOMA | 85.994 |
| *(vacío)* | 26.214 |

### `modalidad`

| modalidad | Filas |
|---|---:|
| CONTRATACION DIRECTA | 8.177.358 |
| REGIMEN ESPECIAL | 3.487.229 |
| MINIMA CUANTIA | 922.288 |
| SELECCION ABREVIADA | 234.894 |
| CONTRATOS Y CONVENIOS CON MAS DE DOS PARTES | 65.229 |
| LICITACION PUBLICA | 65.124 |
| CONCURSO DE MERITOS | 44.706 |
| *(vacío)* | 3.073 |
| SELECCION ABREVIADA MENOR CUANTIA SIN MANIFESTACION INTERES | 1.561 |
| LICITACION PUBLICA ACUERDO MARCO DE PRECIOS | 1.110 |
| SELECCION ABREVIADA SERVICIOS DE SALUD | 1.050 |
| SELECCION ABREVIADA DEL LITERAL H DEL NUMERAL 2 DEL ARTICULO 2 DE LA LEY 1150 DE 2007 | 611 |
| ASOCIACION PUBLICO PRIVADA | 451 |
| ENAJENACION DE BIENES CON SOBRE CERRADO | 269 |
| ENAJENACION DE BIENES CON SUBASTA | 250 |
| CONCURSO DE MERITOS CON LISTA CORTA | 128 |
| CONCURSO DE DISENO ARQUITECTONICO | 54 |
| CONCURSO DE MERITOS CON PRECALIFICACION | 15 |
| OTRAS FORMAS DE CONTRATACION DIRECTA | 2 |

## Prueba 6. Antes y después (bronce vs. plata por `id_fila`)

### 6.1 Textos (R1, R2, R3)

| id_fila | nivel_bronce | nivel_plata | depto_bronce | depto_plata | muni_bronce | muni_plata |
|---:|---|---|---|---|---|---|
| 15957204 | Nacional | NACIONAL | Santander | SANTANDER | San Gil | SAN GIL |
| 15955646 | Territorial | TERRITORIAL | Santander | SANTANDER | Bucaramanga | BUCARAMANGA |
| 15955506 | Nacional | NACIONAL | Distrito Capital de Bogotá | BOGOTA D.C. | Bogotá | BOGOTA D.C. |
| 15955459 | Territorial | TERRITORIAL | Norte de Santander | NORTE DE SANTANDER | Cúcuta | CUCUTA |
| 15955322 | Territorial | TERRITORIAL | Antioquia | ANTIOQUIA | Venecia | VENECIA |
| 15955422 | Territorial | TERRITORIAL | Santander | SANTANDER | Bucaramanga | BUCARAMANGA |
| 15955331 | Territorial | TERRITORIAL | Santander | SANTANDER | Bucaramanga | BUCARAMANGA |
| 15962140 | Territorial | TERRITORIAL | Distrito Capital de Bogotá | BOGOTA D.C. | No Definido | NULL |
| 15956506 | Territorial | TERRITORIAL | Valle del Cauca | VALLE DEL CAUCA | No Definido | NULL |
| 15955433 | Territorial | TERRITORIAL | Santander | SANTANDER | Bucaramanga | BUCARAMANGA |

### 6.2 Fechas imposibles (R4)

| id_fila | inicio_bronce | inicio_plata | fin_bronce | fin_plata | flag_fecha_invalida |
|---:|---|---|---|---|---|
| 14536665 | *(vacío)* | NULL | 2925-12-24T23:00:00.000 | NULL | t |
| 14536666 | 2025-11-12T07:00:00.000 | 2025-11-12 | 2925-12-24T23:59:00.000 | NULL | t |
| 478276 | 2094-08-02T00:00:00.000 | NULL | 2094-08-02T00:00:00.000 | NULL | t |
| 478275 | 2097-04-23T00:00:00.000 | NULL | 2097-04-23T00:00:00.000 | NULL | t |
| 1528915 | 2098-01-02T00:00:00.000 | NULL | 2098-05-02T00:00:00.000 | NULL | t |
| 16025993 | 2026-10-15T00:00:00.000 | 2026-10-15 | 2026-10-16T00:00:00.000 | 2026-10-16 | t |
| 16025991 | 2026-10-05T00:00:00.000 | 2026-10-05 | 2026-10-06T00:00:00.000 | 2026-10-06 | t |
| 2579269 | 2018-08-02T08:00:00.000 | 2018-08-02 | 8201-12-21T23:59:00.000 | NULL | t |
| 11151640 | 2024-03-12T00:00:00.000 | 2024-03-12 | 2924-12-31T23:59:00.000 | NULL | t |
| 11329617 | 2024-04-17T00:00:00.000 | 2024-04-17 | 2924-08-12T00:00:00.000 | NULL | t |

### 6.3 Valores de relleno (R6)

| id_fila | valor_bronce | valor_plata | flag_valor_relleno |
|---:|---:|---|---|
| 3641364 | 999999999 | NULL | t |
| 14661561 | 99999999 | NULL | t |
| 14688564 | 99999999 | NULL | t |
| 15617058 | 99999999 | NULL | t |
| 1399872 | 99999999 | NULL | t |
| 998460 | 99999999 | NULL | t |
| 2863740 | 999999999 | NULL | t |
| 2643284 | 99999999 | NULL | t |
| 2867025 | 99999999 | NULL | t |
| 3042923 | 99999999 | NULL | t |

### 6.4 NIT (R8)

| id_fila | nit_bronce | nit_plata |
|---:|---|---|
| 4014853 | NO DEFINIDO | NULL |
| 4097191 | 891801770-3 | 891801770 |
| 3319352 | 899999034-1 | 899999034 |
| 3641046 | 890503483-2 | 890503483 |
| 3754118 | NO DEFINIDO | NULL |
| 4135684 | 890905211-1 | 890905211 |
| 3873647 | 800099084-6 | 800099084 |
| 3885860 | 890204646-3 | 890204646 |
| 3287949 | 899999034-1 | 899999034 |
| 3988396 | 800065593-7 | 800065593 |

### 6.5 Valor repetido repartido (R7)

El contrato que más se repetía en bronce. Antes se sumaba el valor completo en cada fila; ahora la suma da el valor real.

| id_contrato | filas_en_plata | proveedores | valor_contrato | suma_sin_ajustar | suma_ajustada |
|---|---:|---:|---:|---:|---:|
| 18-4-7947515 | 518 | 473 | 5.858.500.000,00 | 3.034.703.000.000,00 | 5.858.500.000,08 |

## Prueba 7. Corrección de valores (R7b y R9b)

Todas deben dar 0.

| Regla | Prueba | Encontrados | Estado |
|---|---|---:|---|
| R7b | Contratos con versiones sin ajustar | 0 | OK |
| R7b | Contratos cuya suma no queda entre su mínimo y su máximo | 0 | OK |
| R9b | Valores extremos sin marcar como atípicos | 0 | OK |
| R9b | Extremos marcados pero no excluidos (sin `flag_valor_atipico`) | 0 | OK |

## Prueba 8. ¿Las versiones son de verdad el mismo contrato? (R7b)

| grupos | con_distinto_proceso | con_distinta_fecha_firma | con_distinta_entidad |
|---:|---:|---:|---:|
| 554.063 | 4.720 | 116 | 0 |

## Prueba 9. Totales por año y valores más altos

### 9.1 Totales por año (billones de pesos)

Se compara `billones_sin_atipicos` con las cifras oficiales: ≈ 100 billones en 2018 y ≈ 111 en enero a octubre de 2023.

| Año | Contratos | Billones (total) | Billones (sin atípicos) |
|---|---:|---:|---:|
| 2017 | 1.197.434 | 196,74 | 94,19 |
| 2018 | 1.191.851 | 653,19 | **102,54** |
| 2019 | 1.283.407 | 198,08 | 104,86 |
| 2020 | 1.277.700 | 138,55 | 101,78 |
| 2021 | 1.466.176 | 182,95 | 141,97 |
| 2022 | 1.285.723 | 234,08 | 122,79 |
| 2023 | 1.167.049 | 156,97 | **125,33** |
| 2024 | 1.357.111 | 145,22 | 119,14 |
| 2025 | 1.602.637 | 1.137,61 | 153,17 |
| 2026 (hasta el 29/09) | 1.176.311 | 103,73 | 86,71 |
| *(sin fecha de firma)* | 3 | 0,00 | 0,00 |

### 9.2 Los 10 valores más altos de 2025

| id_fila | nombre_entidad | nombre_proveedor | valor_contrato | atípico | extremo |
|---:|---|---|---:|---|---|
| 14467800 | INSTITUTO MUNICIPAL PARA LA RECREACION Y EL DEPORTE-PASTO DEPORTE | FUNDACION PILTO | 944.187.311.000.000,00 | t | f |
| 14720760 | MINISTERIO DE MINAS Y ENERGIA | GECELCA S.A. E.S.P. | 4.205.027.751.839,00 | f | f |
| 13915046 | RNEC | UNION TEMPORAL INTEGRACION LOGISTICA ELECTORAL 2026 | 3.339.924.733.944,00 | t | f |
| 12965607 | MINISTERIO DE COMERCIO INDUSTRIA Y TURISMO - MINCIT | ZONA FRANCA BARRANQUILLA | 2.846.224.257.835,00 | t | f |
| 13461723 | DEPARTAMENTO DE SANTANDER | INSTITUTO FINANCIERO PARA EL DESARROLLO DE SANTANDER | 2.600.000.000.000,00 | t | t |
| 13915044 | RNEC | UNION TEMPORAL INTEGRACION LOGISTICA ELECTORAL 2026 | 2.553.311.282.500,00 | t | f |
| 13915039 | RNEC | UNION TEMPORAL INTEGRACION LOGISTICA ELECTORAL 2026 | 2.552.978.539.300,00 | t | f |
| 13195461 | GOBERNACION DE BOYACA | YESID AVILA TORRES | 2.385.617.800.000,00 | t | f |
| 13915041 | RNEC | UNION TEMPORAL INTEGRACION LOGISTICA ELECTORAL 2026 | 2.383.967.513.300,00 | t | f |
| 13915040 | RNEC | UNION TEMPORAL INTEGRACION LOGISTICA ELECTORAL 2026 | 2.222.283.357.704,00 | t | f |