# SECOP Integrado — Base de Datos de Contratación Pública

Proyecto de construcción de una **base de datos relacional** a partir de los datos abiertos del **SECOP Integrado** (SECOP I + SECOP II) de Colombia, sobre PostgreSQL, con un modelo analítico en estrella y visualización en Power BI.

| | |
|---|---|
| **Fuente** | [SECOP Integrado — datos.gov.co](https://www.datos.gov.co/Estad-sticas-Nacionales/SECOP-Integrado/rpmr-utcd) · Socrata ID `rpmr-utcd` |
| **Volumen** | **13.005.402 registros** en plata · **16.025.993** en bronce · 16 columnas |
| **Motor** | PostgreSQL 18.6 en `localhost:5432` |
| **Arquitectura** | Medallion (bronze → silver → gold) en la base `secop_dw` |
| **Visualización** | Power BI Desktop |
| **Equipo** | Kerin · José · Isabella |
| **Entrega** | miércoles **14 de octubre de 2026** |
| **Licencia de los datos** | CC BY-SA 4.0 — Agencia Nacional de Contratación Pública / Colombia Compra Eficiente |

---

## 1. ¿Qué hace este proyecto?

El SECOP Integrado es un **archivo CSV plano** de contratos, no una base de datos. Tiene 16 columnas, casi todas texto, con fechas imposibles, números de contrato repetidos, categorías duplicadas por diferencias de mayúsculas y **3 millones de filas duplicadas exactas**.

Este proyecto lo convierte en un **modelo relacional analítico**: una tabla de hechos y 7 dimensiones, particionada por año, con índices pensados para consultas de negocio y un tablero en Power BI.

**El grano de la tabla de hechos es una versión de contrato**, es decir, una de las 13.005.402 filas de `silver.contratos`. SECOP II publica cada modificación como una fila nueva, así que un contrato con tres modificaciones aparece tres veces, y eso es lo que permite analizar el fraccionamiento (RF-08). Los duplicados **exactos** sí se eliminan: 16.025.993 → 13.005.402.

## 2. Estado actual

| Entregable | Responsable | Estado |
|---|---|---|
| **1 · Volumetría** | Kerin | ✅ Completo y verificado contra la carga real |
| **2 · Modelo conceptual y lógico** | Kerin | ✅ Completo · modelo, 2 diagramas y DDL en [`docs/modelo_relacional.md`](docs/modelo_relacional.md) |
| **3 · Metodología Medallion** | José | ✅ Implementada en las 3 capas |
| **4 · Explicación de los ETL** | José | ✅ Scripts de descarga y carga funcionando |
| **5 · Fotos de las visualizaciones** | Isabella | ✅ Completo hasta capa oro |

**`bronze` y `silver` están cargadas y validadas** (16.025.993 y 13.005.402 filas, 42/42 pruebas de calidad OK). El Entregable 2 está documentado y su DDL está escrito, pero **la capa `gold` aún no se ha ejecutado**, porque su construcción necesita las credenciales de la base. Lo pendiente es correr `sql/02_modelo_gold.sql`, medir `gold` y completar el tablero de Power BI.

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

Hay dos rutas según el estado de tu máquina. `psql` no lee `.env`: para pasar la clave
sin escribirla en la línea de comandos, la variable `PGPASSWORD` es la que lo hace.

### 4.1 Ya tengo la base `secop_dw` cargada

Si `bronze.secop_raw` y `silver.contratos` ya están poblados, solo falta construir oro.
No hace falta correr `00_instalacion.sql` ni el ETL.

```powershell
# 1. Credenciales locales (nunca se versionan)
Copy-Item .env.example .env
$env:PGPASSWORD = (Get-Content .env | Select-String "^PGPASSWORD=").ToString().Split("=")[1]

# 2. Construir la capa oro desde silver. Es idempotente: con -v recrear=1
#    reconstruye SOLO gold y deja bronce y plata intactas.
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U secop_etl -h localhost -d secop_dw -w -f sql\02_modelo_gold.sql
```

### 4.2 Quiero montarlo desde cero

```powershell
# 1. Configurar PostgreSQL (tuning aplicado por script, con auto-elevación)
#    Detalle en docs/instalacion-postgresql-dbeaver.md, seccion 3
.\scripts\tuning_postgresql.ps1
Restart-Service -Name "postgresql-x64-18"

# 2. Crear rol secop_etl, base secop_dw y esquemas bronze/silver/gold/logs.
#    Es idempotente: si la base ya existe, la reutiliza tal cual.
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U postgres -h localhost -d postgres -i sql\00_instalacion.sql

# 3. Cargar bronce y plata con el ETL, en este orden:
#    01_cargar_bronce -> 02_silver_limpieza -> 02b_correccion_barras
#    -> 02c_correccion_valores -> 05_qa_silver
#    Cada paso está documentado en sql/ETL/README_ETL.md

# 4. Construir la capa oro
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U secop_etl -h localhost -d secop_dw -w -f sql\02_modelo_gold.sql

# 5. Entorno de Python (solo lo necesita 06_validacion_python.py)
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install requests psycopg2-binary
```

## 5. Estructura del proyecto

```text
SECOP/
├── README.md                  <- Este archivo
├── .gitignore                 <- Excluye datos, logs, .pbix y credenciales
├── .env.example               <- Plantilla de credenciales (sin clave real)
│
├── data/                      <- Datos descargados (NO se versionan)
│   └── descargas/             <- 10 CSV, uno por año de contrato (2017-2026)
│
├── sql/
│   ├── 00_instalacion.sql       <- Rol, base secop_dw y esquemas medallion
│   ├── 02_modelo_gold.sql      <- E2: capa oro (7 dim, 13 particiones, vistas)
│   ├── ETL/                     <- E3+E4: bronce, plata, correcciones y QA
│   │   ├── 01_cargar_bronce.sql
│   │   ├── 02_silver_limpieza.sql       reglas R1-R9
│   │   ├── 02b_correccion_barras.sql
│   │   ├── 02c_correccion_valores.sql   R7b y R9b
│   │   ├── 05_qa_silver.sql             42 pruebas
│   │   └── README_ETL.md
│   └── retirado/                <- Modelo anterior (secop_integrado). NO ejecutar
│       ├── README.md
│       ├── 01_esquema.sql
│       ├── descargar_secop.py
│       └── cargar_secop.py
│
├── scripts/
│   └── tuning_postgresql.ps1  <- Ajustes de postgresql.conf, con backup
│
└── docs/
    ├── README.md                  índice
    ├── volumetria.md              Entregable 1, con medición del corte vigente
    ├── Plan_Entrega.md            plan, roles, calendario
    ├── requerimientos.md          20 RF + 10 RNF
    ├── instalacion-postgresql-dbeaver.md   guía de instalación
    ├── decisiones_tecnicas.md     por qué el modelo es así, y lo que queda pendiente
    ├── bitacora_sesiones.md       cronología y errores encontrados
    ├── modelo_relacional.md       Entregable 2 (Kerin)
    ├── etl_carga.md               Pendiente (José) - Entregables 3 y 4
    ├── calidad_datos.md           Pendiente (Isabella)
    ├── visualizaciones.md         Pendiente (Isabella) - Entregable 5
    ├── consultas_ejemplos.md      Pendiente (Kerin)
    ├── diccionario_datos.md       Pendiente (Kerin)
    ├── glosario.md                Pendiente (Kerin)
    └── imagenes/                  Pendiente (Isabella) - Entregable 5
```

El `.gitignore` excluye `data/`, `logs/` y las credenciales: del proyecto solo se versionan código y documentación, unos pocos cientos de KB.

## 6. Hallazgos clave del dataset

Medidos sobre la base `secop_dw` cargada. El detalle está en [`docs/volumetria.md`](docs/volumetria.md).

| Hallazgo | Valor |
|---|---|
| Registros en `bronze` | **16.025.993** (1,60× el mínimo de 10 millones exigido) |
| Registros en `silver` | **13.005.402** (1,30× el mínimo) tras deduplicar |
| Duplicados exactos eliminados | **3.020.591** (18,85%) |
| Rangos de contratos | 2017 – 2026, en 10 CSV (uno por año) |
| La ficha web miente | En el corte anterior declaraba 20.800.218 cuando la verdad eran 22.670.028: desfasada en **1.869.810** |
| Contratos con versiones | **554.063**; en 4.720 de ellos (0,85%) cambia el número de proceso entre versiones |
| Valores atípicos | **33.928**, marcados y **no borrados** |
| Nombres de proveedor con barra suelta | **538**, corregidos |
| Validación de plata | **42/42** pruebas OK |
| Texto dañado desde SECOP | La `ñ` llega como `���`. Irreparable, y **solo afecta nombres**: ni valores, ni fechas, ni llaves |

**Consecuencia práctica:** el conteo de referencia es siempre `count(*)` sobre la base, nunca el de la ficha web.

**Los tres datos que más sorprenden al trabajar con este origen:**

1. **El CSV tiene saltos de línea dentro de los campos.** Contar líneas no sirve; hay que parsear con un lector CSV.
2. **El texto llega con la caja rota** (`ADQUISICIoN`, `CRIPTOGRaFICOS`) y hay 538 nombres con barras sueltas. La normalización ocurre en **plata** (reglas R1 y R3), no en el índice de la base, así que las claves naturales de oro son planas y sus `UNIQUE` no dependen de ninguna collation.
3. **El número de contrato no es único.** SECOP II publica cada modificación como una fila nueva, y por eso el grano es la **versión** y no el contrato.

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
| Disco libre | 128,4 GB antes de cargar |

## 10. Licencia y atribución

Los datos del SECOP Integrado son públicos y están bajo **licencia CC BY-SA 4.0**, publicados por la **Agencia Nacional de Contratación Pública — Colombia Compra Eficiente**.

Esta atribución debe aparecer en toda la documentación y en el tablero de visualizaciones, según el requisito **D-10**.
