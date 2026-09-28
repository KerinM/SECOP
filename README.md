# SECOP Integrado — Base de Datos de Contratación Pública

Proyecto de construcción de una **base de datos relacional** a partir de los datos abiertos del **SECOP Integrado** (SECOP I + SECOP II) de Colombia, sobre PostgreSQL, con un modelo analítico en estrella y visualización en Power BI.

| | |
|---|---|
| **Fuente** | [SECOP Integrado — datos.gov.co](https://www.datos.gov.co/Estad-sticas-Nacionales/SECOP-Integrado/rpmr-utcd) · Socrata ID `rpmr-utcd` |
| **Volumen** | **22.670.028 registros** · 22 columnas · 19,40 GiB en CSV |
| **Motor** | PostgreSQL 18.6 en `localhost:5432` |
| **Arquitectura** | Medallion (staging → silver → gold) |
| **Visualización** | Power BI Desktop |
| **Equipo** | Kerin · José · Isabella |
| **Entrega** | miércoles **14 de octubre de 2026** |
| **Licencia de los datos** | CC BY-SA 4.0 — Agencia Nacional de Contratación Pública / Colombia Compra Eficiente |

---

## 1. ¿Qué hace este proyecto?

El SECOP Integrado es un **archivo CSV plano** de 22,67 millones de contratos, no una base de datos. Tiene 22 columnas, casi todas texto, con fechas imposibles, números de contrato repetidos y categorías duplicadas por diferencias de mayúsculas.

Este proyecto lo convierte en un **modelo relacional analítico**: una tabla de hechos con 22,67M de contratos y 8 dimensiones, particionada por año, con índices pensados para consultas de negocio y un tablero en Power BI.

**El grano de la tabla de hechos es un contrato registrado**, es decir, una de las 22.670.028 filas del origen. Los 4.621.012 contratos con número repetido se conservan marcados, no se eliminan.

## 2. Estado actual

| Entregable | Responsable | Estado |
|---|---|---|
| **1 · Volumetría** | Kerin | ✅ Completo y verificado contra la carga real |
| **2 · Modelo conceptual y lógico** | Kerin | ✅ DDL construido y cargado |
| **3 · Metodología Medallion** | José | ✅ Implementada en las 3 capas |
| **4 · Explicación de los ETL** | José | ✅ Scripts de descarga y carga funcionando |
| **5 · Fotos de las visualizaciones** | Isabella | Pendiente |

**La base de datos está construida y cargada con los 22.670.028 registros.** Las tres capas cuadran exactamente, con 0 filas perdidas en la transformación y 0 huérfanos. Lo pendiente es el tablero de Power BI.

## 3. Empezar aquí

| Quiero… | Abre |
|---|---|
| Entender **por qué** el modelo es así | **[docs/decisiones_tecnicas.md](docs/decisiones_tecnicas.md)** |
| Ver los errores que ya encontramos | **[docs/bitacora_sesiones.md](docs/bitacora_sesiones.md)** |
| Instalar y configurar el entorno | **[docs/instalacion-postgresql-dbeaver.md](docs/instalacion-postgresql-dbeaver.md)** |
| Entender el origen de los datos | **[docs/volumetria.md](docs/volumetria.md)** |
| Saber quién hace qué y cuándo | **[docs/Plan_Entrega.md](docs/Plan_Entrega.md)** |
| Ver qué debe cumplir el sistema | **[docs/requerimientos.md](docs/requerimientos.md)** |
| Navegar toda la documentación | **[docs/README.md](docs/README.md)** |

## 4. Inicio rápido

```powershell
# 1. Configurar PostgreSQL (tuning aplicado por script, con auto-elevación)
#    Detalle en docs/instalacion-postgresql-dbeaver.md, seccion 3
.\scripts\tuning_postgresql.ps1
Restart-Service -Name "postgresql-x64-18"

# 2. Crear rol, base de datos y esquemas
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U postgres -h localhost -d postgres -i sql\00_instalacion.sql

# 3. Crear el modelo. Por defecto es idempotente; con -v recrear=1
#    reconstruye desde cero (¡borra los datos!)
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U secop_etl -h localhost -d secop_integrado -w -v recrear=1 -i sql\01_esquema.sql

# 4. Entorno de Python
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install requests psycopg2-binary

# 5. Credenciales locales (nunca se versionan)
Copy-Item .env.example .env
```

### Cargar los datos

```powershell
# Descargar las 454 páginas (~19,4 GiB, ~50 min con 6 hilos). Reanudable.
python scripts\descargar_secop.py --hilos 6

# Cargar y transformar. --etapa staging|silver|gold|todas
python scripts\cargar_secop.py --etapa todas --truncar
```

Tiempos reales de la carga completa: `COPY` a staging **5,9 min**, silver **91,8 min**, gold **144,8 min**. Las tres capas deben acabar en 22.670.028 filas.

## 5. Estructura del proyecto

```text
SECOP/
├── README.md                  <- Este archivo
├── .gitignore                 <- Excluye datos, logs, .pbix y credenciales
├── .env.example               <- Plantilla de credenciales (sin clave real)
│
├── data/                      <- Datos descargados (NO se versionan, 19,4 GiB)
│   └── descargas/             <- 454 partes CSV de 50.000 filas
│
├── sql/
│   ├── 00_instalacion.sql     <- Rol, base de datos, esquemas, secop_ci, permisos
│   └── 01_esquema.sql         <- staging + silver + gold (8 dim, 30 particiones, vista)
│
├── scripts/
│   ├── tuning_postgresql.ps1  <- Ajustes de postgresql.conf, con backup
│   ├── descargar_secop.py     <- API paginada de Socrata, reanudable
│   └── cargar_secop.py        <- COPY + silver + gold, con verificación
│
└── docs/
    ├── README.md                  índice
    ├── volumetria.md              Entregable 1, con medición real de la carga
    ├── Plan_Entrega.md            plan, roles, calendario
    ├── requerimientos.md          20 RF + 10 RNF
    ├── instalacion-postgresql-dbeaver.md   guía de instalación
    ├── decisiones_tecnicas.md     por qué el modelo es así, y lo que queda pendiente
    ├── bitacora_sesiones.md       cronología y errores encontrados
    ├── modelo_relacional.md       Pendiente (Kerin) - Entregable 2
    ├── etl_carga.md               Pendiente (José) - Entregables 3 y 4
    ├── calidad_datos.md           Pendiente (Isabella)
    ├── visualizaciones.md         Pendiente (Isabella) - Entregable 5
    ├── consultas_ejemplos.md      Pendiente (Kerin)
    ├── diccionario_datos.md       Pendiente (Kerin)
    ├── glosario.md                Pendiente (Kerin)
    └── imagenes/                  Pendiente (Isabella) - Entregable 5
```

El `.gitignore` excluye `data/`, `logs/` y las credenciales: de los 19,8 GB del proyecto solo se versionan **0,21 MB** de código y documentación.

## 6. Hallazgos clave del dataset

Medidos contra la API el 26/09/2026. El detalle está en [`docs/volumetria.md`](docs/volumetria.md).

| Hallazgo | Valor |
|---|---|
| Registros | **22.670.028** (2,27× el mínimo de 10 millones exigido) |
| Distribución por origen | SECOPI **14.603.263** · SECOPII **8.066.765** |
| La ficha web miente | Declara 20.800.218 — desfasada en **1.869.810** registros |
| Contratos con número repetido | **4.621.012** (20,38%) |
| Sin fecha de firma válida | **1.779.534** (7,85%) tras la carga: nulos del origen **+ fechas imposibles** (1899, 2099, 8201) |
| Fechas de firma en el futuro | **106** registros, en 18 años entre 2044 y 2099 |
| Valor máximo | `2.407.343.429.966` (centinela de error, contamina las sumas) |
| Valores en cero | **802.977** |
| Orden | **No está ordenado cronológicamente** |
| Tamaño real | 917,7 bytes/fila → **19,40 GiB** en CSV · **60 GB** en PostgreSQL con las 3 capas |

**Consecuencia práctica:** el conteo de referencia es siempre el de la API en vivo, nunca el de la ficha web.

**Los tres datos que más sorprenden al trabajar con este origen:**

1. **El CSV tiene saltos de línea dentro de los campos.** Contar líneas no sirve; hay que parsear con un lector CSV.
2. **El texto llega con la caja rota** (`ADQUISICIoN`, `CRIPTOGRaFICOS`). Las dimensiones colapsan las variantes gracias a la collation `secop_ci`, no a la función de normalización.
3. **El número de contrato no es único.** Por eso el grano es el contrato *registrado* y no el número de contrato.

## 7. Roles

| Miembro | Rol | Entregables | Requisitos |
|---|---|---|---|
| **Kerin** | Analista de Datos | 1 y 2 | RF-07 a RF-13, RNF-05 a RNF-07 |
| **José** | ETL / Administrador de PostgreSQL | 3 y 4 | RF-01 a RF-06, RNF-01 a RNF-04 |
| **Isabella** | QA / Visualización | 5 | RF-14 a RF-20, RNF-08 a RNF-10 |

## 8. Calendario

Lunes y miércoles, 6 sesiones. Entrega el **miércoles 14/10/2026**.

| Sesión | Fecha | Foco |
|---|---|---|
| 1 | Lun 28/09 | Volumetría · Crear BD · Configurar Power BI |
| 2 | Mié 30/09 | Cierre de volumetría · Descarga y carga |
| 3 | Lun 05/10 | Modelo conceptual · Medallion · Validación de integridad |
| 4 | Mié 07/10 | Modelo lógico y DDL · ETL parte 1 · Power BI parte 1 |
| 5 | Lun 12/10 | Consultas analíticas · Índices y particionado · Power BI parte 2 |
| 6 | Mié 14/10 | **ENTREGA** |

## 9. Requisitos técnicos del entorno

| Componente | Versión |
|---|---|
| PostgreSQL | 18.6 en `localhost:5432` |
| DBeaver | Community 26.2.0 (instalación por usuario) |
| Python | 3.14.5 |
| RAM | 15,3 GB |
| Núcleos | 12 lógicos |
| Disco libre | 128,4 GB antes de cargar; ~41,6 GB después de los 60 GB de base |

## 10. Licencia y atribución

Los datos del SECOP Integrado son públicos y están bajo **licencia CC BY-SA 4.0**, publicados por la **Agencia Nacional de Contratación Pública — Colombia Compra Eficiente**.

Esta atribución debe aparecer en toda la documentación y en el tablero de visualizaciones, según el requisito **D-10**.
