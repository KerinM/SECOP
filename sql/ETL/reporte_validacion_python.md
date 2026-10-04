# Validación independiente de la capa plata (Python)

Fecha: 2026-10-04 16:51 · Duración: 13.5 min · Muestra: 0.8 % de plata, semilla 42

Tabla de tildes y símbolos: unaccent.rules del servidor (2661 caracteres)

**42 de 42 pruebas en OK**

| Prueba | Encontrados | Estado | Detalle |
|---|---|---|---|
| A1. Filas en bronce | 16.025.993 | OK | esperado 16.025.993 |
| A2. Filas en plata | 13.005.402 | OK | esperado 13.005.402 |
| A3. Filas de plata que no vienen de bronce | 0 | OK |  |
| B0. Filas revisadas en la muestra | 104.172 | OK |  |
| B. origen: plata ≠ Python | 0 | OK | (R1) |
| B. id_contrato: plata ≠ Python | 0 | OK | (-) |
| B. id_proceso: plata ≠ Python | 0 | OK | (-) |
| B. nivel_entidad: plata ≠ Python | 0 | OK | (R1-R2) |
| B. codigo_entidad: plata ≠ Python | 0 | OK | (R1) |
| B. nombre_entidad: plata ≠ Python | 0 | OK | (R1) |
| B. nit_entidad: plata ≠ Python | 0 | OK | (R8) |
| B. departamento: plata ≠ Python | 0 | OK | (R1-R3) |
| B. municipio: plata ≠ Python | 0 | OK | (R1-R3) |
| B. estado_proceso: plata ≠ Python | 0 | OK | (R1-R2) |
| B. modalidad: plata ≠ Python | 0 | OK | (R1-R3) |
| B. tipo_contrato: plata ≠ Python | 0 | OK | (R1-R3) |
| B. objeto_contrato: plata ≠ Python | 0 | OK | (R1) · 18 difieren solo en símbolos especiales (aceptable) |
| B. fecha_firma: plata ≠ Python | 0 | OK | (R4) |
| B. fecha_inicio: plata ≠ Python | 0 | OK | (R4) |
| B. fecha_fin: plata ≠ Python | 0 | OK | (R4) |
| B. valor_contrato: plata ≠ Python | 0 | OK | (R6) |
| B. tipo_doc_proveedor: plata ≠ Python | 0 | OK | (R1-R2) |
| B. documento_proveedor: plata ≠ Python | 0 | OK | (R8) |
| B. nombre_proveedor: plata ≠ Python | 0 | OK | (R1) · 2 difieren solo en símbolos especiales (aceptable) |
| B. url_contrato: plata ≠ Python | 0 | OK | (-) |
| B. flag_fecha_invalida: plata ≠ Python | 0 | OK | (R4) |
| B. flag_fechas_incoherentes: plata ≠ Python | 0 | OK | (R4) |
| B. flag_valor_cero: plata ≠ Python | 0 | OK | (R6) |
| B. flag_valor_relleno: plata ≠ Python | 0 | OK | (R6) |
| B. Textos con minúsculas | 0 | OK |  |
| B. Textos con tildes o Ñ | 0 | OK |  |
| B. Textos con espacios dobles o en los bordes | 0 | OK |  |
| B. Nulos disfrazados que siguen como texto | 0 | OK |  |
| B. NIT o documento con algo distinto de dígitos | 0 | OK |  |
| C1. Filas repetidas en plata | 0 | OK |  |
| C2. Filas eliminadas sin gemela en plata | 0 | OK | de 1000 revisadas (0 omitidas por no tener número de contrato o proceso) |
| D. Contratos cuya suma ajustada no es el promedio de sus versiones | 0 | OK | de 2.000 contratos revisados |
| E. Extremos marcados | 10 | OK | esperado 10 |
| E. Extremos sin excluir o por debajo de 1 billón | 0 | OK |  |
| F1. 2018 (oficial ≈ 100 billones) | 102.54 | OK | tolerancia ±15 % |
| F2. 2023 (oficial ≈ 111 billones de enero a octubre) | 125.33 | OK | el año completo debe ser mayor y no exagerado (111–160) |
| F3. Años 2017–2025 fuera de 60–200 billones | 0 | OK |  |

## Ejemplos

- Extremo: BOGOTA D.C. - INSTITUTO DISTRITAL DE GESTION DE RIESGOS Y CAMBIO CLIMATICO - IDIGER → ACUEDUCTO: 28.11 billones
- Extremo: CESAR - ALCALDIA MUNICIPIO DE VALLEDUPAR → BANCO BILBAO VIZCAYA ARGENTARLA COLOMBIA: 25.00 billones
- Extremo: CESAR - ALCALDIA MUNICIPIO DE VALLEDUPAR → BANCO DAVIVIENDA S.A: 15.00 billones
- Extremo: DANE - TERRITORIAL CENTRO ORIENTE → FRANCISCO ANTONIO ALVARADO BESTENE: 9.65 billones
- Extremo: EMPRESA SOCIAL DEL ESTADO NORTE 1 ESE → ASOCIACION SINDICAL EN SALUD ASIES: 5.55 billones
- Extremo: BOGOTA D.C. - TRANSMILENIO → MINISTERIO DE HACIENDA Y CREDITO PUBLICO MINISTERIO DE TRANSPORTE BOGOTA DISTRITO CAPITAL TRANSMI: 4.97 billones
- Extremo: SANTANDER - INSTITUTO DE CULTURA Y TURISMO DE BUCARAMANGA → LA FUNDACION TEATRO SANTANDER Y LA UNIVERSIDAD AUTONOMA DE BUCARAMANGA: 3.00 billones
- Extremo: DEPARTAMENTO DE SANTANDER → INSTITUTO FINANCIERO PARA EL DESARROLLO DE SANTANDER: 2.60 billones
- Extremo: ALCALDIA MUNICIPAL DE OCANA → ASOCIACION PROMOTORA MEDIOAMBIENTAL: 1.41 billones
- Extremo: CESAR - ALCALDIA MUNICIPIO DE CURUMANI → EMPRESA DE SERVICIOS PUBLICOS DE ACUEDUCTO ALCANTIRALLADO Y ASEO DEL MUNICIPIO DE CURUMANI-ACUACUR E: 1.22 billones
