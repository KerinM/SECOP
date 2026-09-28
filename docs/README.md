# Documentación — SECOP Integrado

Índice de la documentación técnica del proyecto. Para la vista general del proyecto (equipo, calendario, estructura), ver el [README raíz](../README.md).

| | |
|---|---|
| **Fuente de datos** | [SECOP Integrado](https://www.datos.gov.co/Estad-sticas-Nacionales/SECOP-Integrado/rpmr-utcd) · Socrata ID `rpmr-utcd` |
| **Volumen** | **22.670.028 registros** · 22 columnas · 19,40 GiB |
| **Entrega** | miércoles 14 de octubre de 2026 |

---

## Documentos

### Esenciales — léelos primero

| Documento | Qué contiene | Responsable | Estado |
|---|---|---|---|
| [volumetria.md](volumetria.md) | **Entregable 1** — Medición del origen: conteo real, distribuciones, nulos, cardinalidades, anomalías, bytes por fila, y comparación de la proyección contra lo que realmente ocupa la base cargada | Kerin | ✅ Completo y verificado |
| [decisiones_tecnicas.md](decisiones_tecnicas.md) | **Por qué el modelo es así**: 8 dimensiones en vez de 9, el rango 1900-2030, el centinela de fechas, quién colapsa los duplicados, los índices, y las optimizaciones pendientes con su intercambio exacto | José | ✅ Completo |
| [bitacora_sesiones.md](bitacora_sesiones.md) | Cronología de las sesiones: qué se construyó, los errores encontrados y cómo se resolvieron | Kerin | ✅ Completo |
| [Plan_Entrega.md](Plan_Entrega.md) | Los 5 entregables, roles, actividades por sesión, ceremonias Scrum, backlog, diagrama Gantt y el modelo Medallion acordado | Kerin | ✅ Completo |
| [requerimientos.md](requerimientos.md) | 20 RF + 10 RNF con responsable asignado, más 10 requisitos de datos (D-01 a D-10) derivados de la medición | Kerin | ✅ Completo |
| [instalacion-postgresql-dbeaver.md](instalacion-postgresql-dbeaver.md) | Guía técnica para montar el entorno: tuning de PostgreSQL, creación de rol y base, conexión DBeaver, entorno Python y verificación | José | ✅ Completo |

### Pendientes

| Documento | Qué contendrá | Responsable | Entregable |
|---|---|---|---|
| modelo_relacional.md | Modelo conceptual y lógico, normalización, diagrama en estrella, DDL de las 8 dimensiones y la tabla de hechos | Kerin | **2** |
| etl_carga.md | Descarga paginada, carga por lotes, mapeo de tipos, saneamiento de fechas, índices y particionado | José | **3** y **4** |
| calidad_datos.md | Desarrollo de las anomalías de la volumetría §8 y las 4 clases de problemas de calidad | Isabella | — |
| visualizaciones.md | Descripción de las páginas del tablero, medidas DAX y KPIs | Isabella | **5** |
| imagenes/ | Capturas PNG de las visualizaciones en alta resolución | Isabella | **5** |
| consultas_ejemplos.md | ≥ 15 consultas analíticas de negocio con su tiempo de ejecución | Kerin | — |
| diccionario_datos.md | Las 22 columnas con tipo, descripción, nulos, cardinalidad y ejemplo | Kerin | — |
| glosario.md | Modalidades de contratación, mínima cuantía, régimen especial | Kerin | — |

---

## Orden de lectura sugerido

```text
1. volumetria.md              -> entender el origen de los datos
2. decisiones_tecnicas.md     -> entender por qué el modelo es así
3. instalacion-postgresql-dbeaver.md  -> montar el entorno
4. requerimientos.md          -> saber qué debe cumplir el sistema
5. Plan_Entrega.md            -> saber quién hace qué y cuándo
6. modelo_relacional.md       -> el modelo de la bodega
7. etl_carga.md               -> cómo se carga
8. visualizaciones.md         -> cómo se ve
```

## Rutas por rol

| Soy… | Leo |
|---|---|
| **Kerin** — Analista de Datos | volumetria → decisiones_tecnicas → requerimientos (RF-07 a RF-13) → Plan_Entrega → modelo_relacional → consultas_ejemplos |
| **José** — ETL / PostgreSQL | decisiones_tecnicas → instalacion-postgresql-dbeaver → requerimientos (RF-01 a RF-06) → volumetria §6 y §8 → etl_carga |
| **Isabella** — QA / Visualización | volumetria §8 → decisiones_tecnicas §4 (centinela) → requerimientos (RF-14 a RF-20) → etl_carga §verificación → calidad_datos → visualizaciones |

## Rutas por requerimiento

| necesito… | Consulting |
|---|---|
| Saber cuántas filas hay | [volumetria.md](volumetria.md) §1 |
| Saber qué columnas existen y qué tan limpias están | [volumetria.md](volumetria.md) §2 y §3.7 |
| Saber cuánto ocupa en PostgreSQL | [volumetria.md](volumetria.md) §6 y §11 |
| Saber qué está mal en los datos | [volumetria.md](volumetria.md) §8 |
| Instalar el entorno | [instalacion-postgresql-dbeaver.md](instalacion-postgresql-dbeaver.md) |
| Saber por qué hay 8 dimensiones y no 9 | [decisiones_tecnicas.md](decisiones_tecnicas.md) §2 |
| Saber qué pasó con las fechas nulas | [decisiones_tecnicas.md](decisiones_tecnicas.md) §4 |
| Saber qué se rompió y cómo se arregló | [bitacora_sesiones.md](bitacora_sesiones.md) |
| Saber qué es staging / silver / gold | [Plan_Entrega.md](Plan_Entrega.md) §6 |
| Ver el cronograma | [Plan_Entrega.md](Plan_Entrega.md) §3 y §5 |
| Saber qué debe cumplir el sistema | [requerimientos.md](requerimientos.md) |
| Ver quién es responsable de qué | [requerimientos.md](requerimientos.md) §4 |
