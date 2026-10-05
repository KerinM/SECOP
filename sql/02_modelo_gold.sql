-- =====================================================================
-- 02_modelo_gold.sql  ·  SECOP Integrado  ·  Entregable 2 (Kerin)
-- Capa GOLD: modelo en estrella construido desde silver.contratos.
-- =====================================================================
-- Base de datos : secop_dw
-- Lee          : silver.contratos  (13.005.402 filas, validada 42/42)
-- Escribe      : gold.dim_* y gold.fact_contrato
-- Entregable   : E2 · modelo logico de la bodega de datos
-- Documento    : docs/modelo_relacional.md
-- Requisitos   : RF-06 (modelo en estrella con PK y FK), RF-13 (vistas de
--                consumo unico para Power BI), RNF-04 (escalabilidad)
--
-- -----------------------------------------------------------------------------
-- QUE HACE ESTE SCRIPT Y QUE NO
-- -----------------------------------------------------------------------------
-- HACE   : crea las 7 dimensiones y la tabla de hechos de la capa oro.
-- NO HACE: no lee bronze, no lee silver mas alla del SELECT de carga, no
--          borra nada de plata. Jamas hace DROP sobre bronze ni silver.
--          El unico DROP es el del bloque "modo recrear", y solo toca gold.
--
-- -----------------------------------------------------------------------------
-- REJECUTABLE
-- -----------------------------------------------------------------------------
--   psql -U postgres -d secop_dw -f sql/02_modelo_gold.sql
--   psql -U postgres -d secop_dw -v recrear=1 -f sql/02_modelo_gold.sql
--
-- Sin -v recrear=1 solo crea lo que falta. Con recrear=1 borra SOLO gold y
-- lo vuelve a construir; plata y bronce quedan intactos.
-- =====================================================================

\set ON_ERROR_STOP on
\pset pager off

\if :{?recrear}
\else
    \set recrear 0
\endif

-- Lote de carga del bloque 6.2. Se puede cambiar sin tocar el script:
--     psql -v lote_desde=0 -v lote_hasta=500000 -f sql/02_modelo_gold.sql
\if :{?lote_desde}
\else
    \set lote_desde 0
\endif
\if :{?lote_hasta}
\else
    \set lote_hasta 999999999999
\endif

\if :recrear
    \echo ''
    \echo '### MODO RECREAR: se borra SOLO la capa gold. bronze y silver intactas.'
\else
    \echo ''
    \echo '### MODO NORMAL: solo se crea lo que falta. Use -v recrear=1 para reconstruir gold.'
\endif

-- El esquema se garantiza ANTES del bloque de DROP. Un DROP TABLE IF EXISTS
-- sobre un esquema inexistente no falla, pero avisar por NOTICE y seguir
-- esconde el problema real, que es que el ETL no creo la base.
CREATE SCHEMA IF NOT EXISTS gold;

\if :recrear
    -- El orden importa por las claves foraneas: primero los hechos, que son
    -- los que referencian a las dimensiones.
    DROP VIEW     IF EXISTS gold.v_contratos_validos CASCADE;
    DROP VIEW     IF EXISTS gold.v_contratos         CASCADE;
    DROP TABLE    IF EXISTS gold.fact_contrato        CASCADE;
    DROP TABLE    IF EXISTS gold.dim_tiempo           CASCADE;
    DROP TABLE    IF EXISTS gold.dim_entidad          CASCADE;
    DROP TABLE    IF EXISTS gold.dim_proveedor        CASCADE;
    DROP TABLE    IF EXISTS gold.dim_tipo_contrato    CASCADE;
    DROP TABLE    IF EXISTS gold.dim_modalidad         CASCADE;
    DROP TABLE    IF EXISTS gold.dim_estado           CASCADE;
    DROP TABLE    IF EXISTS gold.dim_origen           CASCADE;
    -- Las secuencias quedan con el valor ya consumido. Se reinician para que
    -- una reconstruccion produzca los mismos id_ que la original, que es lo
    -- que hace comparables dos ejecuciones del DDL.
    DROP SEQUENCE IF EXISTS gold.seq_entidad;
    DROP SEQUENCE IF EXISTS gold.seq_proveedor;
    DROP SEQUENCE IF EXISTS gold.seq_tipo_contrato;
    DROP SEQUENCE IF EXISTS gold.seq_modalidad;
    DROP SEQUENCE IF EXISTS gold.seq_estado;
    DROP SEQUENCE IF EXISTS gold.seq_origen;
\endif

-- =====================================================================
-- 0. ROLES DE LECTURA
-- =====================================================================
-- secop_integrado (la base de la version anterior del modelo) ya tiene estos
-- roles. En secop_dw se crean si no existen, para que Power BI se conecte
-- igual que antes. El bloque es condicional porque un GRANT a un rol inexistente
-- aborta el script entero.
-- ---------------------------------------------------------------------
DO $roles$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'secop_lectura') THEN
        CREATE ROLE secop_lectura WITH LOGIN;
        RAISE NOTICE 'Rol secop_lectura creado';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'secop_etl') THEN
        CREATE ROLE secop_etl WITH LOGIN;
        RAISE NOTICE 'Rol secop_etl creado';
    END IF;
END
$roles$;

-- =====================================================================
-- 1. dim_tiempo  ·  calendario 1900-2030
-- =====================================================================
-- Calendario puro, NO derivado de los contratos: se genera con
-- generate_series y tiene que existir completo aunque un ano no tenga
-- ninguna fila. Por eso no se hace INSERT ... SELECT DISTINCT sobre los
-- hechos, que es el error clasico al construir esta dimension.
--
-- ARRANCA EN 1900 Y NO EN 2017, Y ESO ES OBLIGATORIO.
-- fecha_firma es a la vez clave de particion y clave foranea contra esta
-- tabla, y una columna de clave primaria no admite NULL. Hay filas de plata
-- con fecha_firma NULL (R4 las puso en NULL y marco flag_fecha_invalida), y
-- sin centinela no tendrian a que apuntar y el COPY fallaria.
-- El centinela es DATE '1900-01-01'. 1900 esta fuera del rango que acepta
-- silver.a_fecha (que exige >= 2000-01-01), asi que es imposible confundirlo
-- con una fecha real: si fecha_firma vale 1900-01-01, es porque no habia
-- fecha, siempre.
--
-- 47.847 dias = (2030-12-31 - 1900-01-01) + 1.
--
-- EL CAST A ::timestamp NO ES COSMETICO. Si se pasa un DATE tal cual,
-- PostgreSQL resuelve generate_series contra la sobrecarga de TIMESTAMPTZ, y
-- con zona America/Bogota sumar '1 day' a un timestamptz preserva la hora
-- local: al cruzar un cambio de horario la hora se desvia, la deriva se
-- acumula ano tras ano y la serie termina ANTES de tiempo. Medido en la base
-- del modelo anterior (calendario 1990-2030): terminaba el 2030-12-30 con
-- 14.974 filas en vez de 14.975, dejando fuera el 2030-12-31, y como
-- fecha_firma es clave foranea ese dia habria hecho fallar el COPY.
--
-- ESTA ES LA UNICA DIMENSION DE LAS SIETE QUE NO USA LLAVE SUSTITUTA, y es
-- una decision consciente, no un descuido. Las otras seis son catalogos de
-- entidades que pueden crecer, y por eso usan id incremental mas codigo
-- natural. El calendario no: la fecha ya es un identificador perfecto, sin
-- duplicados, sin ambiguedad, y estable para siempre.
--
-- Ponerle id a la vez tendria dos efectos malo. Uno: 47.847 filas y una
-- secuencia mas que mantener sin ganar nada. Dos, y este es el serio: la
-- clave de particion de fact_contrato tiene que ser la misma columna que la
-- clave foranea, y una FK a dim_tiempo(id_tiempo) no podria ser la clave de
-- particion porque PostgreSQL exige que la clave de particion sea una columna
-- o expresion de la tabla, no una referencia a otra tabla. Habria que
-- duplicar la fecha en la tabla de hechos, guardarla dos veces, y perder la
-- garantia de que ambas copias coinciden.
--
-- El registro -1 tampoco se usa aqui, por la misma razon: el desconocido no
-- es una fecha, es la ausencia de fecha, y esa ausencia ya tiene un valor
-- propio y explicito, 1900-01-01, con su bandera es_centinela. El -1 de las
-- otras seis dimensiones resuelve "no se que valor es"; aqui el valor esta
-- determinado por la propia naturaleza del dato ausente.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS gold.dim_tiempo (
    fecha             date PRIMARY KEY,
    anio              smallint NOT NULL,
    trimestre         smallint NOT NULL,
    mes               smallint NOT NULL,
    dia               smallint NOT NULL,
    nombre_mes        text     NOT NULL,
    dia_semana        smallint NOT NULL,
    nombre_dia        text     NOT NULL,
    es_fin_de_semana  boolean  NOT NULL,
    -- Marca el centinela para que las consultas lo excluyan sin tener que
    -- escribir la fecha literal en todas partes.
    es_centinela      boolean  NOT NULL DEFAULT false,
    CONSTRAINT dim_tiempo_rango
        CHECK (fecha BETWEEN DATE '1900-01-01' AND DATE '2030-12-31')
);

COMMENT ON TABLE gold.dim_tiempo IS
    'Calendario continuo 1900-01-01 a 2030-12-31 (47.847 dias), generado con generate_series y no derivado de los contratos. Empieza en 1900 para que la clave foranea fecha_firma pueda apuntar al centinela 1900-01-01 de las filas sin fecha valida.';
COMMENT ON COLUMN gold.dim_tiempo.es_centinela IS
    'TRUE solo en 1900-01-01. Todo KPI temporal debe filtrar por es_centinela = false o por anio BETWEEN 2017 AND 2026.';

INSERT INTO gold.dim_tiempo (
    fecha, anio, trimestre, mes, dia, nombre_mes,
    dia_semana, nombre_dia, es_fin_de_semana, es_centinela
)
SELECT
    d::date,
    extract(year    FROM d)::smallint,
    extract(quarter FROM d)::smallint,
    extract(month   FROM d)::smallint,
    extract(day     FROM d)::smallint,
    to_char(d, 'TMMonth'),
    extract(dow     FROM d)::smallint,
    to_char(d, 'TMDay'),
    extract(isodow  FROM d) >= 6,
    d::date = DATE '1900-01-01'
FROM generate_series(DATE '1900-01-01'::timestamp,
                     DATE '2030-12-31'::timestamp,
                     INTERVAL '1 day') AS d
ON CONFLICT (fecha) DO NOTHING;

-- =====================================================================
-- 2. EL REGISTRO -1  ·  el miembro desconocido de las 6 dimensiones
-- =====================================================================
-- Las 6 dimensiones categoricas se llenan con un registro de id = -1 cuyo
-- codigo es 'NO DEFINIDO'. Es el patron de "miembro desconocido" y resuelve
-- tres problemas a la vez:
--
--   a) Las claves foraneas de la tabla de hechos son NOT NULL. Sin -1,
--      cada fila con codigo_entidad NULL habria que descartarla o dejarla
--      huerfana. Con -1 no se pierde ni una fila.
--   b) El DEFAULT -1 de cada columna FK hace que la carga no pueda
--      equivocarse: si el INSERT no encuentra la dimension, la fila cae en
--      -1 sola, en vez de fallar a mitad de los 13 millones de filas.
--   c) La consulta que responde "cuantos contratos no dicen tipo de
--      contrato" es un WHERE contra una fila, no un IS NULL repartido por 13
--      millones de filas. En Power BI es un filtro mas, no un manejo especial.
--
-- POR QUE -1 Y NO 0. El 0 se confunde con un valor real de las columnas
-- funcionalmente numericas del origen, y cualquier reporte que sume sin
-- mirar la clave lo tomaria como dato. -1 no aparece nunca como dato.
--
-- POR QUE -1 Y NO NULL. NULL en una FK significa "no se pudo resolver", que
-- es una informacion que no se quiere perder: aqui -1 significa "el origen
-- no lo traia", que si es informacion. El NULL de verdad se conserva en
-- silver.contratos, que es la capa de auditoria.
-- ---------------------------------------------------------------------

-- =====================================================================
-- 3. LAS 6 DIMENSIONES CATEGORICAS
-- =====================================================================
-- POR QUE NO LLEVA COLLATE secop_ci, COMO LAS LLEVABAN EN EL MODELO RETIRADO
-- (sql/retirado/01_esquema.sql).
-- Aquella version necesitaba secop_ci porque las categorias del origen venian
-- con la caja rota ("Prestacion de Servicios" contra "Prestacion de
-- servicios") y no habia manera de colapsarlas sin una collation no
-- determinista. En este modelo YA NO HACE FALTA, y la razon es que la
-- limpieza se movio a plata:
--
--   R1 de 02_silver_limpieza.sql pasa TODOS los textos a mayusculas y les
--   quita tildes con unaccent. En plata no queda ni una minuscula, ni una
--   tilde, ni una barra suelta (ver PRUEBA 1 de 05_qa_silver.sql: 0 en las
--   cuatro pruebas de R1).
--   R3 homologa contra silver.homologacion, un catalogo explicito de 17
--   equivalencias, que es mas fuerte que cualquier collation: no solo
--   ignora la caja, tambien unifica sinonimos reales como
--   "CONTRATACION DIRECTA (LEY 1150 DE 2007)" con "CONTRATACION DIRECTA".
--
-- Consecuencia: la clave natural de cada dimension es determinista y se
-- puede declarar UNIQUE en serio. Con secop_ci, un UNIQUE sobre una
-- collation no determinista obliga a usar operadores de igualdad no
-- deterministas en cualquier consulta que la use, que es una limitacion
-- conocida de PostgreSQL. Una funcionalidad menos que mantener.
--
-- POR QUE UN SEQUENCE Y NO "GENERATED ALWAYS AS IDENTITY". Se necesita
-- poder insertar explicitamente el id = -1, y ALWAYS identity no lo permite
-- sin OVERRIDING SYSTEM VALUE en cada inserccion. Con un SEQUENCE y un
-- DEFAULT nextval el -1 se inserta una vez al principio y el resto de la
-- tabla se genera sola.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- 3.1 dim_entidad
-- ---------------------------------------------------------------------
-- ABSORBE LA UBICACION. No existe dim_ubicacion, y es la misma decision que
-- se documento para el modelo anterior: municipio y departamento son
-- atributos de la entidad, no una dimension aparte. Con 15.928 entidades
-- contra 1.131 municipios, un municipio no puede depender de dos dimensiones
-- a la vez sin duplicar el dato y sumar un JOIN a cada consulta.
-- La clave natural es codigo_entidad, no el NIT: el NIT tiene 4,00% de
-- vacios en plata y un mismo NIT puede aparecer con nombres distintos
-- de la entidad.
-- ---------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS gold.seq_entidad;
CREATE TABLE IF NOT EXISTS gold.dim_entidad (
    id_entidad     integer NOT NULL DEFAULT nextval('gold.seq_entidad'),
    codigo_entidad text,
    nombre_entidad  text,
    nit_entidad     text,
    nivel_entidad   text,
    departamento    text,
    municipio       text,
    -- Registros de proveedor por entidad. Es un atributo derivado que se
    -- calcula una vez en la carga y no en cada consulta: contar sobre
    -- 13 millones de filas cada vez que Power BI pide la tarjeta de una
    -- entidad es la via rapida a un tablero lento.
    contratos      integer,
    valor_total    numeric(18,2),
    CONSTRAINT dim_entidad_pk PRIMARY KEY (id_entidad),
    CONSTRAINT dim_entidad_codigo_key UNIQUE (codigo_entidad)
);
COMMENT ON TABLE gold.dim_entidad IS
    'Entidad contratante, con su ubicacion (departamento y municipio) absorbida. Clave natural codigo_entidad. La fila id_entidad = -1 es el miembro desconocido.';

-- ---------------------------------------------------------------------
-- 3.2 dim_proveedor
-- ---------------------------------------------------------------------
-- El documento ya viene normalizado en plata: R8 lo pasa por solo_digitos()
-- y, si el tipo de documento es NIT, por nit_base() que le quita el digito
-- de verificacion con el algoritmo modulo 11 de la DIAN. Por eso aqui NO se
-- normaliza otra vez: "8300844337" y "830.084.433-7" ya son la misma cadena
-- antes de llegar a oro.
--
-- tipo_documento se queda AQUI y no en una dimension aparte. Es un atributo
-- del proveedor, no una dimension: depende enteramente del documento, asi
-- que una dim_tipo_documento seria una dimension que cuelga de otra sin
-- aportar ningun analisis que no se pueda hacer con un filtro de columna.
-- Es la razon por la que el modelo tiene 7 dimensiones y no 8.
-- ---------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS gold.seq_proveedor;
CREATE TABLE IF NOT EXISTS gold.dim_proveedor (
    id_proveedor    integer NOT NULL DEFAULT nextval('gold.seq_proveedor'),
    documento       text,
    nombre_proveedor text,
    tipo_documento  text,
    es_persona_natural boolean,
    contratos      integer,
    valor_total    numeric(18,2),
    CONSTRAINT dim_proveedor_pk PRIMARY KEY (id_proveedor),
    CONSTRAINT dim_proveedor_documento_key UNIQUE (documento)
);
COMMENT ON TABLE gold.dim_proveedor IS
    'Proveedor / contratista. El documento llega ya normalizado desde plata (R8: solo digitos, sin digito de verificacion). La fila id_proveedor = -1 es el miembro desconocido. tipo_documento es atributo, no dimension.';
COMMENT ON COLUMN gold.dim_proveedor.es_persona_natural IS
    'TRUE para cedula, pasaporte y visa; FALSE para NIT. Es la columna que responde RF-12 sin tener que leer 19 cadenas de texto distintas en cada grafico.';

-- ---------------------------------------------------------------------
-- 3.3 dim_tipo_contrato
-- 3.4 dim_modalidad
-- 3.5 dim_estado
-- 3.6 dim_origen
-- ---------------------------------------------------------------------
-- Misma estructura, tres fines distintos:
--   tipo_contrato  que se compro (prestacion de servicios, obra, suministro)
--   modalidad      COMO se contrato ( minima cuantia, regimen especial, ...)
--   estado         en que fase esta el proceso (…).
--   origen         de que plataforma viene la fila (SECOPI / SECOPII)
--
-- NOTA SOBRE dim_estado: en plata, estado_proceso NO pasa por el catalogo de
-- homologacion, porque un estado es un valor de un solo campo y las 30
-- variantes del origen se normalizan solo con R1 (mayusculas, sin tildes).
-- Las tres que quedan sueltas ("cedido", "terminado", variantes de caja) se
-- resuelven con el catalogo si el QA las marca; por ahora se conservan tal
-- como llegan, que es lo que exige el requisito de no tratar datos de forma
-- silenciosa.
CREATE SEQUENCE IF NOT EXISTS gold.seq_tipo_contrato;
CREATE TABLE IF NOT EXISTS gold.dim_tipo_contrato (
    id_tipo_contrato integer NOT NULL DEFAULT nextval('gold.seq_tipo_contrato'),
    codigo           text,
    descripcion      text,
    contratos        integer,
    valor_total      numeric(18,2),
    CONSTRAINT dim_tipo_contrato_pk PRIMARY KEY (id_tipo_contrato),
    CONSTRAINT dim_tipo_contrato_codigo_key UNIQUE (codigo)
);

CREATE SEQUENCE IF NOT EXISTS gold.seq_modalidad;
CREATE TABLE IF NOT EXISTS gold.dim_modalidad (
    id_modalidad   integer NOT NULL DEFAULT nextval('gold.seq_modalidad'),
    codigo         text,
    descripcion    text,
    es_minima_cuantia boolean NOT NULL DEFAULT false,
    contratos      integer,
    valor_total    numeric(18,2),
    CONSTRAINT dim_modalidad_pk PRIMARY KEY (id_modalidad),
    CONSTRAINT dim_modalidad_codigo_key UNIQUE (codigo)
);
COMMENT ON COLUMN gold.dim_modalidad.es_minima_cuantia IS
    'TRUE para MINIMA CUANTIA. Es lo que necesita RF-08 (deteccion de fraccionamiento): un contrato por debajo de este umbral es candidato a fraccionamiento, y el umbral cambia por entidad y por ano, asi que la marca sola no basta, pero sirve de filtro.';

CREATE SEQUENCE IF NOT EXISTS gold.seq_estado;
CREATE TABLE IF NOT EXISTS gold.dim_estado (
    id_estado    integer NOT NULL DEFAULT nextval('gold.seq_estado'),
    codigo       text,
    descripcion  text,
    es_terminado boolean NOT NULL DEFAULT false,
    contratos    integer,
    valor_total  numeric(18,2),
    CONSTRAINT dim_estado_pk PRIMARY KEY (id_estado),
    CONSTRAINT dim_estado_codigo_key UNIQUE (codigo)
);

CREATE SEQUENCE IF NOT EXISTS gold.seq_origen;
CREATE TABLE IF NOT EXISTS gold.dim_origen (
    id_origen   integer NOT NULL DEFAULT nextval('gold.seq_origen'),
    codigo      text,
    descripcion text,
    contratos   integer,
    valor_total numeric(18,2),
    CONSTRAINT dim_origen_pk PRIMARY KEY (id_origen),
    CONSTRAINT dim_origen_codigo_key UNIQUE (codigo)
);
COMMENT ON TABLE gold.dim_origen IS
    'Plataforma de origen: SECOPI y SECOPII. Se conservan separadas (requisito D-09) porque no son la misma poblacion: SECOP I no exige fecha de ejecucion y SECOP II si.';

-- =====================================================================
-- 4. Los registros -1
-- =====================================================================
-- Se insertan UNA vez, antes de la tabla de hechos, porque las FK con
-- DEFAULT -1 necesitan que la fila exista en el momento del COPY. Si se
-- insertaran despues, el COPY fallaria en la primera fila sin categoria.
-- El ON CONFLICT hace el script reejecutable.
INSERT INTO gold.dim_entidad       (id_entidad, nombre_entidad)  VALUES (-1, 'NO DEFINIDO') ON CONFLICT DO NOTHING;
INSERT INTO gold.dim_proveedor     (id_proveedor, nombre_proveedor) VALUES (-1, 'NO DEFINIDO') ON CONFLICT DO NOTHING;
INSERT INTO gold.dim_tipo_contrato (id_tipo_contrato, descripcion)  VALUES (-1, 'NO DEFINIDO') ON CONFLICT DO NOTHING;
INSERT INTO gold.dim_modalidad      (id_modalidad, descripcion)      VALUES (-1, 'NO DEFINIDO') ON CONFLICT DO NOTHING;
INSERT INTO gold.dim_estado        (id_estado, descripcion)         VALUES (-1, 'NO DEFINIDO') ON CONFLICT DO NOTHING;
INSERT INTO gold.dim_origen        (id_origen, descripcion)        VALUES (-1, 'NO DEFINIDO') ON CONFLICT DO NOTHING;

COMMENT ON COLUMN gold.dim_entidad.codigo_entidad IS
    'Clave natural de la entidad, UNIQUE. Es un UNIQUE posible porque plata entrego el campo ya normalizado por R1 (mayusculas, sin tildes, sin nulos disfrazados), de modo que no hay dos escrituras que solo difieran en caja. En el modelo anterior, sobre el origen crudo, si habia: "Prestacion de Servicios" contra "prestacion de servicios" son claves distintas y por eso ahi la clave llevaba COLLATE secop_ci. Aqui la normalizacion ya ocurrio, y determinista.';

-- =====================================================================
-- 5. gold.fact_contrato  ·  tabla de hechos
-- =====================================================================
-- -----------------------------------------------------------------------------
-- EL GRANO, QUE ES LO UNICO QUE HAY QUE DECIDIR BIEN
-- -----------------------------------------------------------------------------
-- Una fila de fact_contrato = una fila de silver.contratos = 13.005.402.
-- O sea: UNA VERSION DE CONTRATO, no un contrato.
--
-- El motivo es R7b de 02c_correccion_valores.sql. En SECOP II un mismo
-- contrato aparece en varias filas, una por cada modificacion, con el mismo
-- id_contrato y valores distintos: son 554.063 contratos en 1.317.098 filas.
-- No se puede eliminar ninguna fila (cada una es una modificacion real) y no
-- se puede colapsar a una sola (el dataset no dice cual es la vigente).
--
-- LA SOLUCION ES QUE LA MEDIDA ESTE REPARTIDA. R7b deja valor_ajustado =
-- valor_contrato / n en cada una de las n filas, de modo que:
--
--     SUM(valor_ajustado)  sobre las n filas  =  el PROMEDIO de las versiones
--     SUM(valor_ajustado)  sobre un contrato  =  su valor, UNA vez
--
-- Es decir: sumar valor_ajustado da el mismo numero en cualquiera de los dos
-- granos. Ese es el motivo de que la medida se llame ajustado y no valor.
--
-- Y POR QUE NO SE USA valor_contrato PARA NADA MONETARIO. Con el valor
-- crudo, 2018 daba 692 billones de pesos frente a los 100 de la cifra
-- oficial. Con valor_ajustado da 102,5, que es el numero que publica
-- Colombia Compra Eficiente. Medido en 05_qa_silver.sql PRUEBA 9 y validado
-- en reporte_validacion_python.md (42/42).
--
-- CUIDADO CON EL OTRO LADO. SUM(valor_ajustado) NO excluye los valores
-- atipicos. Para dinero hay que sumar CON EL FILTRO:
--     WHERE es_atipico = false
-- Un contrato de 28,11 billones de la IDIGER a un acueducto es un hecho del
-- dato, no un error de carga, asi que no se borra: se marca y que el
-- consumidor decida.
--
-- -----------------------------------------------------------------------------
-- LAS CLAVES FORANEAS
-- -----------------------------------------------------------------------------
-- SEIS claves foraneas enteras, no siete: fecha_firma ES la septima, contra
-- dim_tiempo. Son las 7 dimensiones, y por eso el conteo de claves por fila
-- coincide con lo que dice el DDL de arriba y lo que seccion 4 del modelo
-- documenta.
--
-- -----------------------------------------------------------------------------
-- SOBRE LA CLAVE PRIMARIA
-- -----------------------------------------------------------------------------
-- id_fila NO es GENERATED: es silver.contratos.id_fila, que a su vez es
-- bronze.secop_raw.id_fila. La fila de oro conserva el numero con el que
-- llego, y eso convierte el rastro de una cifra en una sola consulta:
--
--     SELECT ... FROM gold.fact_contrato f
--     JOIN silver.contratos s USING (id_fila)
--     JOIN bronze.secop_raw b USING (id_fila)
--
-- Es la trazabilidad que exige RNF-06 y que se pierde en cuanto se genera
-- una identidad nueva. El precio es que el id queda ligado al orden de carga
-- de bronce; si se recarga bronce con otro orden, hay que reconstruir oro.
-- Es un intercambio aceptable y consciente: la trazabilidad vale mas que la
-- independencia del id.
--
-- La PK es COMPOSTA porque el particionado la obliga: PostgreSQL no admite
-- una PK ni un UNIQUE que no incluyan la clave de particion. De paso cubre
-- los rangos de fecha, asi que no hace falta un B-tree extra sobre
-- fecha_firma, y por eso el unico indice de fecha es un BRIN.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS gold.fact_contrato (
    -- Clave de particion y a la vez clave foranea de dim_tiempo (la 7ma).
    -- NOT NULL por dos razones que se refuerzan: la PK no admite NULL, y sin
    -- fecha no hay particion donde meter la fila.
    fecha_firma              date    NOT NULL
                                    CONSTRAINT fk_fact_tiempo
                                    REFERENCES gold.dim_tiempo(fecha),
    id_fila                  bigint  NOT NULL,

    -- La centinela se ve desde oro sin tener que comparar contra la fecha
    -- literal. El texto crudo de la fecha que R4 rechazo NO se guarda aqui:
    -- plata lo borro (lo puso en NULL y solo dejo la bandera), asi que no
    -- tendria de donde copiarse. Vive en bronze.secop_raw, al que se llega
    -- por id_fila. Guardar en oro una copia de fecha_firma bajo otro nombre
    -- habria costado 52 MB y no habria recuperado nada.
    fecha_firma_es_centinela boolean NOT NULL DEFAULT false,

    fecha_inicio             date,
    fecha_fin                date,
    -- Derivada y materialized: es una resta de dos columnas y se lee en
    -- todos los KPI de RF-09. Guardarla evita 13 millones de restas por
    -- consulta.
    duracion_dias            integer GENERATED ALWAYS AS (fecha_fin - fecha_inicio) STORED,

    -- Identificadores naturales del contrato. NO son clave: en SECOP I el
    -- mismo numero aparece en cientos de filas (el caso 18-4-7947515 tiene
    -- 304.583 filas en el corte completo).
    --
    -- numero_proceso es el codigo CO1.PCCNTR de SECOP II, y por eso es
    -- tambien lo que permite distinguir las versiones de un mismo contrato:
    -- dentro de un numero de contrato, cada version tiene su proceso.
    numero_contrato          text,
    numero_proceso           text,

    -- LAS DOS MEDIDAS. valor_contrato es el dato tal cual llega y se conserva
    -- por fidelidad (D-03). valor_ajustado es la que se suma.
    valor_contrato           numeric(18,2),
    valor_ajustado           numeric(18,2),

    objeto_contrato          text,
    url_contrato             text,

    -- ---------------------------------------------------------------------
    -- Banderas de calidad, heredadas de silver.contratos
    -- ---------------------------------------------------------------------
    -- Se traen TODAS, y no solo es_atipico, por una razon concreta: si oro
    -- solo guardara la que interesa al tablero, las otras cinco quedarian
    -- accesibles solo a travers de silver, es decir, con un JOIN de 13
    -- millones de filas. Con las seis aqui, toda la calidad es consultable
    -- desde gold, que es lo que el usuario de solo-lectura puede ver.
    --
    -- Los nombres pierden el prefijo flag_ porque en la tabla de hechos ya no
    -- son banderas: son atributos del hecho, y un prefijo de tabla es ruido.
    es_atipico              boolean NOT NULL DEFAULT false,
    es_valor_extremo        boolean NOT NULL DEFAULT false,
    es_valor_cero           boolean NOT NULL DEFAULT false,
    es_valor_relleno        boolean NOT NULL DEFAULT false,
    es_valor_repetido       boolean NOT NULL DEFAULT false,
    es_version_contrato     boolean NOT NULL DEFAULT false,
    es_fecha_invalida       boolean NOT NULL DEFAULT false,
    es_fechas_incoherentes  boolean NOT NULL DEFAULT false,

    -- ---------------------------------------------------------------------
    -- Las 6 claves foraneas enteras. La septima es fecha_firma, arriba.
    -- El DEFAULT -1 manda cada fila sin categoria al miembro desconocido, de
    -- modo que la carga no puede dejar huerfanos ni morir a mitad de camino.
    -- ---------------------------------------------------------------------
    id_entidad               integer NOT NULL DEFAULT -1
                                     REFERENCES gold.dim_entidad(id_entidad),
    id_proveedor             integer NOT NULL DEFAULT -1
                                     REFERENCES gold.dim_proveedor(id_proveedor),
    id_tipo_contrato         integer NOT NULL DEFAULT -1
                                     REFERENCES gold.dim_tipo_contrato(id_tipo_contrato),
    id_modalidad             integer NOT NULL DEFAULT -1
                                     REFERENCES gold.dim_modalidad(id_modalidad),
    id_estado                integer NOT NULL DEFAULT -1
                                     REFERENCES gold.dim_estado(id_estado),
    id_origen                integer NOT NULL DEFAULT -1
                                     REFERENCES gold.dim_origen(id_origen),

    -- No se pone WITH (fillfactor = 90) aqui. Una tabla particionada es
    -- virtual: no tiene almacenamiento propio, asi que el servidor rechaza
    -- los parametros de almacenamiento en la madre. El fillfactor se aplica a
    -- cada particion, en el bloque 5.1.
    CONSTRAINT fact_contrato_pk PRIMARY KEY (fecha_firma, id_fila)
) PARTITION BY RANGE (fecha_firma);

COMMENT ON TABLE gold.fact_contrato IS
    'Grano: 1 fila por fila de silver.contratos = 13.005.402 = UNA VERSION DE CONTRATO, no un contrato. En SECOP II hay 554.063 contratos en 1.317.098 filas por las modificaciones. SUM(valor_ajustado) es correcto en los dos granos; para dinero, excluir es_atipico.';
COMMENT ON COLUMN gold.fact_contrato.valor_ajustado IS
    'LA medida. valor_contrato / n, donde n es el numero de filas del mismo contrato con el mismo valor (R7) o el numero de versiones (R7b). Sumarla da el valor real del contrato UNA vez. Sumar valor_contrato da 692 billones en 2018 frente a los 100 oficiales.';
COMMENT ON COLUMN gold.fact_contrato.valor_contrato IS
    'El valor tal cual viene del origen. Se conserva por fidelidad al dato (D-03) y para poder recalcular valor_ajustado sin volver a plata. NO se usa en ningun KPI.';
COMMENT ON COLUMN gold.fact_contrato.id_fila IS
    '= silver.contratos.id_fila = bronze.secop_raw.id_fila. La trazabilidad de una cifra hasta el CSV de origen es un JOIN por esta columna, sin tabla puente.';
COMMENT ON COLUMN gold.fact_contrato.numero_proceso IS
    'Clave de proceso en formato CO1.PCCNTR de SECOP II. Distingue las versiones de un mismo numero de contrato, que es lo que hace R7b. En SECOP I trae el numero de proceso numerico.';
COMMENT ON COLUMN gold.fact_contrato.duracion_dias IS
    'fecha_fin - fecha_inicio. NULL si falta cualquiera de las dos (date - date en SQL devuelve NULL, no -1). Los 670 contratos con duracion negativa y los 662 con fecha_fin anterior a fecha_inicio estan marcados con es_fechas_incoherentes y no se corrigen.';

-- ---------------------------------------------------------------------
-- 5.1 Particiones
-- ---------------------------------------------------------------------
-- El corte actual son 10 archivos, uno por ano, de 2017 a 2026. El DDL crea:
--   cuarentena pre2000  (1900-01-01 -> 2000-01-01)  1 particion
--   anuales 2017 a 2027                             11 particiones
--   por defecto (todo lo que pase de 2028)          1 particion
--   Total                                           13
--
-- POR QUE NO 30 COMO EN EL MODELO ANTERIOR. Ahi el origen traia los 27 anos
-- de 2000 a 2026, asi que 30 particiones eran 30 anos con datos. Aqui el
-- corte son 10 anos: abrir 17 particiones vacias no cuesta disco (un
-- catalog entry) pero si cuesta ruido, porque un QA que cuenta particiones
-- con filas ve 13 tablas de las que 3 no tienen ninguna, y eso invite a
-- pensar que algo fallo.
--
-- Y SI EL CORTE SE AMPLIA. Anadir 2016 es una linea en el bucle de abajo y
-- un ALTER TABLE ... ATTACH PARTITION. No se migran las 13 millones de
-- filas: por eso particionar (requisito RNF-04) y no una tabla gorda.
-- Lo que caiga fuera de los anos declarados NO SE PIERDE: aterriza en
-- fact_contrato_resto, que es la particion por defecto, y es visible.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS gold.fact_contrato_pre2000
    PARTITION OF gold.fact_contrato
    FOR VALUES FROM (DATE '1900-01-01') TO (DATE '2000-01-01')
    WITH (fillfactor = 90);
COMMENT ON TABLE gold.fact_contrato_pre2000 IS
    'Cuarentena. Las filas con fecha_firma NULL (flag_fecha_invalida) caen aqui con fecha_firma = 1900-01-01 y fecha_firma_es_centinela = true. En el corte actual deberia contener 0 filas, porque toda fecha de plata es >= 2000-01-01 por R4; se conserva para que el modelo no dependa de esa suposicion.';

DO $crear_particiones$
DECLARE
    v_anio integer;
BEGIN
    -- EL ESQUEMA VA COMO %I PROPIO, Y ESTO NO ES COSMETICO.
    -- La version anterior de este DDL usaba un solo %I con el nombre sin
    -- cualificar, y PostgreSQL resolvio las 28 particiones anuales en el
    -- esquema public, no en gold. No es un detalle de estilo: los permisos
    -- en PostgreSQL son por esquema, y public tiene USAGE concedido a PUBLIC,
    -- asi que la tabla de hechos quedaba al alcance de cualquier rol que
    -- conectara. Ver decisiones_tecnicas.md seccion 7.
    FOR v_anio IN 2017..2027 LOOP
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I.%I PARTITION OF gold.fact_contrato'
            ' FOR VALUES FROM (%L) TO (%L) WITH (fillfactor = 90)',
            'gold',
            'fact_contrato_y' || v_anio,
            make_date(v_anio, 1, 1),
            make_date(v_anio + 1, 1, 1)
        );
    END LOOP;
END
$crear_particiones$;

CREATE TABLE IF NOT EXISTS gold.fact_contrato_resto
    PARTITION OF gold.fact_contrato DEFAULT
    WITH (fillfactor = 90);
COMMENT ON TABLE gold.fact_contrato_resto IS
    'Particion por defecto. Si deberia estar vacia y no lo esta, hay una fecha fuera del rango declarado: es el aviso de que el corte se movio.';

-- ---------------------------------------------------------------------
-- 5.2 Indices
-- ---------------------------------------------------------------------
-- SEIS, y la lista es corta a proposito. Cada indice de la tabla de hechos
-- son cientos de megabytes sobre 13 millones de filas, y uno que no se usa
-- no es "inofensivo": se mantiene en cada INSERT y en cada VACUUM.
--
-- La PK (fecha_firma, id_fila) ya resuelve los rangos de fecha: es un
-- B-tree con fecha_firma como columna leader. Por eso NO hay B-tree sobre
-- fecha_firma, y el unico indice de fecha es el BRIN.
CREATE INDEX IF NOT EXISTS ix_fact_fecha_brin
    ON gold.fact_contrato USING brin (fecha_firma)
    WITH (pages_per_range = 32, autosummarize = on);

-- La consulta mas frecuente del proyecto: cuanto se contrato en un ano, y
-- cuanto dinero. Es la que resuelve RF-07, RF-10 y la mitad de RF-15.
CREATE INDEX IF NOT EXISTS ix_fact_anio_valor
    ON gold.fact_contrato (fecha_firma, valor_ajustado);

-- FK mas usadas: los dos ejes de analisis, contratista y entidad.
CREATE INDEX IF NOT EXISTS ix_fact_proveedor
    ON gold.fact_contrato (id_proveedor);
CREATE INDEX IF NOT EXISTS ix_fact_entidad
    ON gold.fact_contrato (id_entidad);

-- Deteccion de versiones y de repetidos (RF-08 cuenta sobre el numero).
CREATE INDEX IF NOT EXISTS ix_fact_numero_contrato
    ON gold.fact_contrato (numero_contrato);

-- NO hay indice sobre valor_ajustado suelto: ix_fact_anio_valor ya lo cubre
-- con la fecha delante. En el modelo anterior se midio que uno suelto ocupaba
-- 639 MB y no lo usaba ninguna consulta, y por eso se elimino.
--
-- NO hay indice sobre es_atipico: es un booleano con 33.928 filas en true
-- sobre 13 millones. Un indice sobre el 99,7% de falsos no lo usa nadie.

-- =====================================================================
-- 6. CARGA DE GOLD  ·  el bloque que se ejecuta despues de crear el DDL
-- =====================================================================
-- Se deja aqui, y no en un archivo aparte, para que el modelo y su carga no
-- puedan separarse: si se cambia una dimension hay que cambiar el INSERT que
-- la llena, y tenerlos en el mismo archivo hace que el cambio se vea.
--
-- NO ES IDEMPOTENTE POR SI MISMO. El bloque 6.1 (las seis dimensiones) si
-- lo es: el ON CONFLICT evita duplicar y el UPDATE refresca los atributos.
-- El bloque 6.2 (la tabla de hechos) NO lo es, porque 13 millones de filas no
-- entran en un ON CONFLICT. Para recargarla sobre una base ya poblada:
--
--     TRUNCATE gold.fact_contrato;
--     \i sql/02_modelo_gold.sql
--
-- que es lo que hace -v recrear=1 por el camino largo. Nota: TRUNCATE
-- ... RESTART IDENTITY solo reinicia columnas GENERATED ... AS IDENTITY, y
-- estas dimensiones usan secuencias CREATE SEQUENCE, asi que no se puede
-- usar. Si se truncan a mano, las secuencias gold.seq_* quedan desfasadas y
-- hay que reiniciarlas con ALTER SEQUENCE ... RESTART WITH 1.
--
-- Ademas hay que reinsertar los seis registros -1, que el TRUNCATE se lleva y
-- que la seccion 1.4 vuelve a crear porque va antes que el TRUNCATE manual
-- solo si el orden es el correcto: el script completo con recrear=1.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 6.1 Las 6 dimensiones categoricas
-- ---------------------------------------------------------------------
-- El patron es el mismo en las seis y se explica una vez:
--   INSERT      agrega las claves naturales que no estaban
--   ON CONFLICT no hace nada si ya estaban, gracias al UNIQUE de la clave
--   UPDATE      agrega los atributos que si pudieron cambiar
--
-- El UNIQUE es lo que hace idempotente el INSERT. Sin el, un
-- ON CONFLICT DO NOTHING no tendria contra que chocar y la segunda
-- ejecucion duplicaria la dimension entera.
--
-- El UPDATE es lo que hace idempotente el resto. Sin el, un nombre de
-- proveedor que llego en mayusculas en la tanda 1 y con una barra suelta en
-- la tanda 2 (el problema de 02b_correccion_barras.sql) se quedaria con el
-- valor viejo.
--
-- dim_entidad y dim_proveedor se cargan con GROUP BY y no con
-- SELECT DISTINCT, porque pueden traer filas con el MISMO codigo y atributos
-- distintos: el mismo codigo de entidad con dos nombres, o el mismo documento
-- con dos razones sociales. max() elige una, que es una decision de modelo
-- consciente y no un dato perdido: los atributos originales siguen en
-- silver.contratos y la fila se puede recuperar por id_fila.
--
-- contratos y valor_total se calculan con el filtro de dinero correcto:
--     valor_ajustado, excluyendo es_atipico
-- de modo que el numero de una tarjeta de entidad en Power BI ya vem
-- limpio y no hay que repetir el filtro en cada medida.

INSERT INTO gold.dim_origen (codigo, descripcion)
SELECT DISTINCT s.origen, s.origen FROM silver.contratos s
WHERE s.origen IS NOT NULL
ON CONFLICT ON CONSTRAINT dim_origen_codigo_key DO NOTHING;

INSERT INTO gold.dim_tipo_contrato (codigo, descripcion)
SELECT DISTINCT s.tipo_contrato, s.tipo_contrato FROM silver.contratos s
WHERE s.tipo_contrato IS NOT NULL
ON CONFLICT ON CONSTRAINT dim_tipo_contrato_codigo_key DO NOTHING;

INSERT INTO gold.dim_modalidad (codigo, descripcion)
SELECT DISTINCT s.modalidad, s.modalidad FROM silver.contratos s
WHERE s.modalidad IS NOT NULL
ON CONFLICT ON CONSTRAINT dim_modalidad_codigo_key DO NOTHING;

INSERT INTO gold.dim_estado (codigo, descripcion)
SELECT DISTINCT s.estado_proceso, s.estado_proceso FROM silver.contratos s
WHERE s.estado_proceso IS NOT NULL
ON CONFLICT ON CONSTRAINT dim_estado_codigo_key DO NOTHING;

INSERT INTO gold.dim_entidad (codigo_entidad, nombre_entidad, nit_entidad,
                              nivel_entidad, departamento, municipio)
SELECT codigo_entidad, max(nombre_entidad), max(nit_entidad),
       max(nivel_entidad),  max(departamento),   max(municipio)
FROM silver.contratos
WHERE codigo_entidad IS NOT NULL
GROUP BY codigo_entidad
ON CONFLICT ON CONSTRAINT dim_entidad_codigo_key DO NOTHING;

INSERT INTO gold.dim_proveedor (documento, nombre_proveedor, tipo_documento,
                                es_persona_natural)
SELECT documento_proveedor, max(nombre_proveedor), max(tipo_doc_proveedor),
       bool_or(tipo_doc_proveedor NOT LIKE 'NIT%')
FROM silver.contratos
WHERE documento_proveedor IS NOT NULL
GROUP BY documento_proveedor
ON CONFLICT ON CONSTRAINT dim_proveedor_documento_key DO NOTHING;

-- Atributos de dim_entidad
UPDATE gold.dim_entidad d SET
    nombre_entidad = a.nombre_entidad,
    nit_entidad    = a.nit_entidad,
    nivel_entidad  = a.nivel_entidad,
    departamento   = a.departamento,
    municipio      = a.municipio,
    contratos      = a.contratos,
    valor_total    = a.valor_total
FROM (
    SELECT codigo_entidad,
           max(nombre_entidad) AS nombre_entidad,
           max(nit_entidad)    AS nit_entidad,
           max(nivel_entidad)  AS nivel_entidad,
           max(departamento)   AS departamento,
           max(municipio)      AS municipio,
           count(*)            AS contratos,
           sum(valor_ajustado) FILTER (WHERE NOT flag_valor_atipico) AS valor_total
    FROM silver.contratos
    WHERE codigo_entidad IS NOT NULL
    GROUP BY codigo_entidad
) a
WHERE d.codigo_entidad = a.codigo_entidad;

-- Atributos de dim_proveedor.
-- es_persona_natural se decide por el tipo de documento, no por el nombre:
-- un NIT con digito de verificacion es de persona juridica por definicion
-- (la DIAN no asigna NIT a personas naturales sin relacion de dependencias).
UPDATE gold.dim_proveedor d SET
    nombre_proveedor     = a.nombre_proveedor,
    tipo_documento       = a.tipo_documento,
    es_persona_natural   = a.es_persona_natural,
    contratos            = a.contratos,
    valor_total          = a.valor_total
FROM (
    SELECT documento_proveedor,
           max(nombre_proveedor)  AS nombre_proveedor,
           max(tipo_doc_proveedor) AS tipo_documento,
           bool_or(tipo_doc_proveedor NOT LIKE 'NIT%') AS es_persona_natural,
           count(*)                AS contratos,
           sum(valor_ajustado) FILTER (WHERE NOT flag_valor_atipico) AS valor_total
    FROM silver.contratos
    WHERE documento_proveedor IS NOT NULL
    GROUP BY documento_proveedor
) a
WHERE d.documento = a.documento_proveedor;

UPDATE gold.dim_tipo_contrato d SET
    descripcion = d.codigo,
    contratos   = a.contratos,
    valor_total = a.valor_total
FROM (
    SELECT tipo_contrato, count(*) AS contratos,
           sum(valor_ajustado) FILTER (WHERE NOT flag_valor_atipico) AS valor_total
    FROM silver.contratos WHERE tipo_contrato IS NOT NULL
    GROUP BY tipo_contrato
) a
WHERE d.codigo = a.tipo_contrato;

UPDATE gold.dim_modalidad d SET
    descripcion          = d.codigo,
    es_minima_cuantia    = (d.codigo = 'MINIMA CUANTIA'),
    contratos            = a.contratos,
    valor_total          = a.valor_total
FROM (
    SELECT modalidad, count(*) AS contratos,
           sum(valor_ajustado) FILTER (WHERE NOT flag_valor_atipico) AS valor_total
    FROM silver.contratos WHERE modalidad IS NOT NULL
    GROUP BY modalidad
) a
WHERE d.codigo = a.modalidad;

UPDATE gold.dim_estado d SET
    descripcion  = d.codigo,
    es_terminado = (d.codigo IN ('CELEBRADO', 'LIQUIDADO', 'CERRADO',
                                 'TERMINADO SIN LIQUIDAR', 'TERMINADO ANORMALMENTE',
                                 'ADJUDICADO', 'CANCELADO')),
    contratos    = a.contratos,
    valor_total  = a.valor_total
FROM (
    SELECT estado_proceso, count(*) AS contratos,
           sum(valor_ajustado) FILTER (WHERE NOT flag_valor_atipico) AS valor_total
    FROM silver.contratos WHERE estado_proceso IS NOT NULL
    GROUP BY estado_proceso
) a
WHERE d.codigo = a.estado_proceso;

UPDATE gold.dim_origen d SET
    descripcion = d.codigo,
    contratos   = a.contratos,
    valor_total = a.valor_total
FROM (
    SELECT origen, count(*) AS contratos,
           sum(valor_ajustado) FILTER (WHERE NOT flag_valor_atipico) AS valor_total
    FROM silver.contratos WHERE origen IS NOT NULL
    GROUP BY origen
) a
WHERE d.codigo = a.origen;

-- ---------------------------------------------------------------------
-- 6.2 La tabla de hechos
-- ---------------------------------------------------------------------
-- El LEFT JOIN con cada dimension trae la clave ya resuelta, y el COALESCE
-- con -1 es la red de seguridad: si el INSERT de la dimension se executed
-- con un filtro distinto al de aqui, la fila no se pierde, cae en el
-- miembro desconocido y la consulta del bloque 8 lo delata.
--
-- El rango se controla con dos variables de psql, lote_desde y lote_hasta, y
-- se traduce a un filtro sobre id_fila, que es el identificador estable de la
-- version. Los valores por defecto (0 y 999999999999) cargan todo de una vez.
--
-- OJO, esto no es el modo por lotes con commit que usa el resto del proyecto.
-- Un INSERT ... SELECT de 13 millones de filas en una sola transaccion
-- mantiene WAL y bloqueos hasta el final, y en una maquina de desarrollo se
-- queda sin espacio en disco a mitad de camino. Para cargar de verdad por
-- lotes, hay que invocar este mismo script una vez por tramo, terminando cada
-- invocacion para que psql cierre su transaccion:
--
--     psql -f sql/02_modelo_gold.sql -v lote_desde=0      -v lote_hasta=500000
--     psql -f sql/02_modelo_gold.sql -v lote_desde=500000  -v lote_hasta=1000000
--     ...
--
-- Es incomodo a proposito, por una razon que conviene no perder de vista: cada
-- invocacion vuelve a correr los bloques 1 a 6.1, y por eso estos tienen que
-- ser idempotentes. Un script de carga que solo funcionara la primera vez
-- obligaria a recorrer 27 tramos a mano y a contar filas a mano.
INSERT INTO gold.fact_contrato (
    fecha_firma, id_fila, fecha_firma_es_centinela,
    fecha_inicio, fecha_fin, numero_contrato, numero_proceso,
    valor_contrato, valor_ajustado, objeto_contrato, url_contrato,
    es_atipico, es_valor_extremo, es_valor_cero, es_valor_relleno,
    es_valor_repetido, es_version_contrato, es_fecha_invalida,
    es_fechas_incoherentes,
    id_entidad, id_proveedor, id_tipo_contrato, id_modalidad, id_estado, id_origen
)
SELECT
    coalesce(s.fecha_firma, DATE '1900-01-01'),
    s.id_fila,
    s.fecha_firma IS NULL,
    s.fecha_inicio,
    s.fecha_fin,
    s.id_contrato,
    s.id_proceso,
    s.valor_contrato,
    s.valor_ajustado,
    s.objeto_contrato,
    s.url_contrato,
    coalesce(s.flag_valor_atipico,       false),
    coalesce(s.flag_valor_extremo,      false),
    coalesce(s.flag_valor_cero,         false),
    coalesce(s.flag_valor_relleno,      false),
    coalesce(s.flag_valor_repetido,     false),
    coalesce(s.flag_version_contrato,   false),
    coalesce(s.flag_fecha_invalida,     false),
    coalesce(s.flag_fechas_incoherentes, false),
    coalesce(de.id_entidad,       -1),
    coalesce(dp.id_proveedor,     -1),
    coalesce(dtc.id_tipo_contrato, -1),
    coalesce(dm.id_modalidad,     -1),
    coalesce(de2.id_estado,       -1),
    coalesce(do_.id_origen,       -1)
FROM silver.contratos s
LEFT JOIN gold.dim_entidad       de  ON de.codigo_entidad   = s.codigo_entidad
LEFT JOIN gold.dim_proveedor     dp  ON dp.documento        = s.documento_proveedor
LEFT JOIN gold.dim_tipo_contrato dtc ON dtc.codigo          = s.tipo_contrato
LEFT JOIN gold.dim_modalidad     dm  ON dm.codigo           = s.modalidad
LEFT JOIN gold.dim_estado        de2 ON de2.codigo          = s.estado_proceso
LEFT JOIN gold.dim_origen        do_ ON do_.codigo          = s.origen
WHERE s.id_fila > :lote_desde AND s.id_fila <= :lote_hasta;

-- =====================================================================
-- 7. LAS VISTAS  ·  RF-13, origen unico para Power BI
-- =====================================================================
-- Dos vistas, y la division es deliberada:
--
--   v_contratos          todo, con las banderas. Para auditoria, QA y para
--                        medir cuantos contratos hay de cada tipo incluso
--                        con los atipicos.
--   v_contratos_validos  el filtro ya aplicado: sin centinelas de fecha, sin
--                        filas con fecha invalida y sin atipicos. Es la que
--                        se conecta a Power BI.
--
-- El motivo de que exista v_contratos_validos y no sea instruccion de
-- "filtrar en el tablero": un filtro en Power BI es una opcion que se puede
-- desactivar con un clic, y en un tablero que llega a una-directional es la
-- unica proteccion que separa el numero que se presenta del numero que es un
-- error del dato. Si la vista ya viene filtrada, el tablero no puede
-- mostrar un total contaminado por ningun camino.
-- =====================================================================

CREATE OR REPLACE VIEW gold.v_contratos AS
SELECT
    f.id_fila,
    f.fecha_firma,
    t.anio,
    t.trimestre,
    t.mes,
    f.numero_contrato,
    f.numero_proceso,
    f.valor_contrato,
    f.valor_ajustado,
    f.fecha_inicio,
    f.fecha_fin,
    f.duracion_dias,
    e.nombre_entidad,
    e.nivel_entidad,
    e.departamento,
    e.municipio,
    p.nombre_proveedor,
    p.documento,
    p.tipo_documento,
    p.es_persona_natural,
    tc.descripcion AS tipo_contrato,
    m.descripcion  AS modalidad,
    es.descripcion AS estado,
    o.descripcion  AS origen,
    f.objeto_contrato,
    f.url_contrato,
    f.es_atipico,
    f.es_valor_extremo,
    f.es_valor_cero,
    f.es_valor_repetido,
    f.es_version_contrato,
    f.es_fecha_invalida,
    f.es_fechas_incoherentes
FROM gold.fact_contrato f
JOIN gold.dim_entidad       e  ON e.id_entidad        = f.id_entidad
JOIN gold.dim_proveedor     p  ON p.id_proveedor      = f.id_proveedor
JOIN gold.dim_tipo_contrato tc ON tc.id_tipo_contrato = f.id_tipo_contrato
JOIN gold.dim_modalidad     m  ON m.id_modalidad      = f.id_modalidad
JOIN gold.dim_estado        es ON es.id_estado        = f.id_estado
JOIN gold.dim_origen        o  ON o.id_origen         = f.id_origen
JOIN gold.dim_tiempo        t  ON t.fecha             = f.fecha_firma;

COMMENT ON VIEW gold.v_contratos IS
    'Todos los contratos con las banderas de calidad a la vista. Para auditoria y QA.';

CREATE OR REPLACE VIEW gold.v_contratos_validos AS
SELECT *
FROM gold.v_contratos
WHERE NOT es_atipico
  AND NOT es_fecha_invalida;

COMMENT ON VIEW gold.v_contratos_validos IS
    'La vista de Power BI. Sin valores atipicos, sin filas con fecha invalida y sin el centinela 1900-01-01. Los totales de dinero y los cortes por ano de esta vista son los que se publican.';

-- =====================================================================
-- 8. PERMISOS
-- =====================================================================
-- secop_lectura ve gold y nada mas. En staging/bronze y silver no se concede
-- nada, y como un esquema recien creado no le da privilegios a PUBLIC, el rol
-- de lectura no ve siquiera la existencia de las capas anteriores.
--
-- El ALTER DEFAULT PRIVILEGES lleva FOR ROLE secop_etl explicito. Sin el se
-- aplica a los objetos del rol que ejecuta el script y las tablas de gold se
-- quedan sin permiso, que es un fallo que no da error en ninguna parte: la
-- base funciona y Power BI no ve nada.
GRANT USAGE ON SCHEMA gold TO secop_lectura;
ALTER DEFAULT PRIVILEGES FOR ROLE secop_etl IN SCHEMA gold
    GRANT SELECT ON TABLES TO secop_lectura;
GRANT SELECT ON ALL TABLES IN SCHEMA gold TO secop_lectura;

-- =====================================================================
-- 9. VERIFICACION
-- =====================================================================
\echo ''
\echo '=== 9. Verificacion del modelo gold ==='

\echo '-- 9.1 Las 7 dimensiones y la tabla de hechos (deben ser 8 objetos):'
SELECT count(*) AS objetos_gold
FROM pg_tables WHERE schemaname = 'gold';

\echo '-- 9.2 Cardinalidades reales. ESTAS SON LAS CIFRAS OFICIALES DEL MODELO.'
\echo '--     dim_proveedor y dim_entidad son las que hay que mirar: si una'
\echo '--     sale en millones, el modelo esta bien; si sale en miles, la'
\echo '--     normalizacion de R8 no llego a oro.'
SELECT relname AS tabla, n_live_tup AS filas,
       pg_size_pretty(pg_total_relation_size(relid)) AS total
FROM pg_stat_user_tables
WHERE schemaname = 'gold'
ORDER BY n_live_tup DESC;

\echo '-- 9.3 Las particiones de fact_contrato (deben ser 13):'
SELECT count(*) AS particiones
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
JOIN pg_class p ON p.oid = i.inhparent
WHERE p.relname = 'fact_contrato';

\echo '-- 9.4 TODAS las particiones deben estar en gold. Si alguna sale en'
\echo '--     otro esquema, se repitio el bug del %I sin cualificar:'
SELECT n.nspname AS esquema, count(*) AS particiones
FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE i.inhparent = 'gold.fact_contrato'::regclass
GROUP BY n.nspname;

\echo '-- 9.5 Integridad de claves foraneas. Los 7 conteos deben dar 0.'
\echo '--     dim_tiempo se comprueba aparte: como es la clave de particion,'
\echo '--     cualquier fecha_firma sin fila en el calendario habria fallado'
\echo '--     al insertar, asi que el conteo es una red de seguridad, no una'
\echo '--     comprobacion que pueda salir mal.'
SELECT
  (SELECT count(*) FROM gold.fact_contrato f LEFT JOIN gold.dim_entidad       d ON d.id_entidad        = f.id_entidad       WHERE d.id_entidad        IS NULL) AS huerfanos_entidad,
  (SELECT count(*) FROM gold.fact_contrato f LEFT JOIN gold.dim_proveedor     d ON d.id_proveedor      = f.id_proveedor     WHERE d.id_proveedor      IS NULL) AS huerfanos_proveedor,
  (SELECT count(*) FROM gold.fact_contrato f LEFT JOIN gold.dim_tipo_contrato d ON d.id_tipo_contrato  = f.id_tipo_contrato  WHERE d.id_tipo_contrato  IS NULL) AS huerfanos_tipo,
  (SELECT count(*) FROM gold.fact_contrato f LEFT JOIN gold.dim_modalidad     d ON d.id_modalidad      = f.id_modalidad      WHERE d.id_modalidad      IS NULL) AS huerfanos_modalidad,
  (SELECT count(*) FROM gold.fact_contrato f LEFT JOIN gold.dim_estado        d ON d.id_estado         = f.id_estado         WHERE d.id_estado         IS NULL) AS huerfanos_estado,
  (SELECT count(*) FROM gold.fact_contrato f LEFT JOIN gold.dim_origen        d ON d.id_origen         = f.id_origen         WHERE d.id_origen         IS NULL) AS huerfanos_origen,
  (SELECT count(*) FROM gold.fact_contrato f LEFT JOIN gold.dim_tiempo        d ON d.fecha             = f.fecha_firma       WHERE d.fecha             IS NULL) AS huerfanos_tiempo;

\echo '-- 9.6 El grano: fact_contrato debe tener exactamente las filas de plata:'
SELECT
  (SELECT count(*) FROM silver.contratos)                     AS plata,
  (SELECT count(*) FROM gold.fact_contrato)                   AS oro,
  (SELECT count(*) FROM silver.contratos) - (SELECT count(*) FROM gold.fact_contrato) AS diferencia;

\echo '-- 9.7 La PK no se puede repetir. Debe dar 0:'
SELECT count(*) AS pk_duplicada FROM (
    SELECT fecha_firma, id_fila FROM gold.fact_contrato
    GROUP BY 1, 2 HAVING count(*) > 1
) d;

\echo '-- 9.8 Cuantas filas cayeron en el miembro desconocido -1.'
\echo '--     Un numero alto en id_entidad o id_proveedor no es un error del'
\echo '--     modelo: es la medida del vacio del origen (4,00% de NIT, y el'
\echo '--     que se lleve el documento de proveedor). Se reporta, no se corrige:'
SELECT
  count(*) FILTER (WHERE id_entidad       = -1) AS sin_entidad,
  count(*) FILTER (WHERE id_proveedor     = -1) AS sin_proveedor,
  count(*) FILTER (WHERE id_tipo_contrato = -1) AS sin_tipo,
  count(*) FILTER (WHERE id_modalidad     = -1) AS sin_modalidad,
  count(*) FILTER (WHERE id_estado        = -1) AS sin_estado,
  count(*) FILTER (WHERE id_origen        = -1) AS sin_origen,
  count(*) FILTER (WHERE fecha_firma_es_centinela) AS con_fecha_centinela
FROM gold.fact_contrato;

\echo '-- 9.9 La comprobacion que de verdad importa: el dinero.'
\echo '--     valor_ajustado sin atipicos debe acercarse a las cifras oficiales'
\echo '--     de Colombia Compra Eficiente (~100 billones en 2018):'
SELECT extract(year FROM fecha_firma) AS anio,
       count(*) AS filas,
       round(sum(valor_ajustado) / 1e12, 2) AS billones_bruto,
       round(sum(valor_ajustado) FILTER (WHERE NOT es_atipico) / 1e12, 2) AS billones_limpio
FROM gold.fact_contrato
GROUP BY 1 ORDER BY 1;

\echo '-- 9.10 Grano contra grano: las filas son versiones, no contratos. Las tres'
\echo '--      cifras NO tienen por que coincidir, y esa es la prueba de que'
\echo '--      el grano quedo en la version y no se subio a proposito al contrato.'
\echo '--      filas - numeros_distintos = las filas que son versiones adicionales.'
SELECT
  count(*)                                                   AS filas,
  count(DISTINCT numero_contrato)                            AS numeros_distintos,
  count(*) FILTER (WHERE es_version_contrato)                AS filas_con_versiones
FROM gold.fact_contrato;

\echo '-- 9.11 Las banderas de calidad, ya en oro:'
SELECT count(*) AS filas,
       count(*) FILTER (WHERE es_atipico)              AS atipicos,
       count(*) FILTER (WHERE es_valor_extremo)        AS extremos,
       count(*) FILTER (WHERE es_valor_cero)           AS valor_cero,
       count(*) FILTER (WHERE es_valor_relleno)        AS valor_relleno,
       count(*) FILTER (WHERE es_valor_repetido)       AS valor_repetido,
       count(*) FILTER (WHERE es_version_contrato)     AS versiones,
       count(*) FILTER (WHERE es_fecha_invalida)       AS fecha_invalida,
       count(*) FILTER (WHERE es_fechas_incoherentes)  AS fechas_incoherentes
FROM gold.fact_contrato;

\echo '-- 9.12 dim_tiempo completa, sin huecos y con el centinela:'
SELECT
  (SELECT count(*) FROM gold.dim_tiempo) = 47847 AS filas_ok,
  (SELECT count(*) FROM gold.dim_tiempo WHERE es_centinela) = 1 AS centinela_ok,
  (SELECT count(*) FROM (SELECT generate_series(DATE '1900-01-01', DATE '2030-12-31', INTERVAL '1 day')::date AS f
                         EXCEPT SELECT fecha FROM gold.dim_tiempo) h) = 0 AS sin_huecos;

\echo '-- 9.13 El usuario de solo-lectura ve gold y nada mas:'
SELECT has_schema_privilege('secop_lectura','gold','USAGE')  AS ve_gold,
       has_schema_privilege('secop_lectura','silver','USAGE') AS ve_silver;

\echo ''
\echo '### Modelo gold listo. Ahora cargar (bloque 6.2) y despues verificar.'
