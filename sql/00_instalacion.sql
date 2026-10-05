-- =============================================================================
-- 00_instalacion.sql — SECOP Integrado
-- Creacion de roles, base de datos, collation y esquemas Medallion.
-- =============================================================================
-- Fuente de datos  : SECOP Integrado (Socrata ID rpmr-utcd) — CC BY-SA 4.0
-- Motor            : PostgreSQL 18.6 en localhost:5432
-- Responsabile     : Jose (ETL / Administrador de PostgreSQL)
-- Requisitos       : RNF-07 (codificacion e intercalacion regional)
--                    RNF-10 (mantenibilidad, credenciales fuera del repo)
-- Referencia       : docs/instalacion-postgresql-dbeaver.md, secciones 4 y 8
-- Aplicado         : 27/09/2026
--
-- -----------------------------------------------------------------------------
-- COMO EJECUTAR
-- -----------------------------------------------------------------------------
--   cd C:\Users\Usuario\Documents\Github\SECOP
--   $env:PGCLIENTENCODING = "UTF8"
--   & "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U postgres -h localhost -d postgres -i sql\00_instalacion.sql
--
-- El script pide la clave de `postgres`, despues la de `secop_etl` y la de
-- `secop_lectura` de forma oculta. Ninguna clave queda escrita en un archivo
-- versionado ni en el historial del shell (RNF-10).
--
-- El script es RE-EJECUTABLE: se puede correr las veces que haga falta sin
-- romper nada. Los roles, la base, la collation y los esquemas solo se crean
-- si no existen.
--
-- -----------------------------------------------------------------------------
-- POR QUE ESTE SCRIPT Y NO EL DIALOGO "CREATE DATABASE" DE DBEAVER
-- -----------------------------------------------------------------------------
-- 1. La intercalacion (LC_COLLATE / LC_CTYPE) se FIJA al crear la base y no se
--    puede cambiar despues. Cambiarla obliga a recrear la base entera con sus
--    16.025.993 filas en bronce. El dialogo de DBeaver no expone esos dos campos.
-- 2. El cluster se creo con intercalacion Spanish_Spain.1252 (la de Windows),
--    no una de Linux. Por eso la base se crea desde TEMPLATE template0 en vez
--    de template1.
-- 3. CREATE DATABASE no puede ejecutarse dentro de una transaccion, y DBeaver
--    al ejecutar un script puede envolverlo en una. Con psql cada sentencia
--    va en autocommit.
-- 4. Que quede en un archivo versionado es la evidencia de reproducibilidad
--    que exigen RNF-09 y el Entregable 3.
--
-- -----------------------------------------------------------------------------
-- INTERCALACION: es-CO-x-icu  (NO usar la intercalacion C)
-- -----------------------------------------------------------------------------
-- El nombre correcto es "es-CO-x-icu", CON el sufijo. Escribir "es-CO" a
-- secas falla con: no existe el ordenamiento "es-CO" para la codificacion UTF8.
-- (Verificado en este cluster el 26/09/2026.)
--
-- Con la intercalacion C, que ordena por bytes, un ORDER BY sobre la dimension
-- de departamentos devuelve:
--     ... Cesar | Choco | Cundinamarca | Cordoba | Distrito Capital ...
-- o sea, "Cordoba" queda DESPUES de "Cundinamarca" porque la "o" acentuada
-- ordena despues que la "u". Con es-CO-x-icu el orden alfabetico en espanol
-- es el correcto. Para un proyecto colombiano con dimensiones llamadas
-- "Nariño", "Cordoba" y "Choco" eso importa en cada lista, cada mapa y cada
-- TOP N de Power BI. (Medido en docs/instalacion-postgresql-dbeaver.md §4.2)
-- =============================================================================

\set ON_ERROR_STOP on
\timing off

\echo ''
\echo '###############################################################'
\echo '# SECOP Integrado — instalacion de base de datos'
\echo '###############################################################'
\echo ''

-- =============================================================================
-- 1. Roles de aplicacion
-- =============================================================================
-- Se crean SIN clave: la clave se asigna en el paso 1b con \password, que la
-- pide de forma oculta. Asi la clave nunca pasa por un archivo ni por la linea
-- de comandos.
-- =============================================================================

\echo '--- [1/6] Roles secop_etl y secop_lectura ---'

DO $roles$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'secop_etl') THEN
        CREATE ROLE secop_etl WITH LOGIN;
        RAISE NOTICE 'Rol secop_etl creado (aun sin clave)';
    ELSE
        RAISE NOTICE 'Rol secop_etl ya existe';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'secop_lectura') THEN
        CREATE ROLE secop_lectura WITH LOGIN;
        RAISE NOTICE 'Rol secop_lectura creado (aun sin clave)';
    ELSE
        RAISE NOTICE 'Rol secop_lectura ya existe';
    END IF;
END
$roles$;

-- -----------------------------------------------------------------------------
-- 1b. Claves de los roles
-- -----------------------------------------------------------------------------
-- Hay dos caminos, y el script elige solo:
--
--   INTERACTIVO (el normal para el equipo) — no hay nada que configurar.
--   \password pide el valor de forma oculta y lo confirma. Al no pasar por un
--   archivo ni por la linea de comandos, la clave no queda en ningun lado
--   (RNF-10).
--
--   AUTOMATIZADO — para correr el script sin terminal (CI, agente).
--   Definir en el entorno del proceso, NO en la linea de comandos:
--       $env:SECOP_PW_AUTO = "1"
--       $env:SECOP_PW_ETL = "<clave de secop_etl>"
--       $env:SECOP_PW_RO  = "<clave de secop_lectura>"
--   Van por entorno y no por -v a proposito: los argumentos de la linea de
--   comandos son visibles para cualquier proceso del usuario mientras corren.
--   La clave de superusuario va en PGPASSWORD por la misma razon.
--
-- \getenv deja la variable SIEMPRE definida (vacia si el entorno no la tiene),
-- de modo que la rama descartada no puede fallar al expandirse.
--
-- Para cambiar una clave despues, sin volver a correr todo el script, desde la
-- base postgres:
--
--     ALTER ROLE secop_etl PASSWORD 'CLAVE_NUEVA';
--
-- Si el script se ejecuta con redireccion de entrada (psql < archivo.sql) y sin
-- las variables de entorno, \password no tiene de donde leer y falla: en ese
-- caso hay que asignar las claves a mano, como en la linea de arriba.
-- -----------------------------------------------------------------------------

\getenv pw_etl SECOP_PW_ETL
\getenv pw_ro  SECOP_PW_RO

\if :{?SECOP_PW_AUTO}
    \echo 'Asignando claves desde las variables de entorno del proceso.'
    ALTER ROLE secop_etl PASSWORD :'pw_etl';
    ALTER ROLE secop_lectura PASSWORD :'pw_ro';
\else
    \echo 'Escriba la clave de secop_etl — ETL, dueno de los esquemas (oculta):'
    \password secop_etl
    \echo 'Escriba la clave de secop_lectura — solo lectura, para Power BI (oculta):'
    \password secop_lectura
\endif

\echo 'Claves asignadas.'

-- =============================================================================
-- 2. Base de datos
-- =============================================================================
-- RNF-07: UTF-8 obligatorio, intercalacion regional colombiana.
--
-- Se genera el CREATE DATABASE con \gexec en lugar de escribirlo directo para
-- poder condicionarlo a que la base no exista: eso es lo que hace el script
-- re-ejecutable. \gexec no puede ir dentro de un bloque DO justamente porque
-- eso seria una transaccion, y CREATE DATABASE esta prohibido alli.
--
-- LOCALE se omite a proposito: al fijar LC_COLLATE y LC_CTYPE explicitamente,
-- indicar LOCALE en el mismo comando es un error.
-- =============================================================================

\echo '--- [2/6] Base de datos secop_dw ---'

-- Se consulta primero si la base ya existe y se guarda el resultado en la
-- variable de psql :ya_existia, para poder avisar sin mentirse: si la base no
-- existia y este script la crea, no hay nada que avisar.
SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'secop_dw') AS ya_existia
\gset

\if :ya_existia
    \echo 'ATENCION: secop_dw YA EXISTIA. Se reutiliza tal cual.'
    \echo 'Si fue creada desde el dialogo de DBeaver, probablemente tenga la'
    \echo 'intercalacion Spanish_Spain.1252 del cluster, que no sirve. El chequeo [2]'
    \echo 'de la verificacion final lo delata. En ese caso habria que hacer'
    \echo 'DROP DATABASE secop_dw y volver a correr este script.'
\else
    \echo 'Creando secop_dw con ENCODING UTF8 y LC_COLLATE es-CO-x-icu...'
    SELECT format(
               'CREATE DATABASE secop_dw
                  ENCODING   ''UTF8''
                  LC_COLLATE ''es-CO-x-icu''
                  LC_CTYPE   ''es-CO-x-icu''
                  TEMPLATE   template0
                  OWNER      secop_etl'
           )
    \gexec
\endif

\connect secop_dw

\echo 'Conectado a secop_dw.'

-- =============================================================================
-- 3. Collation secop_ci  (SOLO para el modelo retirado, ver sql/retirado/)
-- =============================================================================
-- AVISO: el pipeline vigente NO usa esta collation. La deduplicacion de plata
-- (R1) normaliza de forma determinista, con initcap y quita de tildes, y por eso
-- la capa oro puede declarar UNIQUE en serio y no la necesita. Este bloque se
-- mantiene unicamente porque sql/retirado/01_esquema.sql la usa; si ese modelo
-- se borra del historial, este bloque se puede borrar con el.
--
-- NO va en la intercalacion de la base. Es una collation ICU NO determinista con
-- fuerza secundaria, que ignora mayusculas pero RESPETA los acentos.
--
-- Comportamiento medido en este cluster (ver docs/instalacion-postgresql-dbeaver.md
-- §4.2.1):
--     'Norte De Santander' = 'Norte de Santander'  ->  true    (fusiona, correcto)
--     'Bogota D.C.'       = 'BOGOTA D.C.'         ->  true    (fusiona, correcto)
--     'Prestacion de Servicios' = 'prestacion...'  ->  true    (es el duplicado de RF-05)
--     'Nariño'            = 'NARINO'              ->  false   (correcto: no son el mismo nombre)
--
-- Sin esto, ninguna intercalacion del cluster fusiona mayusculas: 'C' y
-- 'es-CO-x-icu' dan false en los tres primeros casos.
--
-- LIMITACION CONOCIDA: las collations no deterministas NO funcionan con LIKE ni
-- con ILIKE. Si el ETL necesita comodines, hay que normalizar antes en el ETL
-- con initcap(trim(...)) en lugar de apoyarse en la collation.
--
-- Se crea en el esquema public, que es donde la deja el search_path, para poder
-- escribir COLLATE secop_ci sin calificar en 01_esquema.sql.
-- =============================================================================

\echo '--- [3/6] Collation secop_ci ---'

DO $collation$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_collation WHERE collname = 'secop_ci') THEN
        CREATE COLLATION secop_ci (
            provider       = icu,
            locale         = 'und-u-ks-level2',
            deterministic  = false
        );
        RAISE NOTICE 'Collation secop_ci creada';
    ELSE
        RAISE NOTICE 'Collation secop_ci ya existe';
    END IF;
END
$collation$;

-- =============================================================================
-- 4. Esquemas Medallion
-- =============================================================================
-- bronze  = dato crudo, tal cual llega del origen
-- silver  = datos tipificados, deduplicados y normalizados
-- gold    = modelo en estrella, lo unico que lee Power BI
-- logs    = trazabilidad de la carga y de las consultas
--
-- AUTHORIZATION secop_etl: el dueno es el rol del ETL, no postgres. Asi el
-- esquema sobrevive a cualquier cambio de clave del superusuario.
-- =============================================================================

\echo '--- [4/6] Esquemas Medallion (bronze, silver, gold, logs) ---'

DO $esquemas$
DECLARE
    esquema text;
BEGIN
    FOREACH esquema IN ARRAY ARRAY['bronze', 'silver', 'gold', 'logs'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = esquema) THEN
            EXECUTE format('CREATE SCHEMA %I AUTHORIZATION secop_etl', esquema);
            RAISE NOTICE 'Esquema % creado', esquema;
        ELSE
            RAISE NOTICE 'Esquema % ya existe', esquema;
        END IF;
    END LOOP;
END
$esquemas$;

-- =============================================================================
-- 5. Privilegios
-- =============================================================================
-- secop_lectura existe para Power BI y para reproducir en DBeaver exactamente
-- los permisos que vera el tablero. Con ella se detectan los problemas de
-- privilegios antes de construir las visualizaciones, no despues.
--
-- IMPORTANTE — ALTER DEFAULT PRIVILEGES:
-- Un ALTER DEFAULT PRIVILEGES sin FOR ROLE se aplica a los objetos que crea
-- el ROL QUE EJECUTA EL SCRIPT, o sea postgres. Las tablas de gold las crea
-- secop_etl, no postgres, asi que sin FOR ROLE el permiso NO se aplicaria a
-- ninguna tabla y Power BI se quedaria sin ver nada. Por eso el FOR ROLE
-- secop_etl, que es explicito y no depende de quien instale la base.
-- =============================================================================

\echo '--- [5/6] Privilegios de secop_lectura sobre gold ---'

GRANT CONNECT ON DATABASE secop_dw TO secop_etl, secop_lectura;

-- gold es lo unico que consulta Power BI. En bronze, silver y logs no se
-- concede nada: un esquema recien creado no le da privilegios a PUBLIC, asi
-- que secop_lectura no ve siquiera la existencia de bronze y silver.
GRANT USAGE ON SCHEMA gold TO secop_lectura;

-- Toda tabla futura en gold nace legible por secop_lectura, sin tener que
-- repetir el GRANT SELECT en cada CREATE TABLE.
ALTER DEFAULT PRIVILEGES FOR ROLE secop_etl IN SCHEMA gold
    GRANT SELECT ON TABLES TO secop_lectura;

-- Cinturon de seguridad: esta conexion no puede escribir ni por error. Si
-- alguna vez hace falta escribir con ella, es una señal de que se esta usando
-- el rol equivocado: para eso esta secop_etl.
ALTER ROLE secop_lectura SET default_transaction_read_only = on;

\echo 'Privilegios aplicados.'

-- =============================================================================
-- 6. Verificacion
-- =============================================================================
-- Los mismos 7 chequeos de docs/instalacion-postgresql-dbeaver.md §8.
-- =============================================================================

\echo ''
\echo '--- [6/6] Verificacion ---'

\echo '[1] Version del motor:'
SELECT version();

\echo '[2] Codificacion e intercalacion de la base (esperado: UTF8 / es-CO-x-icu):'
SELECT datname,
       pg_encoding_to_char(encoding) AS codificacion,
       datcollate,
       datctype
FROM   pg_database
WHERE  datname = 'secop_dw';

\echo '[3] Los 4 esquemas Medallion (esperado: 4 filas):'
SELECT schema_name
FROM   information_schema.schemata
WHERE  schema_name IN ('bronze', 'silver', 'gold', 'logs')
ORDER  BY schema_name;

\echo '[4] Collation secop_ci de RF-05 (esperado: s / i / f):'
SELECT collname, collprovider, collisdeterministic
FROM   pg_collation
WHERE  collname = 'secop_ci';

\echo '[5] secop_lectura puede leer el esquema gold (esperado: t):'
SELECT has_schema_privilege('secop_lectura', 'gold', 'USAGE') AS puede_leer_gold;

\echo '[6] Los dos roles existen y pueden entrar (esperado: 2 filas con canlogin = t):'
SELECT rolname, rolcanlogin
FROM   pg_roles
WHERE  rolname IN ('secop_etl', 'secop_lectura')
ORDER  BY rolname;

\echo '[7] Tamano actual de la base (vacio o muy pequeno todavia, no hay datos):'
SELECT pg_size_pretty(pg_database_size('secop_dw')) AS tamano_actual;

\echo ''
\echo '### Instalacion completada.'
\echo '### Siguiente paso: configurar las conexiones en DBeaver (§5.1).'
\echo '### Ojo: falta aplicar el tuning de postgresql.conf (§3.1).'
\echo ''
