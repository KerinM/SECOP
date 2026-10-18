# SECOP Integrado — Base de Datos de Contratación Pública

Proyecto de construcción de un **Data Warehouse** a partir de los datos abiertos del **SECOP Integrado** (SECOP I + SECOP II) de Colombia, sobre PostgreSQL, con un modelo analítico en estrella y visualización en Power BI.

| | |
|---|---|
| **Fuente** | [SECOP Integrado — datos.gov.co](https://www.datos.gov.co/Estad-sticas-Nacionales/SECOP-Integrado/rpmr-utcd) · Socrata ID `rpmr-utcd` |
| **Volumen** | **13.005.402 registros** en plata y oro · **16.025.993** en bronce · 22 columnas de origen |
| **Modelo** | Estrella de **5 dimensiones** y una tabla de hechos, particionada en 13 particiones |
| **Requisitos** | 14 requerimientos de negocio (RQ01-RQ14) · 22 funcionales · 10 no funcionales |
| **Motor** | PostgreSQL 18.6 en `localhost:5432` |
| **Arquitectura** | Medallón (bronze → silver → gold) en la base `secop_dw` |
| **Visualización** | Power BI Desktop |
| **Equipo** | Kerin · José · Isabella |
| **Entrega** | miércoles **14 de octubre de 2026** |
| **Licencia de los datos** | CC BY-SA 4.0 — Agencia Nacional de Contratación Pública / Colombia Compra Eficiente |

---

## 1. Introducción

**SECOP Integrado** es el registro oficial de los contratos públicos de Colombia: reúne los contratos que las entidades del Estado publican en las plataformas SECOP I y SECOP II. Este proyecto trabaja con los **contratos firmados entre 2017 y 2026** (corte del 29/09/2026), que suman **16.025.993 registros** distribuidos en 10 archivos CSV, uno por año.

El dataset describe las entidades que contratan, los proveedores contratados, las fechas de firma y ejecución, la modalidad, el tipo y el estado de cada contrato, y su valor firmado. No incluye el valor pagado ni el ejecutado.

Se publica como un archivo plano con fechas imposibles, textos escritos de formas distintas y más de tres millones de filas duplicadas. Este proyecto lo convierte en un **Data Warehouse** con arquitectura Medallón en PostgreSQL: un modelo en estrella de cinco dimensiones y una tabla de hechos, particionada por año, que se consume desde un tablero en Power BI.

**El grano de la tabla de hechos es una versión de contrato.** SECOP II publica cada modificación como una fila nueva, así que un contrato con tres modificaciones aparece tres veces. Solo se eliminan los duplicados **exactos**: 16.025.993 → 13.005.402.

### 1.1 Objetivo general

Diseñar e implementar un Data Warehouse con arquitectura Medallón que convierta los contratos de SECOP en un modelo estrella para analizar la contratación pública y apoyar decisiones.

### 1.2 Objetivos específicos

1. **Diseñar** un modelo estrella que responda los requerimientos de negocio (RQ01 a RQ14).
2. **Implementar** un proceso ELT Medallón en PostgreSQL con los 16.025.993 registros de 2017 a 2026.
3. **Validar** la calidad de la capa plata con pruebas en SQL y una verificación independiente en Python.
4. **Analizar** el valor, la contratación directa, los proveedores, la duración y el estado de los contratos.
5. **Visualizar** los indicadores en un tablero de Power BI conectado a la capa oro.

## 2. Estado actual

| Entregable | Responsable | Estado |
|---|---|---|
| **1 · Volumetría** | Kerin | ✅ Completo y verificado contra la carga real |
| **2 · Modelo conceptual y lógico** | Kerin | ✅ Completo · modelo, diagramas y DDL en [`docs/modelo_relacional.md`](docs/modelo_relacional.md) |
| **3 · Metodología Medallón** | José | ✅ Implementada en las 3 capas |
| **4 · Explicación de los ETL** | José | ✅ Scripts de carga, limpieza y validación funcionando; documentados en [`sql/ETL/README_ETL.md`](sql/ETL/README_ETL.md) |
| **5 · Fotos de las visualizaciones** | Isabella | 🟡 En curso · las vistas de consumo están listas; faltan el tablero y las capturas |

**Las tres capas están cargadas y verificadas:**

| Capa | Filas | Verificación |
|---|---:|---|
| `bronze.secop_raw` | 16.025.993 | `count(*)` igual al total de los 10 CSV |
| `silver.contratos` | 13.005.402 | 18 validaciones automáticas en SQL y 43 pruebas independientes en Python, todas en OK |
| `gold.fact_contrato` | 13.005.402 | 0 huérfanos en las 5 claves foráneas, 13 particiones en `gold`, 2018 = 102,54 billones |

Lo pendiente es el tablero de Power BI (Entregable 5), la confirmación con el profesor de la definición de «gastado» y la documentación final en PDF.

## 3. Empezar aquí

| Quiero… | Abre |
|---|---|
| Entender **por qué** el modelo es así | **[docs/decisiones_tecnicas.md](docs/decisiones_tecnicas.md)** |
| Ver el modelo conceptual y lógico | **[docs/modelo_relacional.md](docs/modelo_relacional.md)** |
| Ver los errores que ya encontramos | **[docs/bitacora_sesiones.md](docs/bitacora_sesiones.md)** |
| Instalar y configurar el entorno | **[docs/instalacion-postgresql-dbeaver.md](docs/instalacion-postgresql-dbeaver.md)** |
| Entender el origen de los datos | **[docs/volumetria.md](docs/volumetria.md)** |
| Entender cómo se limpian bronce y plata | **[sql/ETL/README_ETL.md](sql/ETL/README_ETL.md)** |
| Saber qué estados y tipos de documento hay | **[docs/medicion_estados_y_documentos.md](docs/medicion_estados_y_documentos.md)** |
| Saber quién hace qué y cuándo | **[docs/Plan_Entrega.md](docs/Plan_Entrega.md)** |
| Ver qué debe cumplir el sistema | **[docs/requerimientos.md](docs/requerimientos.md)** |
| Navegar toda la documentación | **[docs/README.md](docs/README.md)** |

## 4. Inicio rápido

Hay dos rutas según el estado de tu máquina. `psql` no lee `.env`: para pasar la clave sin escribirla en la línea de comandos, la variable `PGPASSWORD` es la que lo hace.

### 4.1 Ya tengo la base `secop_dw` con bronce y plata cargadas

Si `bronze.secop_raw` y `silver.contratos` ya están poblados, solo falta construir oro y las vistas. No hace falta correr `00_instalacion.sql` ni el ETL.

```powershell
# 1. Credenciales locales (nunca se versionan)
Copy-Item .env.example .env
$env:PGPASSWORD = (Get-Content .env | Select-String "^PGPASSWORD=").ToString().Split("=")[1]

# 2. Construir la capa oro desde silver. Es idempotente: con -v recrear=1
#    reconstruye SOLO gold y deja bronce y plata intactas.
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U secop_etl -h localhost -d secop_dw -w -f sql\02_modelo_gold.sql

# 3. Crear las vistas de consumo para Power BI (es idempotente)
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U secop_etl -h localhost -d secop_dw -w -f sql\04_vistas.sql
```

### 4.2 Quiero montarlo desde cero

```powershell
# 1. Configurar PostgreSQL (tuning aplicado por script, con auto-elevación)
#    Detalle en docs/instalacion-postgresql-dbeaver.md, seccion 3
.\scripts\tuning_postgresql.ps1
Restart-Service -Name "postgresql-x64-18"

# 2. Crear roles, base secop_dw y esquemas bronze/silver/gold/logs.
#    Es idempotente: si la base ya existe, la reutiliza tal cual.
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U postgres -h localhost -d postgres -i sql\00_instalacion.sql

# 3. Cargar bronce y plata con el ETL, en este orden:
#    01_cargar_bronce -> 01b_trazabilidad_bronce -> 02_silver_limpieza
#    -> 02c_correccion_valores -> 05_qa_silver -> 06_validacion_python
#    Cada paso está documentado en sql/ETL/README_ETL.md

# 4. Construir la capa oro y las vistas de consumo
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U secop_etl -h localhost -d secop_dw -w -f sql\02_modelo_gold.sql
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U secop_etl -h localhost -d secop_dw -w -f sql\04_vistas.sql

# 5. Entorno de Python (solo lo necesita 06_validacion_python.py)
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install pandas psycopg2-binary
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
│   ├── 00_instalacion.sql       <- Roles, base secop_dw y esquemas Medallón
│   ├── 02_modelo_gold.sql       <- E2: capa oro (5 dimensiones, 13 particiones, vistas base)
│   ├── 04_vistas.sql            <- Vistas de consumo para Power BI (8 materializadas y 14 normales)
│   ├── ETL/                     <- E3+E4: bronce, plata, correcciones y QA
│   │   ├── 01_cargar_bronce.sql
│   │   ├── 01b_trazabilidad_bronce.sql
│   │   ├── eda_perfilado.sql
│   │   ├── 02_silver_limpieza.sql       reglas R1-R9, con R5 por estado de mayor avance
│   │   ├── 02b_correccion_barras.sql    solo para plata creada con la versión anterior
│   │   ├── 02c_correccion_valores.sql   R7b y R9b
│   │   ├── 05_qa_silver.sql             18 validaciones automáticas
│   │   ├── 06_validacion_python.py      43 pruebas independientes
│   │   ├── README_ETL.md
│   │   ├── resultado_qa.md
│   │   └── reporte_validacion_python.md
│   └── retirado/                <- Modelo anterior (secop_integrado). NO ejecutar
│       ├── README.md
│       ├── 01_esquema.sql
│       ├── descargar_secop.py
│       └── cargar_secop.py
│
├── scripts/
│   ├── tuning_postgresql.ps1  <- Ajustes de postgresql.conf, con backup
│   └── inspeccionar_csv.py    <- Revisa encabezado y columnas de los CSV
│
├── powerbi/                   <- Tablero de Power BI (el .pbix no se versiona)
│
└── docs/
    ├── README.md                  índice
    ├── volumetria.md              Entregable 1, con medición del corte vigente
    ├── Plan_Entrega.md            plan, roles, calendario
    ├── requerimientos.md          RQ01-RQ14, 22 RF y 10 RNF
    ├── instalacion-postgresql-dbeaver.md   guía de instalación
    ├── decisiones_tecnicas.md     por qué el modelo es así, y lo que queda pendiente
    ├── bitacora_sesiones.md       cronología y errores encontrados
    ├── modelo_relacional.md       Entregable 2 (Kerin)
    ├── explicacion_e2.md          explicación teórica del Entregable 2
    ├── medicion_estados_y_documentos.md   medición que respalda las reglas de negocio
    ├── etl_carga.md               Pendiente (José) - Entregables 3 y 4
    ├── calidad_datos.md           Pendiente (Isabella)
    ├── visualizaciones.md         Pendiente (Isabella) - Entregable 5
    ├── consultas_ejemplos.md      Pendiente (Kerin)
    ├── diccionario_datos.md       Pendiente (Kerin)
    ├── glosario.md                Pendiente (Kerin)
    └── imagenes/                  Pendiente (Isabella) - Entregable 5
```

El `.gitignore` excluye `data/`, `logs/`, los `.pbix` y las credenciales: del proyecto solo se versionan código y documentación, unos pocos cientos de KB.

## 6. Hallazgos clave del dataset

Medidos sobre la base `secop_dw` cargada. El detalle está en [`docs/volumetria.md`](docs/volumetria.md).

| Hallazgo | Valor |
|---|---|
| Registros en `bronze` | **16.025.993** (1,60× el mínimo de 10 millones exigido) |
| Registros en `silver` y `gold` | **13.005.402** (1,30× el mínimo) tras deduplicar |
| Duplicados exactos eliminados | **3.020.591** (18,85%) |
| Rango de contratos | 2017 – 2026, en 10 CSV (uno por año); 2026 llega hasta el 29/09 |
| La ficha web miente | En el corte anterior declaraba 20.800.218 cuando la verdad eran 22.670.028: desfasada en **1.869.810** |
| Contratos con versiones | **554.063** (medido antes de corregir R5). Cada versión es una fila de SECOP II |
| Valores atípicos | **33.939**, marcados y **no borrados** |
| Estado «ANULADO» | **No existe** en la fuente: las cancelaciones son 84 filas (0,0006 %) |
| Nombres de proveedor con barra suelta | **538**, corregidos |
| Validación de plata | **18** validaciones en SQL y **43** pruebas en Python, todas en OK |
| Dinero de 2018 sin atípicos | **102,54 billones** frente a ≈ 100 oficiales |
| Texto dañado desde SECOP | La `ñ` llega como `���`. Irreparable, y **solo afecta nombres**: ni valores, ni fechas, ni llaves |

**Consecuencia práctica:** el conteo de referencia es siempre `count(*)` sobre la base, nunca el de la ficha web.

**Los datos que más sorprenden al trabajar con este origen:**

1. **El CSV tiene saltos de línea dentro de los campos.** Contar líneas no sirve; hay que parsear con un lector CSV.
2. **El texto llega con la caja rota** (`ADQUISICIoN`, `CRIPTOGRaFICOS`) y hay 538 nombres con barras sueltas. La normalización ocurre en **plata** (reglas R1 y R3), no en el índice de la base, así que las claves naturales de oro son planas y sus `UNIQUE` no dependen de ninguna collation.
3. **El número de contrato no es único.** SECOP II publica cada modificación como una fila nueva, y por eso el grano es la **versión** y no el contrato.
4. **Sumar el valor original infla el dinero.** Con `valor_contrato`, 2018 daba ≈ 692 billones. Las medidas correctas son `valor_ajustado` (que reparte el valor entre las versiones) y `valor_gastado`, siempre excluyendo los atípicos.
5. **«Gastado» no es dinero pagado.** La fuente no trae valor pagado ni ejecutado: `valor_gastado` es el valor contratado vigente.

## 7. Roles

| Miembro | Rol | Entregables | Requisitos |
|---|---|---|---|
| **Kerin** | Analista de Datos | 1 y 2 | RF-07 a RF-13, RF-21, RF-22, RNF-05 a RNF-07 |
| **José** | ETL / Administrador de PostgreSQL | 3 y 4 | RF-01 a RF-06, RNF-01 a RNF-04 |
| **Isabella** | QA / Visualización | 5 | RF-14 a RF-20, RNF-08 a RNF-10 |

## 8. Calendario

Lunes y miércoles, 6 sesiones. Entrega el **miércoles 14/10/2026**.

| Sesión | Fecha | Foco |
|---|---|---|
| 1 | Lun 28/09 | Volumetría · Crear BD · Configurar Power BI |
| 2 | Mié 30/09 | Cierre de volumetría · Descarga y carga |
| 3 | Lun 05/10 | Modelo conceptual · Medallón · Validación de integridad |
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