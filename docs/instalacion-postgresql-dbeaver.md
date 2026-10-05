# Instalación y configuración del entorno — SECOP Integrado

Guía técnica para montar y dejar operativo el entorno de base de datos del proyecto **SECOP Integrado**: PostgreSQL 18.6, DBeaver, Python y la conexión con la fuente de datos.

| Campo | Valor |
|---|---|
| **Proyecto** | SECOP Integrado — base relacional de contratación pública de Colombia |
| **Fuente de datos** | [SECOP Integrado](https://www.datos.gov.co/Estad-sticas-Nacionales/SECOP-Integrado/rpmr-utcd) · Socrata ID `rpmr-utcd` |
| **Volumen a cargar** | **16.025.993 registros** · ~19,71 GiB en CSV |
| **Motor** | PostgreSQL 18.6 en `localhost:5432` |
| **Cliente SQL** | DBeaver Community 26.2.0 (instalación por usuario) |
| **Scripts** | Python 3.14.5 |
| **Responsable** | **José** — ETL / Administrador de PostgreSQL |
| **Requerimientos que cubre** | RF-01 a RF-05, RNF-01 a RNF-04, RNF-07, RNF-10 |

---

## 1. Estado actual verificado del entorno

Todas las cifras de esta sección se leyeron de la máquina el **26 de septiembre de 2026**. No son supuestos.

### 1.1 Hardware y sistema

| Recurso | Valor medido | Impacto en el proyecto |
|---|---:|---|
| RAM total | **15,3 GB** | Define `shared_buffers` (§3.2) |
| RAM libre en el momento de la medición | 4,6 GB | **Atención:** hay ~10 GB en uso por otros procesos |
| Núcleos lógicos | **12** | Define paralelismo y workers |
| Disco `C:` libre | **128,4 GB** de 476 GB | Alcanza para 19,71 GiB de CSV + ~26 GiB de BD |
| Directorio de datos de PostgreSQL ya ocupado | **21,95 GB** | Suma al presupuesto: ~48 GB en total |

### 1.2 PostgreSQL

| Elemento | Valor verificado |
|---|---|
| Versión | `psql (PostgreSQL) 18.6` |
| Servicio | `postgresql-x64-18` — **Running**, inicio **Automatic** |
| Puerto | `5432` |
| Escuchando en | `::` y `0.0.0.0` — ver §1.4 |
| Directorio de datos | `C:\Program Files\PostgreSQL\18\data` |
| Autenticación | `scram-sha-256` (local, `127.0.0.1/32`, `::1/128`) |
| Accesible desde | `127.0.0.1` y `::1` únicamente |

**`psql` NO está en el PATH.** Invocarlo con la ruta completa:

```
C:\Program Files\PostgreSQL\18\bin\psql.exe
```

### 1.2.1 Bases de datos existentes en el clúster

Leídas con `SELECT ... FROM pg_database` el 26/09/2026:

| Base de datos | Codificación | `datcollate` | Notas |
|---|---|---|---|
| `placsp_contratacion` | UTF8 | `es_ES.UTF-8` | **Proyecto anterior. No tocar.** |
| `postgres` | UTF8 | `Spanish_Spain.1252` | Base de administración del superusuario |
| `template0` | UTF8 | `Spanish_Spain.1252` | Plantilla sin conexiones, la que se usa para crear bases con codificación propia |
| `template1` | UTF8 | `Spanish_Spain.1252` | Plantilla estándar |

⚠️ El clúster se creó con intercalación **`Spanish_Spain.1252`**, que es la de Windows, no una de Linux. El proyecto SECOP usa base propia (`secop_dw`) y **no debe mezclarse** con `placsp_contratacion`.

El clúster tiene **883 collations ICU** disponibles (proveedor `icu`), entre ellas `es-CO-x-icu`, `es-419-x-icu` y `es-x-icu`. Ver §4.2.

### 1.3 Parámetros actuales — la brecha que hay que cerrar

Este es el punto más importante de la guía. PostgreSQL está instalado **con los valores por defecto de fábrica**, que no sirven para una carga masiva de 20 GiB.

| Parámetro | Valor actual | Valor recomendado | Por qué importa |
|---|---:|---:|---|
| `shared_buffers` | **128 MB** | **4 GB** | Es el defecto crítico. Con 128 MB PostgreSQL va a disco en cada lectura y la carga de 22,67M filas se multiplica en tiempo |
| `work_mem` | 4 MB | **64 MB** | Sin esto, un `ORDER BY` o un `GROUP BY` sobre 22,67M filas usa archivos temporales en disco |
| `maintenance_work_mem` | 64 MB | **1 GB** | Acelera `CREATE INDEX`, `VACUUM` y la creación de las 30 particiones |
| `effective_cache_size` | 4 GB | **10 GB** | Le dice al planificador cuánto puede esperar en caché del sistema operativo |
| `max_wal_size` | **1 GB** | **4 GB** | Con 1 GB los checkpoints se disparan constantemente durante la carga |
| `min_wal_size` | 80 MB | **1 GB** | Evita el crecimiento y la reducción cíclica del WAL |
| `max_connections` | 100 | 100 *(sin cambio)* | Suficiente: descarga con 4 hilos + DBeaver + consultas |
| `listen_addresses` | **`*`** | `localhost` | Ver §1.4 |
| `random_page_cost` | 4.0 | **1.1** | La unidad es un SSD, no un disco rotacional |
| `effective_io_concurrency` | 16 | **200** | En Windows el default ya es 16; 200 aprovecha mejor el SSD |
| `max_parallel_workers` | 8 | **6** | Para los `GROUP BY` analíticos de RF-07 a RF-13. Bajar de 8 a 6 deja margen para DBeaver |
| `max_parallel_workers_per_gather` | 2 | **2** | Ya está en el valor recomendado |
| `default_statistics_target` | 100 | **200** | Mejor estimado para las 20 dimensiones |
| `checkpoint_completion_target` | 0.9 | 0.9 *(sin cambio)* | Ya está en el valor recomendado |
| `wal_compression` | off | **on** | Ahorra I/O de WAL durante la carga |
| `log_min_duration_statement` | -1 *(desactivado)* | **5000** | Registra solo consultas lentas (>5 s), para validar RNF-02 |
| `autovacuum_vacuum_scale_factor` | 0.2 *(default)* | **0.05** | La tabla se crea y se llena de una vez: el default no basta para 22,67M filas |
| `autovacuum_analyze_scale_factor` | 0.2 *(default)* | **0.02** | Actualiza las estadísticas del planificador tras la carga |

Los 17 valores se leyeron con `SELECT ... FROM pg_settings` el 26/09/2026. Los que aparecen como *default* no están escritos en `postgresql.conf`; se pueden fijar de todos modos para dejar el criterio explícito y auditable.

### 1.4 Seguridad: `listen_addresses = '*'`

El servidor acepta conexiones desde **cualquier interfaz de red del equipo**, no solo de `localhost`. Como el puerto 5432 escucha en `0.0.0.0` y en `::`, otra máquina de la red podría alcanzar el puerto.

`pg_hba.conf` **sí** está bien configurado: solo admite `127.0.0.1` y `::1`, con `scram-sha-256`. Pero la defensa se apoya en una sola capa.

**Corrección recomendada** en `postgresql.conf`:

```
listen_addresses = 'localhost'
```

Esto mantiene el acceso de DBeaver, `psql` y Python — que corren en la misma máquina — y cierra el puerto a la red. Se aplica en el §4, que requiere reiniciar el servicio.

### 1.5 DBeaver

| Elemento | Valor verificado |
|---|---|
| Ruta de instalación | `C:\Users\Usuario\AppData\Local\DBeaver\dbeaver.exe` |
| Tipo de instalación | Por usuario (no está en `C:\Program Files`) |
| Java requerido | **21** (`-Dosgi.requiredJavaVersion=21`) |
| Codificación de archivos | UTF-8 |
| Memoria JVM máxima | **`-Xmx1024m`** — ver §5.2 |

### 1.6 Python

| Elemento | Valor verificado |
|---|---|
| Versión | **Python 3.14.5** |
| Ruta | `C:\Users\Usuario\AppData\Local\Programs\Python\Python314` |
| pip | 26.1.1 |

### 1.7 Fuente de datos

| Elemento | Valor verificado |
|---|---|
| Host que **funciona** | `www.datos.gov.co` |
| Host que **no resuelve** | `api.datos.gov.co` — no usar |
| Identificador del dataset | `rpmr-utcd` |
| Conteo en vivo | **16.025.993** |
| Conteo en la ficha web | 20.800.218 — **desfasado en 1.869.810, no usar** |
| Formato de descarga | JSON paginado sobre `/resource/` |
| Compresión | El endpoint `/api/views/.../rows.csv?accessType=DOWNLOAD` **no admite gzip** |

---

## 2. Requisitos previos

Antes de empezar, verifica que se cumple todo esto:

- [ ] PostgreSQL 18.6 instalado y el servicio `postgresql-x64-18` en **Running**.
- [ ] Conoces la contraseña del usuario `postgres` (la que definiste al instalar). **No está en este repositorio** — es tuya, no la compartas por chat ni la versiones.
- [ ] Python 3.14.5 disponible.
- [ ] DBeaver instalado y arranca correctamente.
- [ ] Al menos **60 GB libres** en `C:` para la carga completa. Verificado: 128,4 GB. ✅
- [ ] Cerradas las aplicaciones pesadas antes de cargar (navegador, Excel, IDE). La RAM libre bajó a 4,6 GB durante la medición.

Comprobar el servicio desde PowerShell:

```powershell
Get-Service -Name "postgresql-x64-18"
```

Comprobar que el puerto responde:

```powershell
& "C:\Program Files\PostgreSQL\18\bin\pg_isready.exe" -h localhost -p 5432
```

Debería responder `localhost:5432 - accepting connections`.

---

## 3. Configuración de PostgreSQL

### 3.1 Editar `postgresql.conf`

El archivo está en `C:\Program Files\PostgreSQL\18\data\postgresql.conf`. **Editarlo como Administrador** (la carpeta `Program Files` lo exige).

Dos formas de aplicarlo. **Opción recomendada:** al final del archivo se agrega un bloque que sobrescribe los valores por defecto, de modo que el archivo original queda intacto y auditable.

```conf
# ============================================================
# SECOP Integrado - tuning para carga de 16.025.993 filas
# Aplicado: 26/09/2026 - responsable: Jose (ETL)
# Justificación de cada valor en docs/instalacion-postgresql-dbeaver.md
# ============================================================

# --- Memoria ---
shared_buffers = 4GB
work_mem = 64MB
maintenance_work_mem = 1GB
effective_cache_size = 10GB

# --- WAL y checkpoints (carga masiva) ---
max_wal_size = 4GB
min_wal_size = 1GB
checkpoint_completion_target = 0.9
wal_compression = on

# --- Planificador (SSD, no rotacional) ---
random_page_cost = 1.1
effective_io_concurrency = 200
default_statistics_target = 200

# --- Paralelismo ---
max_worker_processes = 8
max_parallel_workers = 6
max_parallel_workers_per_gather = 2

# --- Red: solo local (ver seccion 1.4) ---
listen_addresses = 'localhost'
port = 5432
max_connections = 100

# --- Diagnostico: registra consultas que tardan mas de 5 s (RNF-02) ---
log_min_duration_statement = 5000

# --- Autovacuum: la tabla se crea y se llena de una vez ---
autovacuum_vacuum_scale_factor = 0.05
autovacuum_analyze_scale_factor = 0.02
```

**Sobre `shared_buffers = 4GB`:** es el valor de RNF-03. Con 15,3 GB de RAM es correcto (25%), pero solo si cierras las demás aplicaciones antes de reiniciar. Si al arrancar PostgreSQL el sistema empieza a usar el archivo de intercambio, baja a `2GB` y anota la desviación.

**Sobre `work_mem = 64MB`:** se multiplica por las operaciones simultáneas de cada conexión. Con 4 hilos de descarga más DBeaver más una consulta analítica, el pico puede llegar a 6-7 conexiones. `7 × 64 MB = 448 MB`, dentro del presupuesto. Si se abre DBeaver en varias pestañas con consultas pesadas, baja a `32MB`.

### 3.2 Verificar la memoria antes de reiniciar

```powershell
$os = Get-CimInstance Win32_OperatingSystem
"RAM libre: {0:N1} GB" -f ($os.FreePhysicalMemory/1MB)
```

Si baja de **5 GB**, cerrá aplicaciones antes de continuar.

### 3.3 Reiniciar el servicio

Los cambios de `shared_buffers`, `work_mem` y `listen_addresses` requieren **reiniciar**, no solo recargar.

Como Administrador en PowerShell:

```powershell
Restart-Service -Name "postgresql-x64-18"
Start-Sleep -Seconds 5
Get-Service -Name "postgresql-x64-18"
& "C:\Program Files\PostgreSQL\18\bin\pg_isready.exe" -h localhost -p 5432
```

### 3.4 Confirmar que los cambios entraron

```powershell
$env:PGPASSWORD = "<tu contraseña>"
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U postgres -h localhost -d postgres -c "SHOW shared_buffers;"
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U postgres -h localhost -d postgres -c "SHOW work_mem;"
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U postgres -h localhost -d postgres -c "SHOW listen_addresses;"
```

Debe responder `4GB`, `64MB` y `localhost` respectivamente.

> ⚠️ **Nunca** escribas la contraseña en un archivo `.sql`, en un `.py` ni en este repositorio. Usa la variable de entorno `PGPASSWORD` o el archivo `.pgpass`. RNF-10 lo exige.

---

## 4. Crear el rol y la base de datos

### 4.1 Rol de la aplicación

El usuario `postgres` es el superusuario: no debe usarse para las consultas del día a día ni para la carga. Crear un rol dedicado.

```sql
-- Sin clave: se asigna después, oculta, con \password de psql
CREATE ROLE secop_etl     WITH LOGIN;
CREATE ROLE secop_lectura WITH LOGIN;

\password secop_etl
\password secop_lectura
```

> **Por qué `\password` y no `PASSWORD 'CLAVE'` en el comando.** La forma con la clave escrita dentro del `CREATE ROLE` es la que aparece en muchas guías, pero eso deja la clave en un archivo versionado, que es justo lo que RNF-10 prohíbe. `\password` de `psql` la pide de forma oculta en la terminal: no pasa por ningún archivo ni por el historial del shell. `sql/00_instalacion.sql` ya usa este mecanismo.
>
> Si la clave se filtra, se cambia sin volver a correr todo: `ALTER ROLE secop_etl PASSWORD 'NUEVA';`

### 4.2 Base de datos con la codificación correcta

**RNF-07** exige UTF-8. La intercalación de la base define cómo se ordenan y comparan los textos, y **se fija al crearla**: cambiarla después obliga a recrear la base entera. Por eso la decisión se toma ahora, no después de cargar 20 GiB.

```sql
CREATE DATABASE secop_dw
    ENCODING 'UTF8'
    LC_COLLATE 'es-CO-x-icu'
    LC_CTYPE  'es-CO-x-icu'
    TEMPLATE   template0;
```

> **`LOCALE` se omite a propósito.** Al fijar `LC_COLLATE` y `LC_CTYPE` de forma explícita, agregar `LOCALE` en el mismo comando es redundante y PostgreSQL lo rechaza. La versión ejecutable de todo este bloque está en **[sql/00_instalacion.sql](../sql/00_instalacion.sql)**, que además crea los roles, la collation y los esquemas. Ejecutar ese archivo es preferible a copiar estos fragmentos a mano: se puede re-ejecutar sin romper nada.

**Por qué `es-CO-x-icu` y no `C`.** La diferencia se midió con los nombres de departamento reales del SECOP:

| Intercalación | Resultado del `ORDER BY` |
|---|---|
| `C` | `... Cesar | Chocó | **Cundinamarca | Córdoba** | Distrito Capital...` |
| `es-CO-x-icu` | `... Cesar | Chocó | **Córdoba | Cundinamarca** | Distrito Capital...` |

Con `C` el orden es por bytes, así que `Córdoba` queda **después** de `Cundinamarca` (la `ó` vale más que la `u`). Con `es-CO-x-icu` el orden alfabético es el correcto en español. Para un proyecto colombiano cuyas dimensiones se llaman "Nariño", "Córdoba" y "Chocó", eso importa en cada lista, cada mapa y cada `TOP N` de Power BI.

> El nombre correcto es **`es-CO-x-icu`**. Escribir `es-CO` a secas **falla** con el error `no existe el ordenamiento «es-CO» para la codificación «UTF8»`, verificado en este clúster.

### 4.2.1 La collation NO resuelve los duplicados por mayúsculas

Este es un resultado medido que cambia el diseño del ETL, y conviene dejarlo escrito antes de que alguien asuma lo contrario.

Se probaron tres opciones contra las variantes que existen en el origen:

| Comparación | `C` | `es-CO-x-icu` | ICU no determinista (fuerza por defecto) |
|---|---|---|---|
| `'Norte De Santander' = 'Norte de Santander'` | `false` | `false` | `false` |
| `'Bogotá D.C.' = 'BOGOTÁ D.C.'` | `false` | `false` | `false` |

**Las tres fallan.** La intercalación define el orden y la comparación, pero no ignora las mayúsculas salvo que se configure una ICU no determinista con fuerza secundaria:

```sql
CREATE COLLATION secop_ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
```

Probado en este clúster:

| Comparación con `secop_ci` | Resultado | Interpretación |
|---|---|---|
| `'Norte De Santander' = 'Norte de Santander'` | **`true`** | ✅ Fusión correcta |
| `'Bogotá D.C.' = 'BOGOTÁ D.C.'` | **`true`** | ✅ Fusión correcta |
| `'Prestación de Servicios' = 'prestación de servicios'` | **`true`** | ✅ Exactamente el duplicado de RF-05 |
| `'Nariño' = 'NARINO'` | **`false`** | ✅ Correcto: los acentos se respetan, no se fusionan nombres distintos |

La fuerza secundaria ignora mayúsculas pero **respeta los acentos**, que es justo lo que se necesita: `Nariño` y `Narino` no deben fusionarse.

**Recomendación para RF-05:** aplicar `COLLATE secop_ci` **solo en las tablas de dimensión** (`dim_departamento`, `dim_tipo_contrato`, `dim_modalidad`, `dim_estado`, `dim_nivel_entidad`), que son pequeñas. **No** aplicarla a la tabla de hechos de 22,67M filas: no aporta nada ahí y penaliza el `GROUP BY`.

**Limitación conocida:** las collations no deterministas **no funcionan con `LIKE` ni `ILIKE`** (verificado: `'Bogotá' LIKE 'bogot%'` devuelve `false`). Si el ETL necesita búsquedas con comodines, hay que normalizar antes con `initcap(trim(...))` en lugar de apoyarse en la collation.

### 4.2.2 Verificar la base creada

```sql
SELECT datname, pg_encoding_to_char(encoding) AS codificacion, datcollate, datctype
FROM pg_database
WHERE datname = 'secop_dw';
```

Debe mostrar `UTF8`, `es-CO-x-icu` y `es-CO-x-icu`.

### 4.3 Collation no determinista de RF-05

La §4.2.1 explica por qué hace falta. Este es el comando:

```sql
CREATE COLLATION secop_ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
```

Se crea en `secop_dw`, dentro del esquema `public` (donde la deja el `search_path`), para poder escribir `COLLATE secop_ci` sin calificar en el DDL de las dimensiones. Requiere ICU, que este clúster tiene disponible (883 collations, §1.2.1).

⚠️ El §8 la verifica, pero antes no había ningún comando que la creara: faltaba este paso. Ya está corregido y está en `sql/00_instalacion.sql`.

### 4.4 Esquemas Medallion

```sql
\c secop_dw

CREATE SCHEMA bronze  AUTHORIZATION secop_etl;   -- dato crudo
CREATE SCHEMA silver   AUTHORIZATION secop_etl;
CREATE SCHEMA gold     AUTHORIZATION secop_etl;
CREATE SCHEMA logs     AUTHORIZATION secop_etl;

GRANT CONNECT ON DATABASE secop_dw TO secop_etl, secop_lectura;
GRANT USAGE ON SCHEMA gold TO secop_lectura;

-- OJO: el FOR ROLE secop_etl es obligatorio. Sin él, este GRANT se aplica solo
-- a las tablas que cree postgres, y las de gold las crea secop_etl: Power BI
-- se quedaría sin ver ninguna.
ALTER DEFAULT PRIVILEGES FOR ROLE secop_etl IN SCHEMA gold
    GRANT SELECT ON TABLES TO secop_lectura;
```

El `ALTER DEFAULT PRIVILEGES` es importante: hace que **toda tabla futura** en `gold` sea legible por Power BI sin tener que repetir el `GRANT`. Y el `FOR ROLE secop_etl` es lo que lo hace funcionar: un `ALTER DEFAULT PRIVILEGES` sin `FOR ROLE` aplica a los objetos del rol **que ejecuta el script** (`postgres`), no a los de `secop_etl`. Sin ese calificador, las tablas de `gold` —que crea `secop_etl`— no serían visibles para Power BI.

Tampoco se concede nada sobre `bronze`, `silver` y `logs`: un esquema recién creado no da privilegios a `PUBLIC`, así que `secop_lectura` ni siquiera ve que existen.

### 4.5 Verificar

```sql
SELECT datname, pg_encoding_to_char(encoding) AS codificacion, datcollate
FROM pg_database
WHERE datname = 'secop_dw';
```

Debe mostrar `UTF8` y `es-CO-x-icu`.

---

## 5. Configurar DBeaver

### 5.1 Crear la conexión

1. Abrir `C:\Users\Usuario\AppData\Local\DBeaver\dbeaver.exe`.
2. **Base de datos → Nueva conexión de base de datos** → **PostgreSQL**.
3. Llenar:

| Campo | Valor |
|---|---|
| Nombre de la conexión | `SECOP Integrado` |
| Host | `localhost` |
| Puerto | `5432` |
| Base de datos | `secop_dw` |
| Usuario | `secop_etl` |
| Contraseña | *(la que definiste en §4.1)* |
| Autenticación | **Native** / SCRAM-SHA-256 |

4. **Probar conexión**. Debe aparecer `Connected`.
5. Guardar.

> Usa `secop_etl` para trabajar. Guarda `secop_lectura` como segunda conexión para replicar exactamente los permisos que verá Power BI, que es la forma de detectar problemas de privilegios antes de construir el tablero.

### 5.2 Aumentar la memoria de la JVM

DBeaver arranca con `-Xmx1024m` (1 GB), verificado en su `dbeaver.ini`. Con 15,3 GB de RAM, **1 GB es insuficiente** para manipular resultados de agregaciones sobre 22,67M filas.

Cerrar DBeaver completamente. Editar `C:\Users\Usuario\AppData\Local\DBeaver\dbeaver.ini` y cambiar:

```
-Xms64m
-Xmx1024m
```

por:

```
-Xms256m
-Xmx3072m
```

**Justificación:** la RAM total es 15,3 GB y ya hay 4 GB comprometidos con `shared_buffers`. Reservar 3 GB para el cliente deja margen para el sistema operativo. **Si al usar DBeaver el equipo empieza a intercambiar memoria, vuelve a `-Xmx2048m`.**

> El valor `-Xmx` mayor que la RAM disponible no acelera nada: hace que Windows intercambie. Nunca pongas `-Xmx` por encima de lo que la máquina puede dar.

### 5.3 Configuración de la cuadrícula

Para que DBeaver no intente traer 22,67M filas a la pantalla:

En DBeaver, **Editar → Preferencias → Editor SQL → Editor** → desmarca **"Cargar datos al seleccionar"**.
2. En la pestaña de resultados, botón derecho → **Configuración** → **Límite de filas** = `10000`.
3. **Preferencias → Editors → Editors de resultados** → **Resultados máximos** = `10000`.

Con esto, un `SELECT` accidental sobre la tabla completa devuelve las primeras 10.000 filas y no congela DBeaver.

---

## 6. Preparar el entorno de Python

### 6.1 Entorno virtual

Nunca instalar paquetes en el Python global. Crear un entorno dentro del proyecto (ya está en `.gitignore`):

```powershell
cd C:\Users\Usuario\Documents\Github\SECOP
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
```

### 6.2 Dependencias

```powershell
pip install psycopg[binary] requests python-dotenv
```

| Paquete | Para qué |
|---|---|
| `psycopg[binary]` | Driver PostgreSQL 3, necesario para `COPY FROM STDIN` de RF-02 |
| `requests` | Descarga paginada de la API (RF-01) |
| `python-dotenv` | Leer credenciales de `.env` (RNF-10) |

### 6.3 Archivo `.env` (no se versiona)

Crear `.env` en la raíz del proyecto. **Nunca** se sube al repositorio; `.gitignore` ya lo excluye.

```
PGHOST=localhost
PGPORT=5432
PGDATABASE=secop_dw
PGUSER=secop_etl
PGPASSWORD=tu_clave_aqui
SOCRATA_ID=rpmr-utcd
SOCRATA_HOST=www.datos.gov.co
LOTE_FILAS=250000
HILOS_DESCARGA=4
```

Para que quede de ejemplo sin la clave real, crear también `.env.example` con el mismo contenido pero `PGPASSWORD=` vacío. Ese sí se versiona.

---

## 7. Descarga y carga (referencia rápida)

Esta sección resume el procedimiento; el desarrollo completo va en `etl_carga.md` (Entregables 3 y 4, **José**).

### 7.1 Por qué no se descarga el archivo completo

El endpoint oficial entrega los 19,71 GiB **sin compresión** y a una velocidad medida de **0,5 – 1,2 MB/s**, o sea entre 4 y 10 horas de espera. La API paginada `/resource/` con 4 conexiones en paralelo baja ese tiempo a menos de 90 minutos (RNF-01).

```powershell
# Probar el endpoint paginado con 5 filas
$u = "https://www.datos.gov.co/resource/rpmr-utcd.json?`$limit=5&`$offset=0"
(Invoke-RestMethod -Uri $u -TimeoutSec 60) | Format-Table
```

> En PowerShell el `$` de SoQL debe escaparse con backtick (`` `$ ``). En Python no hace falta.

### 7.2 Secuencia de la carga

```text
1. bronze.secop_raw         -> COPY FROM STDIN, dato crudo del origen
2. silver.contratos        -> tipificado, deduplicado y normalizado (R1-R9)
3. plata no tiene dimensiones; las 7 de oro van en 02_modelo_gold.sql
4. gold.fact_contrato      -> tabla de hechos particionada por anio
5. indices + VACUUM ANALYZE
6. verificacion plata: 42/42 pruebas (sql/ETL/05_qa_silver.sql)
```

Los archivos van numerados en `sql/`, y los del pipeline vigente en `sql/ETL/`. Los del modelo retirado quedaron en `sql/retirado/`.

### 7.3 Monitorear la carga

Con DBeaver abierta en una segunda pestaña, o desde PowerShell:

```sql
SELECT pid, state, wait_event_type, wait_event,
       now() - query_start AS duracion,
       left(query, 80) AS consulta
FROM pg_stat_activity
WHERE datname = 'secop_dw'
ORDER BY query_start;
```

`wait_event = ClientWriteRead` durante mucho tiempo es normal en `COPY`: significa que va bien y esperando al siguiente lote.

---

## 8. Verificar que el entorno quedó operativo

Ejecutar esta lista al final de la instalación. Todo debe responder correctamente.

```sql
-- 1. Version
SELECT version();

-- 2. Codificacion e intercalacion de la base
SELECT datname, pg_encoding_to_char(encoding) AS codificacion, datcollate, datctype
FROM pg_database WHERE datname='secop_dw';

-- 3. Parametros de tuning aplicados
SELECT name, setting, unit FROM pg_settings
WHERE name IN ('shared_buffers','work_mem','maintenance_work_mem','effective_cache_size',
               'max_wal_size','min_wal_size','random_page_cost','listen_addresses',
               'max_parallel_workers','wal_compression','log_min_duration_statement')
ORDER BY name;

-- 4. Los 4 esquemas Medallion existen
SELECT schema_name FROM information_schema.schemata
WHERE schema_name IN ('bronze','silver','gold','logs') ORDER BY 1;

-- 5. La collation no determinista de RF-05
SELECT collname, collprovider FROM pg_collation WHERE collname = 'secop_ci';

-- 6. Privilegios de lectura para Power BI
SELECT has_schema_privilege('secop_lectura','gold','USAGE') AS puede_leer_gold;

-- 7. Espacio en disco
SELECT pg_size_pretty(pg_database_size('secop_dw')) AS tamano_actual;
```

Criterio de éxito:

| # | Verificación | Resultado esperado |
|---|---|---|
| 1 | `version()` | `PostgreSQL 18.6` |
| 2 | Codificación / intercalación | `UTF8` / `es-CO-x-icu` |
| 3 | `shared_buffers` | `4GB` |
| 3 | `work_mem` | `64MB` |
| 3 | `listen_addresses` | `localhost` |
| 4 | Esquemas | 4 filas: `bronze`, `gold`, `logs`, `silver` |
| 5 | Collation RF-05 | 1 fila: `secop_ci` |
| 6 | Privilegios | `t` |
| 7 | Tamaño | vacío o muy pequeño antes de cargar; **~11–26 GiB** después |

**Estado al 26/09/2026:** la conexión funciona y el clúster responde. Los puntos 2 a 7 **todavía no se cumplen** porque la base `secop_dw` aún no se ha creado. Los valores de `pg_settings` son los de fábrica descritos en §1.3.

---

## 9. Problemas frecuentes

| Síntoma | Causa | Solución |
|---|---|---|
| `fe_sendauth: no password supplied` | Falta la clave | `psql` la pide si no hay `PGPASSWORD` ni `.pgpass` |
| `password authentication failed for user "postgres"` | Clave incorrecta | Verifica la clave; **no** la adivines. `pg_hba.conf` usa `scram-sha-256` |
| `could not translate host name "api.datos.gov.co"` | Ese host no resuelve | Usa **`www.datos.gov.co`** |
| El conteo da 20.800.218 | Leíste la ficha web | La metadata está desfasada 1.869.810. Contá por API (§1.7) |
| `server does not support gzip` en la descarga | El endpoint `rows.csv` no comprime | Bajá por `/resource/` paginado y comprimí vos mismo |
| `FATAL: remaining connection slots...` | `max_connections` agotado | 100 es suficiente; si falla, cerrá conexiones de DBeaver |
| La carga va muy lenta | `shared_buffers` sin aplicar | El valor por defecto es 128 MB. Revisá §3.1 y reiniciá el servicio |
| `could not resize shared memory segment` | `work_mem` × conexiones excede la RAM | Bajá `work_mem` a `32MB` (§3.1) |
| El equipo se pone lento al cargar | `shared_buffers` 4 GB + DBeaver 3 GB + Windows | Cerrá aplicaciones; si persiste, `shared_buffers = 2GB` |
| DBeaver se congela con un `SELECT` | Intentó traer 22,67M filas | Aplicá §5.3 (límite de 10.000 filas) |
| `invalid input syntax for type date` | Hay 106 fechas en años futuros y 1.767.413 nulas | Aplicá `es_fecha_valida()` antes de convertir (RF-04) |
| El mapa muestra Bogotá dos veces | Hay 38 valores de departamento, 3 pares por unificar | Normalizá antes de construir la dimensión (RF-05) y usá `COLLATE secop_ci` (§4.2.1) |
| `no existe el ordenamiento «es-CO»` | Nombre de collation incorrecto | Usá **`es-CO-x-icu`**, con el sufijo (verificado en este clúster) |
| `'Norte De Santander' = 'Norte de Santander'` devuelve `false` | La collation no ignora mayúsculas | Aplicá `COLLATE secop_ci` en las dimensiones, o normalizá con `initcap(trim(...))` (§4.2.1) |
| `nondeterministic collations are not supported for LIKE` | Las collations no deterministas no sirven con comodines | Normalizar en el ETL antes de buscar con `LIKE` |
| `No password supplied` desde Python | Falta `.env` o la variable | Verifica §6.3 y que `python-dotenv` esté instalado |
