# Documentación — SECOP Integrado

Índice de la documentación técnica del proyecto. Para la vista general del proyecto (equipo, calendario, estructura), ver el [README raíz](../README.md).

| | |
|---|---|
| **Fuente de datos** | [SECOP Integrado](https://www.datos.gov.co/Estad-sticas-Nacionales/SECOP-Integrado/rpmr-utcd) · Socrata ID `rpmr-utcd` |
| **Volumen** | **13.005.402 registros** en plata y oro · **16.025.993** en bronce · 22 columnas de origen |
| **Modelo** | Estrella de **5 dimensiones** y una tabla de hechos, particionada en 13 particiones |
| **Requisitos** | 14 requerimientos de negocio (RQ) · 22 funcionales (RF) · 10 no funcionales (RNF) |
| **Entrega** | miércoles 14 de octubre de 2026 |

---

## Documentos

### Esenciales — léelos primero

| Documento | Qué contiene | Responsable | Estado |
|---|---|---|---|
| [volumetria.md](volumetria.md) | **Entregable 1** — Medición del origen: conteo real por capa, deduplicación, cardinalidades, anomalías medidas y riesgo de capacidad. Los puntos no medidos están marcados como pendientes, con su consulta | Kerin | ✅ Completo |
| [modelo_relacional.md](modelo_relacional.md) | **Entregable 2** — Modelo conceptual y lógico derivado de los requerimientos, normalización 1FN/2FN/3FN, diagramas PlantUML, el grano del modelo, las vistas de consumo y los cambios respecto al modelo anterior | Kerin | ✅ Completo |
| [explicacion_e2.md](explicacion_e2.md) | Explicación teórica del Entregable 2: por qué el modelo es así, qué se validó y cómo respondió a las correcciones del profesor | Kerin | ✅ Completo |
| [decisiones_tecnicas.md](decisiones_tecnicas.md) | **Por qué el modelo es así**: 5 dimensiones derivadas de los RQ, `dim_tiempo` con clave entera y registro `-1`, las llaves degeneradas, las reglas de negocio (`tipo_persona`, `es_competitiva`, `agrupacion_estado`, `valor_gastado`), la regla R5 y el particionado | Kerin | ✅ Completo |
| [medicion_estados_y_documentos.md](medicion_estados_y_documentos.md) | Medición de estados de contrato y tipos de documento que respalda RQ13, `tipo_persona`, `valor_gastado` y la regla R5. Incluye el hallazgo de que «ANULADO» no existe en la fuente | Kerin | ✅ Completo |
| [bitacora_sesiones.md](bitacora_sesiones.md) | Cronología de las sesiones de los dos cortes de datos: qué se construyó, los errores encontrados y cómo se resolvieron | Kerin | ✅ Completo |
| [Plan_Entrega.md](Plan_Entrega.md) | Los 5 entregables, roles, actividades por sesión, ceremonias Scrum, backlog, diagrama Gantt y el modelo Medallión acordado | Kerin | ✅ Completo |
| [requerimientos.md](requerimientos.md) | RQ01-RQ14, 22 RF y 10 RNF con responsable asignado, más 10 requisitos de datos (D-01 a D-10) derivados de la medición | Kerin | ✅ Completo |
| [instalacion-postgresql-dbeaver.md](instalacion-postgresql-dbeaver.md) | Guía técnica para montar el entorno: tuning de PostgreSQL, creación de rol y base, conexión DBeaver, entorno Python y verificación | José | ✅ Completo |

### Material de apoyo

| Documento | Qué contiene | Responsable |
|---|---|---|
| [monologo-diapositivas-6-9.md](monologo-diapositivas-6-9.md) | Guion hablado de las diapositivas 6 a 9 (volumetría, capas, datos de origen y granularidad) | Equipo |

### Pendientes

| Documento | Qué contendrá | Responsable | Entregable |
|---|---|---|---|
| etl_carga.md | Descarga paginada, carga por lotes, mapeo de tipos, saneamiento de fechas, índices y particionado. Mientras tanto, el ETL de bronce y plata está documentado en `sql/ETL/README_ETL.md` | José | **3** y **4** |
| calidad_datos.md | Desarrollo de las anomalías de la volumetría §4 y las clases de problemas de calidad | Isabella | — |
| visualizaciones.md | Descripción de las páginas del tablero, medidas DAX y KPIs | Isabella | **5** |
| imagenes/ | Capturas PNG de las visualizaciones en alta resolución | Isabella | **5** |
| consultas_ejemplos.md | ≥ 15 consultas analíticas de negocio con su tiempo de ejecución | Kerin | — |
| diccionario_datos.md | Las 22 columnas de origen con tipo, descripción, nulos, cardinalidad y ejemplo | Kerin | — |
| glosario.md | Modalidades de contratación, mínima cuantía, régimen especial | Kerin | — |

---

## Documentación que vive junto al código

| Archivo | Qué contiene |
|---|---|
| [sql/ETL/README_ETL.md](../sql/ETL/README_ETL.md) | Orden de ejecución del ETL de bronce y plata, las reglas R1-R9b, la regla R5 y los hallazgos de calidad |
| [sql/ETL/resultado_qa.md](../sql/ETL/resultado_qa.md) | Resultado de las pruebas de calidad en SQL sobre plata |
| [sql/ETL/reporte_validacion_python.md](../sql/ETL/reporte_validacion_python.md) | Resultado de la validación independiente en Python (43 pruebas) |
| [sql/02_modelo_gold.sql](../sql/02_modelo_gold.sql) | DDL ejecutable de la capa oro, con su carga y su verificación |
| [sql/04_vistas.sql](../sql/04_vistas.sql) | Vistas materializadas y vistas de consumo para Power BI |
| [sql/retirado/README.md](../sql/retirado/README.md) | Por qué se archivó el pipeline anterior |

---

## Orden de lectura sugerido

```text
1. volumetria.md              -> entender el origen de los datos
2. decisiones_tecnicas.md     -> entender por qué el modelo es así
3. instalacion-postgresql-dbeaver.md  -> montar el entorno
4. requerimientos.md          -> saber qué debe cumplir el sistema
5. Plan_Entrega.md            -> saber quién hace qué y cuándo
6. modelo_relacional.md       -> el modelo de la bodega (conceptual, lógico, DDL)
7. sql/ETL/README_ETL.md      -> cómo se cargan y se limpian bronce y plata
8. visualizaciones.md         -> cómo se ve
```

## Rutas por rol

| Soy… | Leo |
|---|---|
| **Kerin** — Analista de Datos | volumetria → decisiones_tecnicas → requerimientos (RF-07 a RF-13, RF-21, RF-22) → Plan_Entrega → modelo_relacional → consultas_ejemplos |
| **José** — ETL / PostgreSQL | decisiones_tecnicas → instalacion-postgresql-dbeaver → requerimientos (RF-01 a RF-06) → volumetria §5 y §8 → sql/ETL/README_ETL.md |
| **Isabella** — QA / Visualización | volumetria §4 → decisiones_tecnicas §5 y §6 (`dim_tiempo` y el registro `-1`) y §13 (vistas) → modelo_relacional §7.5 (`-1`) y §11 (vistas) → requerimientos (RF-14 a RF-20) → calidad_datos → visualizaciones |

## Rutas por requerimiento

| Necesito… | Consulto |
|---|---|
| Saber cuántas filas hay | [volumetria.md](volumetria.md) §1 y §3.1 |
| Saber qué columnas existen y qué tan limpias están | [volumetria.md](volumetria.md) §3.3 y §4 |
| Saber cuánto ocupa en PostgreSQL | [volumetria.md](volumetria.md) §5 y §8 |
| Saber qué está mal en los datos | [volumetria.md](volumetria.md) §4 (medido) → `calidad_datos.md` (análisis, pendiente) |
| Instalar el entorno | [instalacion-postgresql-dbeaver.md](instalacion-postgresql-dbeaver.md) |
| Saber por qué el modelo tiene 5 dimensiones | [decisiones_tecnicas.md](decisiones_tecnicas.md) §2 y §3 |
| Saber cómo es `dim_tiempo` y por qué tiene un registro `-1` | [decisiones_tecnicas.md](decisiones_tecnicas.md) §5 y §6 |
| Saber cuál es el grano de la tabla de hechos | [modelo_relacional.md](modelo_relacional.md) §4 |
| Saber qué son las llaves degeneradas y cuáles quedan | [decisiones_tecnicas.md](decisiones_tecnicas.md) §4 |
| Saber cómo se calculan `tipo_persona`, `es_competitiva` y `valor_gastado` | [decisiones_tecnicas.md](decisiones_tecnicas.md) §8 |
| Saber cómo decide R5 qué fila conserva | [sql/ETL/README_ETL.md](../sql/ETL/README_ETL.md) y [decisiones_tecnicas.md](decisiones_tecnicas.md) §8.3 |
| Saber por qué «ANULADO» no existe | [medicion_estados_y_documentos.md](medicion_estados_y_documentos.md) §1 |
| Ver el DDL ejecutable de la capa oro | [sql/02_modelo_gold.sql](../sql/02_modelo_gold.sql) |
| Ver las vistas que consume Power BI | [modelo_relacional.md](modelo_relacional.md) §11 y [sql/04_vistas.sql](../sql/04_vistas.sql) |
| Saber qué se rompió y cómo se arregló | [bitacora_sesiones.md](bitacora_sesiones.md) |
| Saber qué es bronze / silver / gold | [decisiones_tecnicas.md](decisiones_tecnicas.md) §1 |
| Ver el cronograma | [Plan_Entrega.md](Plan_Entrega.md) §3 y §5 |
| Saber qué debe cumplir el sistema | [requerimientos.md](requerimientos.md) |
| Ver quién es responsable de qué | [requerimientos.md](requerimientos.md), encabezado y §4 |