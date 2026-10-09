# Medición de estados de contrato y tipos de documento

**Origen:** correcciones del profesor al modelo estrella (Paso 2 del plan de corrección)
**Base:** `secop_dw` · **Fecha de medición:** 09/10/2026 · **Tabla:** `silver.contratos` (13.005.402 filas)

Todas las cifras de este documento son **medidas** con las consultas incluidas. Las reglas propuestas están marcadas como **provisionales** hasta que el grupo y el profesor las confirmen.

---

## 1. Estados del proceso por plataforma (consulta 2a)

```sql
SELECT origen, estado_proceso, count(*) AS filas
FROM silver.contratos
GROUP BY 1, 2
ORDER BY filas DESC;
```

| Origen | Estado | Filas |
|---|---|---:|
| SECOPI | CELEBRADO | 4.414.138 |
| SECOPI | LIQUIDADO | 1.996.394 |
| SECOPII | EN EJECUCION | 1.902.281 |
| SECOPII | MODIFICADO | 1.548.187 |
| SECOPII | CERRADO | 1.174.268 |
| SECOPII | TERMINADO | 644.692 |
| SECOPII | APROBADO | 531.544 |
| SECOPII | ACTIVO | 502.776 |
| SECOPI | TERMINADO SIN LIQUIDAR | 228.040 |
| SECOPII | CEDIDO | 43.774 |
| SECOPII | SUSPENDIDO | 14.844 |
| SECOPI | CONVOCADO | 3.301 |
| SECOPII | BORRADOR | 434 |
| SECOPI | ADJUDICADO | 323 |
| SECOPII | PRORROGADO | 117 |
| SECOPII | ENVIADO PROVEEDOR | 114 |
| SECOPII | EN APROBACION | 89 |
| SECOPII | CANCELADO | 74 |
| SECOPI | TERMINADO ANORMALMENTE DESPUES DE CONVOCA… | 10 |
| SECOPI | BORRADOR | 1 |
| SECOPII | *(nulo)* | 1 |

### Hallazgos

- **No existe el estado `ANULADO`.** Las únicas cancelaciones son `CANCELADO` (74) y `TERMINADO ANORMALMENTE…` (10): **84 filas, 0,0006 %** de plata.
- Cada plataforma usa un vocabulario de estados distinto.
- Estados precontractuales (BORRADOR, EN APROBACION, ENVIADO PROVEEDOR, CONVOCADO, ADJUDICADO): 4.262 filas.

---

## 2. Estados que chocan en filas idénticas (consulta 2b / 2d)

Sobre bronce, hay **1.169.445 grupos** con el mismo contrato, proceso, proveedor, valor y fecha de firma pero con estados distintos. La regla R5 actual no mira el estado y conserva el menor `id_fila`, por lo que puede quedarse con un estado anterior.

| Combinación de estados | Grupos |
|---|---:|
| Cerrado \| En ejecución | 292.076 |
| Cerrado \| Modificado | 181.635 |
| En ejecución \| terminado | 135.197 |
| Modificado \| terminado | 95.537 |
| Cerrado \| terminado | 63.766 |
| En ejecución \| Modificado | 59.391 |
| Activo \| Cerrado | 54.204 |
| Aprobado \| Modificado | 44.626 |

(Top 8 de 20. Ninguna de las 20 combinaciones incluye un estado de anulación.)

Los choques son **avances del ciclo de vida**, no contradicciones. Como el dataset no trae fecha de modificación, `id_fila` no sirve para decidir cuál es el estado vigente.

### Ranking de ciclo de vida (PROVISIONAL)

De menor a mayor avance. Al deduplicar, se conserva el estado de mayor rango.

| Rango | Estados |
|---:|---|
| 1 | BORRADOR, EN APROBACION, ENVIADO PROVEEDOR, CONVOCADO, ADJUDICADO |
| 2 | APROBADO, ACTIVO, CELEBRADO |
| 3 | EN EJECUCION, MODIFICADO, PRORROGADO |
| 4 | SUSPENDIDO, CEDIDO |
| 5 | TERMINADO, TERMINADO SIN LIQUIDAR, LIQUIDADO |
| 6 | CERRADO |
| 7 | CANCELADO, TERMINADO ANORMALMENTE |

Respaldado por los datos: CERRADO sobre EN EJECUCION y MODIFICADO; TERMINADO sobre ambos. El orden de SUSPENDIDO y CEDIDO es un **juicio**, no una medición.

---

## 3. Tipos de documento del proveedor (consulta 2c)

```sql
SELECT tipo_doc_proveedor, count(*) AS filas
FROM silver.contratos
GROUP BY 1
ORDER BY filas DESC;
```

| Tipo de documento | Filas |
|---|---:|
| CEDULA DE CIUDADANIA | 9.883.909 |
| NIT DE PERSONA JURIDICA | 1.659.999 |
| *(nulo)* | 697.080 |
| NIT DE PERSONA NATURAL | 466.606 |
| NIT | 262.530 |
| CEDULA DE EXTRANJERIA | 14.455 |
| NIT DE EXTRANJERIA | 8.268 |
| OTRO | 3.863 |
| CARNE DIPLOMATICO | 2.353 |
| PERMISO POR PROTECCION TEMPORAL | 1.863 |
| PASAPORTE | 1.327 |
| SOCIEDADES EXTRANJERAS | 1.309 |
| TARJETA DE IDENTIDAD | 1.078 |
| NUIP | 409 |
| PERMISO ESPECIAL DE PERMANENCIA | 242 |
| REGISTRO CIVIL | 81 |
| NUMERO DE FIDEICOMISO | 30 |

Las 17 filas suman 13.005.402.

### Regla de `tipo_persona` (PROVISIONAL)

| tipo_persona | Criterio | Filas |
|---|---|---:|
| NATURAL | CEDULA DE CIUDADANIA, NIT DE PERSONA NATURAL, CEDULA DE EXTRANJERIA, PASAPORTE, TARJETA DE IDENTIDAD, REGISTRO CIVIL, NUIP, CARNE DIPLOMATICO, PERMISO POR PROTECCION TEMPORAL, PERMISO ESPECIAL DE PERMANENCIA | 10.372.323 |
| JURIDICA | NIT DE PERSONA JURIDICA, SOCIEDADES EXTRANJERAS, NUMERO DE FIDEICOMISO, **más la heurística del NIT genérico** | 1.909.481 |
| NO CLASIFICADO | NIT DE EXTRANJERIA, OTRO, nulos y NIT genérico que no cumple la heurística | 723.598 |

**Heurística del NIT genérico (no es una medición directa):** `tipo_doc_proveedor = 'NIT'` con documento de 9 dígitos que empieza por 8 o 9 se clasifica como JURIDICA. Cubre 248.143 de las 262.530 filas con `NIT` genérico (94,5 %). Los 697.080 nulos son el grueso de NO CLASIFICADO.

**Corrección detectada:** el DDL actual deriva `es_persona_natural` con `NOT LIKE 'NIT%'`, lo que clasifica mal "NIT DE PERSONA NATURAL" (466.606 filas) como no natural.

---

## 4. Decisiones pendientes

1. Reformular el RQ de anulaciones como **estado del contrato**, dado que las cancelaciones reales son 84 filas.
2. Confirmar si los estados precontractuales se excluyen de "gastado".
3. Confirmar el orden de SUSPENDIDO y CEDIDO en el ranking.
4. Confirmar la heurística del NIT genérico.
5. Confirmar con el profesor que "gastado" = valor contratado vigente.