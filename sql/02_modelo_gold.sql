-- =====================================================================
-- 02_modelo_gold.sql  ·  SECOP Integrado  ·  Entregable 2 (Kerin)
-- Capa GOLD: modelo en estrella construido desde silver.contratos.
-- =====================================================================
-- Base de datos : secop_dw
-- Lee          : silver.contratos  (13.005.402 filas, validada 42/42)
-- Escribe      : gold.dim_* y gold.fact_contrato
-- Documento    : docs/modelo_relacional.md
-- Requisitos   : RQ01-RQ14, RF-06, RF-12, RF-13, RF-21, RF-22, RNF-04
--
-- MODELO (derivado de los requerimientos de negocio):
--   5 dimensiones: dim_tiempo, dim_entidad, dim_ubicacion,
--                  dim_proveedor, dim_contrato
--   1 hecho      : fact_contrato (grano = una VERSION de contrato)
--
-- QUE HACE ESTE SCRIPT Y QUE NO
--   HACE   : crea las 5 dimensiones y la tabla de hechos de la capa oro.
--   NO HACE: no toca bronze ni silver. El unico DROP es el del bloque
--            "modo recrear", y solo afecta a gold.
--
-- REJECUTABLE
--   psql -U secop_etl -d secop_dw -f sql/02_modelo_gold.sql
--   psql -U secop_etl -d secop_dw -v recrear=1 -f sql/02_modelo_gold.sql
--
-- Si existia una version anterior de gold (7 dimensiones), usar recrear=1:
-- sin ese modo, CREATE TABLE IF NOT EXISTS dejaria las tablas viejas.
--
-- REGLAS DE NEGOCIO DEFINIDAS EN ESTE ARCHIVO (no son mediciones):
--   * tipo_persona        -> gold.clasificar_persona()
--   * agrupacion_estado   -> gold.agrupacion_estado() y gold.rango_estado()
--   * es_competitiva      -> bloque 3.4 y UPDATE del bloque 6.1
--   * valor_gastado       -> bloque 6.2 (valor contratado vigente; la fuente
--                            NO trae valor pagado ni ejecutado)
-- =====================================================================

\set ON_ERROR_STOP on
\pset pager off

\if :{?recrear}
\else
    \set recrear 0
\endif

-- Lote de carga del bloque 6.2 (filtra por id_fila).
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

-- El esquema se garantiza ANTES del bloque de DROP.
CREATE SCHEMA IF NOT EXISTS gold;

\if :recrear
    -- Primero vistas y hechos (referencian a las dimensiones).
    DROP VIEW     IF EXISTS gold.v_contratos_validos CASCADE;
    DROP VIEW     IF EXISTS gold.v_contratos         CASCADE;
    DROP TABLE    IF EXISTS gold.fact_contrato        CASCADE;
    -- Dimensiones del modelo vigente
    DROP TABLE    IF EXISTS gold.dim_tiempo           CASCADE;
    DROP TABLE    IF EXISTS gold.dim_entidad          CASCADE;
    DROP TABLE    IF EXISTS gold.dim_ubicacion        CASCADE;
    DROP TABLE    IF EXISTS gold.dim_proveedor        CASCADE;
    DROP TABLE    IF EXISTS gold.dim_contrato         CASCADE;
    -- Dimensiones del modelo anterior (7 dimensiones), por si existen
    DROP TABLE    IF EXISTS gold.dim_tipo_contrato    CASCADE;
    DROP TABLE    IF EXISTS gold.dim_modalidad        CASCADE;
    DROP TABLE    IF EXISTS gold.dim_estado           CASCADE;
    DROP TABLE    IF EXISTS gold.dim_origen           CASCADE;
    DROP TABLE    IF EXISTS gold.dim_tipo_documento   CASCADE;
    -- Las secuencias se reinician para que una reconstruccion produzca
    -- los mismos sk_ que la original.
    DROP SEQUENCE IF EXISTS gold.seq_entidad;
    DROP SEQUENCE IF EXISTS gold.seq_ubicacion;
    DROP SEQUENCE IF EXISTS gold.seq_proveedor;
    DROP SEQUENCE IF EXISTS gold.seq_contrato;
    DROP SEQUENCE IF EXISTS gold.seq_tipo_contrato;
    DROP SEQUENCE IF EXISTS gold.seq_modalidad;
    DROP SEQUENCE IF EXISTS gold.seq_estado;
    DROP SEQUENCE IF EXISTS gold.seq_origen;
\endif

-- =====================================================================
-- 0. ROLES DE LECTURA
-- =====================================================================
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
-- 1. FUNCIONES DE REGLAS DE NEGOCIO
-- =====================================================================
-- Son IMMUTABLE: el resultado depende solo de los argumentos.

-- 1.1 sk_fecha: fecha -> clave entera AAAAMMDD. NULL -> -1 (SIN FECHA).
CREATE OR REPLACE FUNCTION gold.sk_fecha(d date) RETURNS integer
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN d IS NULL THEN -1
                ELSE extract(year  FROM d)::int * 10000
                   + extract(month FROM d)::int * 100
                   + extract(day   FROM d)::int
           END
$$;

-- 1.2 rango_estado: posicion del estado en el ciclo de vida (RF-22).
--     REGLA DE NEGOCIO PROVISIONAL, no medicion. Sirve para que R5 conserve
--     el estado de mayor avance. El orden de SUSPENDIDO y CEDIDO es juicio
--     del equipo. 0 = estado desconocido.
CREATE OR REPLACE FUNCTION gold.rango_estado(e text) RETURNS smallint
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN e IN ('BORRADOR', 'EN APROBACION', 'ENVIADO PROVEEDOR',
                   'CONVOCADO', 'ADJUDICADO')                          THEN 1
        WHEN e IN ('APROBADO', 'ACTIVO', 'CELEBRADO')                  THEN 2
        WHEN e IN ('EN EJECUCION', 'MODIFICADO', 'PRORROGADO')         THEN 3
        WHEN e IN ('SUSPENDIDO', 'CEDIDO')                             THEN 4
        WHEN e IN ('TERMINADO', 'TERMINADO SIN LIQUIDAR', 'LIQUIDADO') THEN 5
        WHEN e = 'CERRADO'                                             THEN 6
        WHEN e = 'CANCELADO' OR e LIKE 'TERMINADO ANORMALMENTE%'       THEN 7
        ELSE 0
    END::smallint
$$;

-- 1.3 agrupacion_estado: nombre de cada rango.
CREATE OR REPLACE FUNCTION gold.agrupacion_estado(e text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE gold.rango_estado(e)
        WHEN 1 THEN 'PRECONTRACTUAL'
        WHEN 2 THEN 'INICIO'
        WHEN 3 THEN 'VIGENTE'
        WHEN 4 THEN 'SUSPENDIDO O CEDIDO'
        WHEN 5 THEN 'TERMINADO'
        WHEN 6 THEN 'CERRADO'
        WHEN 7 THEN 'CANCELADO'
        ELSE 'NO REGISTRA'
    END
$$;

-- 1.4 clasificar_persona (RF-12). REGLA DE NEGOCIO, no medicion.
--     El tipo 'NIT' generico es ambiguo. HEURISTICA: documento de 9 digitos
--     que empieza por 8 o 9 -> JURIDICA (cubre el 94,5% de los NIT genericos).
--     En plata el NIT ya llega sin digito de verificacion (R8).
CREATE OR REPLACE FUNCTION gold.clasificar_persona(tipo_doc text, documento text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN tipo_doc IN ('CEDULA DE CIUDADANIA', 'NIT DE PERSONA NATURAL',
                          'CEDULA DE EXTRANJERIA', 'PASAPORTE',
                          'TARJETA DE IDENTIDAD', 'REGISTRO CIVIL', 'NUIP',
                          'CARNE DIPLOMATICO',
                          'PERMISO POR PROTECCION TEMPORAL',
                          'PERMISO ESPECIAL DE PERMANENCIA')            THEN 'NATURAL'
        WHEN tipo_doc IN ('NIT DE PERSONA JURIDICA', 'SOCIEDADES EXTRANJERAS',
                          'NUMERO DE FIDEICOMISO')                      THEN 'JURIDICA'
        WHEN tipo_doc = 'NIT' AND documento ~ '^[89][0-9]{8}$'          THEN 'JURIDICA'
        ELSE 'NO CLASIFICADO'
    END
$$;

COMMENT ON FUNCTION gold.clasificar_persona(text, text) IS
    'Regla de negocio (no medicion). NATURAL / JURIDICA / NO CLASIFICADO segun el tipo de documento de plata. Heuristica para el tipo NIT generico: 9 digitos que empiezan por 8 o 9 = JURIDICA.';
COMMENT ON FUNCTION gold.rango_estado(text) IS
    'Regla de negocio provisional. Posicion del estado en el ciclo de vida (1 precontractual ... 7 cancelado, 0 desconocido). La usa R5 para conservar el estado de mayor avance.';

-- =====================================================================
-- 2. dim_tiempo  ·  calendario 2000-2060 + registro -1 SIN FECHA
-- =====================================================================
-- Calendario puro, NO derivado de los contratos: se genera con
-- generate_series y existe completo aunque un dia no tenga contratos.
--
-- CLAVE: sk_tiempo = entero AAAAMMDD (20180315). Es legible y es un entero,
-- que PostgreSQL acepta como clave de particion. Por eso ya NO hace falta
-- usar la fecha como clave ni duplicarla en la tabla de hechos.
--
-- AUSENCIA DE FECHA: la fila sk_tiempo = -1 'SIN FECHA' (fecha NULL) es el
-- miembro desconocido, igual que en las demas dimensiones. Reemplaza al
-- centinela 1900-01-01 del modelo anterior.
--
-- RANGO 2000-2060: plata deja fecha_firma en [2000-01-01, fecha de descarga]
-- y fecha_inicio / fecha_fin en [2000-01-01, 2060-12-31] (regla R4). Toda
-- fecha valida de plata tiene fila aqui.
-- 22.281 dias = 61 anios * 365 + 16 bisiestos (2000, 2004, ... 2060).
-- Con el registro -1 son 22.282 filas.
--
-- EL CAST A ::timestamp NO ES COSMETICO. Con un DATE, PostgreSQL resuelve
-- generate_series contra TIMESTAMPTZ y con la zona America/Bogota la serie
-- puede terminar antes de tiempo.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS gold.dim_tiempo (
    sk_tiempo      integer  PRIMARY KEY,
    fecha          date     UNIQUE,
    anio           smallint,
    semestre       smallint,
    trimestre      smallint,
    mes            smallint,
    nombre_mes     text,
    dia            smallint,
    dia_semana     smallint,
    nombre_dia     text,
    es_fin_semana  boolean,
    es_sin_fecha   boolean  NOT NULL DEFAULT false,
    CONSTRAINT dim_tiempo_rango CHECK (
        sk_tiempo = -1
        OR fecha BETWEEN DATE '2000-01-01' AND DATE '2060-12-31')
);

COMMENT ON TABLE gold.dim_tiempo IS
    'Calendario 2000-01-01 a 2060-12-31 (22.281 dias) mas el registro -1 SIN FECHA. Clave entera AAAAMMDD. Se usa con 3 roles en fact_contrato: firma, inicio y fin.';
COMMENT ON COLUMN gold.dim_tiempo.es_sin_fecha IS
    'TRUE solo en sk_tiempo = -1. Todo KPI temporal debe excluirlo.';

INSERT INTO gold.dim_tiempo (sk_tiempo, es_sin_fecha)
VALUES (-1, true)
ON CONFLICT (sk_tiempo) DO NOTHING;

INSERT INTO gold.dim_tiempo (
    sk_tiempo, fecha, anio, semestre, trimestre, mes, nombre_mes,
    dia, dia_semana, nombre_dia, es_fin_semana, es_sin_fecha
)
SELECT
    gold.sk_fecha(d::date),
    d::date,
    extract(year    FROM d)::smallint,
    CASE WHEN extract(month FROM d) <= 6 THEN 1 ELSE 2 END::smallint,
    extract(quarter FROM d)::smallint,
    extract(month   FROM d)::smallint,
    to_char(d, 'TMMonth'),
    extract(day     FROM d)::smallint,
    extract(dow     FROM d)::smallint,
    to_char(d, 'TMDay'),
    extract(isodow  FROM d) >= 6,
    false
FROM generate_series(DATE '2000-01-01'::timestamp,
                     DATE '2060-12-31'::timestamp,
                     INTERVAL '1 day') AS d
ON CONFLICT (sk_tiempo) DO NOTHING;

-- =====================================================================
-- 3. LAS 4 DIMENSIONES CATEGORICAS
-- =====================================================================
-- Todas llevan un registro sk = -1 'NO REGISTRA' (miembro desconocido):
--   a) las claves foraneas del hecho son NOT NULL con DEFAULT -1, asi que
--      ninguna fila se pierde ni queda huerfana;
--   b) "cuantos contratos no traen entidad" es un WHERE contra una fila.
-- Se usa -1 y no 0 porque 0 se confunde con un valor real; y no NULL porque
-- el NULL real se conserva en silver.contratos (capa de auditoria).
--
-- La normalizacion (mayusculas, sin tildes, homologacion) ocurrio en PLATA
-- (R1, R3), asi que los UNIQUE son planos, sin collation especial.
-- Se usan SEQUENCE y no IDENTITY para poder insertar explicitamente el -1.
-- ---------------------------------------------------------------------

-- 3.1 dim_entidad
-- La ubicacion NO va aqui: vive en dim_ubicacion (RQ05).
-- Clave natural: codigo_entidad (el NIT tiene 4,00% de vacios).
CREATE SEQUENCE IF NOT EXISTS gold.seq_entidad;
CREATE TABLE IF NOT EXISTS gold.dim_entidad (
    sk_entidad      integer NOT NULL DEFAULT nextval('gold.seq_entidad'),
    codigo_entidad  text    NOT NULL,
    nit_entidad     text,
    nombre_entidad  text,
    nivel_entidad   text,
    CONSTRAINT dim_entidad_pk PRIMARY KEY (sk_entidad),
    CONSTRAINT dim_entidad_codigo_key UNIQUE (codigo_entidad)
);
COMMENT ON TABLE gold.dim_entidad IS
    'Entidad contratante. Clave natural codigo_entidad. Responde RQ01, RQ03, RQ07. sk_entidad = -1 es el miembro desconocido.';

-- 3.2 dim_ubicacion  (separada de dim_entidad, RQ05)
-- Una fila por par (departamento, municipio) tal como llega de plata.
-- Los NULL se guardan como 'NO REGISTRA' para que el UNIQUE funcione.
CREATE SEQUENCE IF NOT EXISTS gold.seq_ubicacion;
CREATE TABLE IF NOT EXISTS gold.dim_ubicacion (
    sk_ubicacion  integer NOT NULL DEFAULT nextval('gold.seq_ubicacion'),
    departamento  text    NOT NULL,
    municipio     text    NOT NULL,
    CONSTRAINT dim_ubicacion_pk PRIMARY KEY (sk_ubicacion),
    CONSTRAINT dim_ubicacion_key UNIQUE (departamento, municipio)
);
COMMENT ON TABLE gold.dim_ubicacion IS
    'Departamento y municipio de la entidad contratante (RQ05). El par (NO REGISTRA, NO REGISTRA) es el miembro desconocido, sk_ubicacion = -1.';

-- 3.3 dim_proveedor
-- Documento ya normalizado en plata (R8): solo digitos, NIT sin digito de
-- verificacion. El tipo de documento NO se modela: se resume en tipo_persona.
CREATE SEQUENCE IF NOT EXISTS gold.seq_proveedor;
CREATE TABLE IF NOT EXISTS gold.dim_proveedor (
    sk_proveedor         integer NOT NULL DEFAULT nextval('gold.seq_proveedor'),
    documento_proveedor  text    NOT NULL,
    nombre_proveedor     text,
    tipo_persona         text    NOT NULL DEFAULT 'NO CLASIFICADO',
    CONSTRAINT dim_proveedor_pk PRIMARY KEY (sk_proveedor),
    CONSTRAINT dim_proveedor_documento_key UNIQUE (documento_proveedor),
    CONSTRAINT dim_proveedor_tipo_persona_chk
        CHECK (tipo_persona IN ('NATURAL', 'JURIDICA', 'NO CLASIFICADO'))
);
COMMENT ON TABLE gold.dim_proveedor IS
    'Proveedor / contratista. Clave natural documento_proveedor. tipo_persona (RQ10) es una regla de negocio, ver gold.clasificar_persona. Si un mismo documento aparece con tipos distintos, JURIDICA gana sobre NATURAL y NATURAL sobre NO CLASIFICADO.';

-- 3.4 dim_contrato
-- Combina modalidad, tipo de contrato, estado y origen: son atributos que
-- clasifican al contrato y no tienen sentido analitico por separado
-- (RQ03, RQ06, RQ08, RQ11, RQ13). Una fila por combinacion existente.
CREATE SEQUENCE IF NOT EXISTS gold.seq_contrato;
CREATE TABLE IF NOT EXISTS gold.dim_contrato (
    sk_contrato        integer  NOT NULL DEFAULT nextval('gold.seq_contrato'),
    modalidad          text     NOT NULL,
    es_competitiva     boolean,
    tipo_contrato      text     NOT NULL,
    estado_proceso     text     NOT NULL,
    agrupacion_estado  text     NOT NULL,
    rango_estado       smallint NOT NULL,
    origen             text     NOT NULL,
    CONSTRAINT dim_contrato_pk PRIMARY KEY (sk_contrato),
    CONSTRAINT dim_contrato_key UNIQUE (modalidad, tipo_contrato, estado_proceso, origen)
);
COMMENT ON TABLE gold.dim_contrato IS
    'Clasificacion del contrato: modalidad, tipo, estado y origen (SECOPI / SECOPII, se conservan separados). El miembro desconocido (sk = -1) es la combinacion NO REGISTRA en los cuatro campos.';
COMMENT ON COLUMN gold.dim_contrato.es_competitiva IS
    'Regla de negocio. FALSE = contratacion NO competitiva: CONTRATACION DIRECTA, OTRAS FORMAS DE CONTRATACION DIRECTA y REGIMEN ESPECIAL. TRUE = las demas modalidades (licitacion, seleccion abreviada, concurso de meritos, minima cuantia, etc.). NULL = modalidad desconocida. Es la base del porcentaje de contratacion directa y de regimen especial (RQ03).';
COMMENT ON COLUMN gold.dim_contrato.agrupacion_estado IS
    'Regla de negocio (ver gold.rango_estado). PRECONTRACTUAL y CANCELADO no cuentan en valor_gastado.';

-- =====================================================================
-- 4. REGISTROS -1
-- =====================================================================
-- Se insertan antes del hecho: las FK con DEFAULT -1 necesitan que la fila
-- exista en el momento de la carga.
INSERT INTO gold.dim_entidad (sk_entidad, codigo_entidad, nombre_entidad)
VALUES (-1, 'NO REGISTRA', 'NO REGISTRA')
ON CONFLICT DO NOTHING;

INSERT INTO gold.dim_ubicacion (sk_ubicacion, departamento, municipio)
VALUES (-1, 'NO REGISTRA', 'NO REGISTRA')
ON CONFLICT DO NOTHING;

INSERT INTO gold.dim_proveedor (sk_proveedor, documento_proveedor, nombre_proveedor, tipo_persona)
VALUES (-1, 'NO REGISTRA', 'NO REGISTRA', 'NO CLASIFICADO')
ON CONFLICT DO NOTHING;

INSERT INTO gold.dim_contrato (sk_contrato, modalidad, es_competitiva, tipo_contrato,
                               estado_proceso, agrupacion_estado, rango_estado, origen)
VALUES (-1, 'NO REGISTRA', NULL, 'NO REGISTRA', 'NO REGISTRA', 'NO REGISTRA', 0, 'NO REGISTRA')
ON CONFLICT DO NOTHING;

-- =====================================================================
-- 5. gold.fact_contrato  ·  tabla de hechos
-- =====================================================================
-- GRANO: una fila de fact_contrato = una fila de silver.contratos
--        = UNA VERSION DE CONTRATO (13.005.402), no un contrato.
-- SECOP II publica cada modificacion como una fila; el dataset no dice cual
-- es la vigente. R7b deja valor_ajustado = valor_contrato / n en cada una de
-- las n versiones, de modo que SUM(valor_ajustado) da el valor del contrato
-- UNA vez.
--
-- MEDIDAS
--   valor_contrato  tal cual llega. Se conserva por fidelidad. NO se suma.
--   valor_ajustado  la que se suma. Para dinero, excluir es_atipico.
--   valor_gastado   valor contratado VIGENTE (RQ14, RF-21). Definicion
--                   derivada: la fuente no trae valor pagado ni ejecutado,
--                   asi que NUNCA se presenta como dinero pagado.
--                   = valor_ajustado si el contrato no es atipico y su
--                     agrupacion_estado NO es PRECONTRACTUAL, CANCELADO ni
--                     NO REGISTRA; en cualquier otro caso = 0.
--   duracion_dias   fecha_fin - fecha_inicio (NULL si falta alguna).
--   contrato_unidad = 1 en cada fila; permite contar versiones con SUM.
--
-- LLAVES FORANEAS: 7 enteras. dim_tiempo participa con 3 roles
-- (firma, inicio, fin); las otras 4 dimensiones, con una cada una.
-- LLAVES DEGENERADAS: solo id_contrato e id_proceso.
--
-- CLAVE PRIMARIA: (sk_fecha_firma, id_fila). id_fila NO se genera: es
-- silver.contratos.id_fila = bronze.secop_raw.id_fila, lo que permite
-- auditar una cifra hasta el CSV con un JOIN (RNF-06). PostgreSQL exige que
-- la PK incluya la clave de particion.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS gold.fact_contrato (
    sk_fecha_firma   integer NOT NULL DEFAULT -1
                     CONSTRAINT fk_fact_fecha_firma
                     REFERENCES gold.dim_tiempo(sk_tiempo),
    id_fila          bigint  NOT NULL,

    sk_fecha_inicio  integer NOT NULL DEFAULT -1
                     CONSTRAINT fk_fact_fecha_inicio
                     REFERENCES gold.dim_tiempo(sk_tiempo),
    sk_fecha_fin     integer NOT NULL DEFAULT -1
                     CONSTRAINT fk_fact_fecha_fin
                     REFERENCES gold.dim_tiempo(sk_tiempo),
    sk_entidad       integer NOT NULL DEFAULT -1
                     REFERENCES gold.dim_entidad(sk_entidad),
    sk_ubicacion     integer NOT NULL DEFAULT -1
                     REFERENCES gold.dim_ubicacion(sk_ubicacion),
    sk_proveedor     integer NOT NULL DEFAULT -1
                     REFERENCES gold.dim_proveedor(sk_proveedor),
    sk_contrato      integer NOT NULL DEFAULT -1
                     REFERENCES gold.dim_contrato(sk_contrato),

    -- Llaves degeneradas
    id_contrato      text,
    id_proceso       text,

    -- Medidas
    valor_contrato   numeric(18,2),
    valor_ajustado   numeric(18,2),
    valor_gastado    numeric(18,2) NOT NULL DEFAULT 0,
    duracion_dias    integer,
    contrato_unidad  smallint NOT NULL DEFAULT 1,

    -- Banderas de calidad heredadas de silver (sin el prefijo flag_)
    es_atipico              boolean NOT NULL DEFAULT false,
    es_valor_extremo        boolean NOT NULL DEFAULT false,
    es_valor_cero           boolean NOT NULL DEFAULT false,
    es_valor_relleno        boolean NOT NULL DEFAULT false,
    es_valor_repetido       boolean NOT NULL DEFAULT false,
    es_version_contrato     boolean NOT NULL DEFAULT false,
    es_fecha_invalida       boolean NOT NULL DEFAULT false,
    es_fechas_incoherentes  boolean NOT NULL DEFAULT false,

    -- No se pone WITH (fillfactor) aqui: la tabla madre no tiene
    -- almacenamiento. Se aplica a cada particion (bloque 5.1).
    CONSTRAINT fact_contrato_pk PRIMARY KEY (sk_fecha_firma, id_fila)
) PARTITION BY RANGE (sk_fecha_firma);

COMMENT ON TABLE gold.fact_contrato IS
    'Grano: 1 fila por fila de silver.contratos = UNA VERSION DE CONTRATO. SUM(valor_ajustado) es correcto; para dinero excluir es_atipico. valor_gastado es el valor contratado vigente, no el pagado.';
COMMENT ON COLUMN gold.fact_contrato.valor_ajustado IS
    'LA medida que se suma. valor_contrato / n (R7 y R7b). Sumar valor_contrato da 692 billones en 2018 frente a los ~100 oficiales.';
COMMENT ON COLUMN gold.fact_contrato.valor_gastado IS
    'Valor contratado vigente (regla de negocio, no valor pagado). = valor_ajustado si NOT es_atipico y agrupacion_estado no es PRECONTRACTUAL, CANCELADO ni NO REGISTRA; 0 en los demas casos.';
COMMENT ON COLUMN gold.fact_contrato.id_fila IS
    '= silver.contratos.id_fila = bronze.secop_raw.id_fila. Trazabilidad hasta el CSV de origen en un JOIN.';
COMMENT ON COLUMN gold.fact_contrato.duracion_dias IS
    'fecha_fin - fecha_inicio. NULL si falta alguna. Las duraciones negativas estan marcadas con es_fechas_incoherentes y no se corrigen.';

-- ---------------------------------------------------------------------
-- 5.1 Particiones (13)
-- ---------------------------------------------------------------------
--   cuarentena pre2017  -1 y todo lo anterior a 2017   1
--   anuales 2017 a 2027                                11
--   por defecto (desde 2028 en adelante)                1
--   Total                                              13
-- Anadir 2028 es un CREATE TABLE ... PARTITION OF, sin migrar filas.
CREATE TABLE IF NOT EXISTS gold.fact_contrato_pre2017
    PARTITION OF gold.fact_contrato
    FOR VALUES FROM (MINVALUE) TO (20170101)
    WITH (fillfactor = 90);
COMMENT ON TABLE gold.fact_contrato_pre2017 IS
    'Cuarentena: filas sin fecha de firma (sk_fecha_firma = -1) y cualquier firma anterior a 2017. Se espera con muy pocas filas (3 sin fecha en plata).';

DO $crear_particiones$
DECLARE
    v_anio integer;
BEGIN
    -- El esquema va como %I propio. Con un solo %I el nombre sale sin
    -- cualificar y la particion se crea en public (bug del modelo anterior).
    FOR v_anio IN 2017..2027 LOOP
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I.%I PARTITION OF gold.fact_contrato'
            ' FOR VALUES FROM (%s) TO (%s) WITH (fillfactor = 90)',
            'gold',
            'fact_contrato_y' || v_anio,
            v_anio * 10000 + 101,
            (v_anio + 1) * 10000 + 101
        );
    END LOOP;
END
$crear_particiones$;

CREATE TABLE IF NOT EXISTS gold.fact_contrato_resto
    PARTITION OF gold.fact_contrato DEFAULT
    WITH (fillfactor = 90);
COMMENT ON TABLE gold.fact_contrato_resto IS
    'Particion por defecto. Si no esta vacia, hay una firma posterior a 2027: el corte se movio.';

-- ---------------------------------------------------------------------
-- 5.2 Indices (7)
-- ---------------------------------------------------------------------
-- La PK (sk_fecha_firma, id_fila) ya resuelve los rangos de fecha, asi que
-- el unico indice adicional por fecha es un BRIN.
CREATE INDEX IF NOT EXISTS ix_fact_fecha_brin
    ON gold.fact_contrato USING brin (sk_fecha_firma)
    WITH (pages_per_range = 32, autosummarize = on);

-- Consulta mas frecuente: cuanto se contrato en un anio y cuanto dinero.
CREATE INDEX IF NOT EXISTS ix_fact_anio_valor
    ON gold.fact_contrato (sk_fecha_firma, valor_ajustado);

CREATE INDEX IF NOT EXISTS ix_fact_proveedor  ON gold.fact_contrato (sk_proveedor);
CREATE INDEX IF NOT EXISTS ix_fact_entidad    ON gold.fact_contrato (sk_entidad);
CREATE INDEX IF NOT EXISTS ix_fact_ubicacion  ON gold.fact_contrato (sk_ubicacion);
CREATE INDEX IF NOT EXISTS ix_fact_contrato   ON gold.fact_contrato (sk_contrato);
CREATE INDEX IF NOT EXISTS ix_fact_id_contrato ON gold.fact_contrato (id_contrato);

-- NO hay indice sobre es_atipico: es un booleano casi siempre falso.
-- NO hay indice sobre valor_ajustado suelto: ix_fact_anio_valor lo cubre.

-- =====================================================================
-- 6. CARGA DE GOLD
-- =====================================================================
-- El bloque 6.1 (dimensiones) es idempotente: ON CONFLICT evita duplicar y
-- el UPDATE refresca atributos. El bloque 6.2 (hechos) NO lo es: para
-- recargarlo, usar -v recrear=1.
--
-- Para cargar los hechos por tramos (cada invocacion cierra su transaccion):
--     psql -f sql/02_modelo_gold.sql -v lote_desde=0       -v lote_hasta=500000
--     psql -f sql/02_modelo_gold.sql -v lote_desde=500000  -v lote_hasta=1000000
-- Los bloques 1 a 6.1 se vuelven a correr en cada tramo, por eso son
-- idempotentes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 6.1 Las 4 dimensiones categoricas
-- ---------------------------------------------------------------------
-- dim_entidad y dim_proveedor se cargan con GROUP BY (no DISTINCT): una
-- misma clave puede venir con atributos distintos y max() elige uno; los
-- originales siguen en silver y se recuperan por id_fila.

INSERT INTO gold.dim_entidad (codigo_entidad, nit_entidad, nombre_entidad, nivel_entidad)
SELECT codigo_entidad, max(nit_entidad), max(nombre_entidad), max(nivel_entidad)
FROM silver.contratos
WHERE codigo_entidad IS NOT NULL
GROUP BY codigo_entidad
ON CONFLICT ON CONSTRAINT dim_entidad_codigo_key DO NOTHING;

UPDATE gold.dim_entidad d SET
    nit_entidad    = a.nit_entidad,
    nombre_entidad = a.nombre_entidad,
    nivel_entidad  = a.nivel_entidad
FROM (
    SELECT codigo_entidad, max(nit_entidad) AS nit_entidad,
           max(nombre_entidad) AS nombre_entidad, max(nivel_entidad) AS nivel_entidad
    FROM silver.contratos
    WHERE codigo_entidad IS NOT NULL
    GROUP BY codigo_entidad
) a
WHERE d.codigo_entidad = a.codigo_entidad;

INSERT INTO gold.dim_ubicacion (departamento, municipio)
SELECT DISTINCT coalesce(departamento, 'NO REGISTRA'),
                coalesce(municipio,    'NO REGISTRA')
FROM silver.contratos
ON CONFLICT ON CONSTRAINT dim_ubicacion_key DO NOTHING;

-- tipo_persona por documento: si un documento aparece con varios tipos,
-- JURIDICA gana sobre NATURAL y NATURAL sobre NO CLASIFICADO.
INSERT INTO gold.dim_proveedor (documento_proveedor, nombre_proveedor, tipo_persona)
SELECT documento_proveedor,
       max(nombre_proveedor),
       CASE WHEN bool_or(p = 'JURIDICA') THEN 'JURIDICA'
            WHEN bool_or(p = 'NATURAL')  THEN 'NATURAL'
            ELSE 'NO CLASIFICADO' END
FROM (
    SELECT documento_proveedor, nombre_proveedor,
           gold.clasificar_persona(tipo_doc_proveedor, documento_proveedor) AS p
    FROM silver.contratos
    WHERE documento_proveedor IS NOT NULL
) x
GROUP BY documento_proveedor
ON CONFLICT ON CONSTRAINT dim_proveedor_documento_key DO NOTHING;

UPDATE gold.dim_proveedor d SET
    nombre_proveedor = a.nombre_proveedor,
    tipo_persona     = a.tipo_persona
FROM (
    SELECT documento_proveedor,
           max(nombre_proveedor) AS nombre_proveedor,
           CASE WHEN bool_or(p = 'JURIDICA') THEN 'JURIDICA'
                WHEN bool_or(p = 'NATURAL')  THEN 'NATURAL'
                ELSE 'NO CLASIFICADO' END AS tipo_persona
    FROM (
        SELECT documento_proveedor, nombre_proveedor,
               gold.clasificar_persona(tipo_doc_proveedor, documento_proveedor) AS p
        FROM silver.contratos
        WHERE documento_proveedor IS NOT NULL
    ) x
    GROUP BY documento_proveedor
) a
WHERE d.documento_proveedor = a.documento_proveedor;

-- NULL::boolean es obligatorio: en un SELECT DISTINCT un NULL sin tipo se
-- resuelve como text y no se puede asignar a es_competitiva (boolean).
-- Los valores reales los fija el UPDATE de abajo.
INSERT INTO gold.dim_contrato (modalidad, tipo_contrato, estado_proceso, origen,
                               es_competitiva, agrupacion_estado, rango_estado)
SELECT DISTINCT
       coalesce(modalidad,      'NO REGISTRA'),
       coalesce(tipo_contrato,  'NO REGISTRA'),
       coalesce(estado_proceso, 'NO REGISTRA'),
       coalesce(origen,         'NO REGISTRA'),
       NULL::boolean, 'NO REGISTRA'::text, 0::smallint
FROM silver.contratos
ON CONFLICT ON CONSTRAINT dim_contrato_key DO NOTHING;

-- Los atributos derivados se recalculan siempre: si cambia una regla de
-- negocio, basta volver a correr este UPDATE.
UPDATE gold.dim_contrato SET
    es_competitiva    = CASE WHEN modalidad = 'NO REGISTRA' THEN NULL
                             ELSE modalidad NOT IN ('CONTRATACION DIRECTA',
                                                    'OTRAS FORMAS DE CONTRATACION DIRECTA',
                                                    'REGIMEN ESPECIAL') END,
    agrupacion_estado = gold.agrupacion_estado(estado_proceso),
    rango_estado      = gold.rango_estado(estado_proceso)
WHERE sk_contrato <> -1;

-- ---------------------------------------------------------------------
-- 6.2 La tabla de hechos
-- ---------------------------------------------------------------------
-- El LEFT JOIN trae cada clave y el COALESCE con -1 es la red de seguridad:
-- una fila sin dimension cae en el miembro desconocido, no se pierde.
-- Las fechas se convierten a clave entera con gold.sk_fecha (NULL -> -1).
INSERT INTO gold.fact_contrato (
    sk_fecha_firma, id_fila, sk_fecha_inicio, sk_fecha_fin,
    sk_entidad, sk_ubicacion, sk_proveedor, sk_contrato,
    id_contrato, id_proceso,
    valor_contrato, valor_ajustado, valor_gastado, duracion_dias,
    es_atipico, es_valor_extremo, es_valor_cero, es_valor_relleno,
    es_valor_repetido, es_version_contrato, es_fecha_invalida,
    es_fechas_incoherentes
)
SELECT
    gold.sk_fecha(s.fecha_firma),
    s.id_fila,
    gold.sk_fecha(s.fecha_inicio),
    gold.sk_fecha(s.fecha_fin),
    coalesce(de.sk_entidad,   -1),
    coalesce(du.sk_ubicacion, -1),
    coalesce(dp.sk_proveedor, -1),
    coalesce(dc.sk_contrato,  -1),
    s.id_contrato,
    s.id_proceso,
    s.valor_contrato,
    s.valor_ajustado,
    CASE WHEN NOT coalesce(s.flag_valor_atipico, false)
          AND coalesce(dc.agrupacion_estado, 'NO REGISTRA')
              NOT IN ('PRECONTRACTUAL', 'CANCELADO', 'NO REGISTRA')
         THEN coalesce(s.valor_ajustado, 0)
         ELSE 0 END,
    s.fecha_fin - s.fecha_inicio,
    coalesce(s.flag_valor_atipico,        false),
    coalesce(s.flag_valor_extremo,        false),
    coalesce(s.flag_valor_cero,           false),
    coalesce(s.flag_valor_relleno,        false),
    coalesce(s.flag_valor_repetido,       false),
    coalesce(s.flag_version_contrato,     false),
    coalesce(s.flag_fecha_invalida,       false),
    coalesce(s.flag_fechas_incoherentes,  false)
FROM silver.contratos s
LEFT JOIN gold.dim_entidad   de ON de.codigo_entidad      = s.codigo_entidad
LEFT JOIN gold.dim_ubicacion du ON du.departamento        = coalesce(s.departamento, 'NO REGISTRA')
                               AND du.municipio           = coalesce(s.municipio,    'NO REGISTRA')
LEFT JOIN gold.dim_proveedor dp ON dp.documento_proveedor = s.documento_proveedor
LEFT JOIN gold.dim_contrato  dc ON dc.modalidad           = coalesce(s.modalidad,      'NO REGISTRA')
                               AND dc.tipo_contrato       = coalesce(s.tipo_contrato,  'NO REGISTRA')
                               AND dc.estado_proceso      = coalesce(s.estado_proceso, 'NO REGISTRA')
                               AND dc.origen              = coalesce(s.origen,         'NO REGISTRA')
WHERE s.id_fila > :lote_desde AND s.id_fila <= :lote_hasta;

-- =====================================================================
-- 7. VISTAS  ·  RF-13, origen unico para Power BI
-- =====================================================================
--   v_contratos          todo, con banderas. Para auditoria y QA.
--   v_contratos_validos  filtro ya aplicado. Es la que se conecta a Power BI.
-- El filtro vive en la vista y no en el tablero: un filtro de Power BI se
-- puede desactivar con un clic.
-- =====================================================================
CREATE OR REPLACE VIEW gold.v_contratos AS
SELECT
    f.id_fila,
    f.sk_fecha_firma,
    tf.fecha         AS fecha_firma,
    tf.anio, tf.semestre, tf.trimestre, tf.mes, tf.nombre_mes,
    ti.fecha         AS fecha_inicio,
    tn.fecha         AS fecha_fin,
    f.id_contrato,
    f.id_proceso,
    e.codigo_entidad, e.nombre_entidad, e.nit_entidad, e.nivel_entidad,
    u.departamento,   u.municipio,
    p.documento_proveedor, p.nombre_proveedor, p.tipo_persona,
    c.modalidad, c.es_competitiva, c.tipo_contrato,
    c.estado_proceso, c.agrupacion_estado, c.rango_estado, c.origen,
    f.valor_contrato,
    f.valor_ajustado,
    f.valor_gastado,
    f.duracion_dias,
    f.contrato_unidad,
    f.es_atipico, f.es_valor_extremo, f.es_valor_cero, f.es_valor_relleno,
    f.es_valor_repetido, f.es_version_contrato, f.es_fecha_invalida,
    f.es_fechas_incoherentes
FROM gold.fact_contrato f
JOIN gold.dim_tiempo     tf ON tf.sk_tiempo    = f.sk_fecha_firma
JOIN gold.dim_tiempo     ti ON ti.sk_tiempo    = f.sk_fecha_inicio
JOIN gold.dim_tiempo     tn ON tn.sk_tiempo    = f.sk_fecha_fin
JOIN gold.dim_entidad    e  ON e.sk_entidad    = f.sk_entidad
JOIN gold.dim_ubicacion  u  ON u.sk_ubicacion  = f.sk_ubicacion
JOIN gold.dim_proveedor  p  ON p.sk_proveedor  = f.sk_proveedor
JOIN gold.dim_contrato   c  ON c.sk_contrato   = f.sk_contrato;

COMMENT ON VIEW gold.v_contratos IS
    'Todas las versiones de contrato con las banderas de calidad a la vista. Para auditoria y QA.';

CREATE OR REPLACE VIEW gold.v_contratos_validos AS
SELECT *
FROM gold.v_contratos
WHERE NOT es_atipico
  AND NOT es_fecha_invalida
  AND sk_fecha_firma <> -1;

COMMENT ON VIEW gold.v_contratos_validos IS
    'La vista de Power BI. Sin valores atipicos, sin filas con fecha invalida y sin firma ausente (sk_fecha_firma = -1). Los totales de dinero de esta vista son los que se publican.';

-- =====================================================================
-- 8. PERMISOS
-- =====================================================================
-- secop_lectura ve gold y nada mas. El FOR ROLE secop_etl es obligatorio:
-- sin el, el permiso por defecto se aplica a los objetos de quien ejecuta
-- el script y Power BI no veria las tablas (falla silencioso).
GRANT USAGE ON SCHEMA gold TO secop_lectura;
ALTER DEFAULT PRIVILEGES FOR ROLE secop_etl IN SCHEMA gold
    GRANT SELECT ON TABLES TO secop_lectura;
GRANT SELECT ON ALL TABLES IN SCHEMA gold TO secop_lectura;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA gold TO secop_lectura;

-- =====================================================================
-- 9. VERIFICACION
-- =====================================================================
\echo ''
\echo '=== 9. Verificacion del modelo gold ==='

\echo '-- 9.1 Objetos: 5 dimensiones + 1 hecho (esperado: 6):'
SELECT count(*) AS objetos_gold
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'gold' AND c.relkind IN ('r', 'p') AND NOT c.relispartition;

\echo '-- 9.2 Cardinalidades y tamanos (cifras oficiales del modelo):'
SELECT relname AS tabla, n_live_tup AS filas,
       pg_size_pretty(pg_total_relation_size(relid)) AS total
FROM pg_stat_user_tables
WHERE schemaname = 'gold'
ORDER BY n_live_tup DESC;

\echo '-- 9.3 Particiones de fact_contrato (esperado: 13):'
SELECT count(*) AS particiones
FROM pg_inherits i
WHERE i.inhparent = 'gold.fact_contrato'::regclass;

\echo '-- 9.4 TODAS las particiones deben estar en gold (si sale otro esquema,'
\echo '--     se repitio el bug del %I sin cualificar):'
SELECT n.nspname AS esquema, count(*) AS particiones
FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE i.inhparent = 'gold.fact_contrato'::regclass
GROUP BY n.nspname;

\echo '-- 9.5 Huerfanos por clave foranea (los 7 conteos deben dar 0):'
SELECT
  (SELECT count(*) FROM gold.fact_contrato f LEFT JOIN gold.dim_tiempo    d ON d.sk_tiempo    = f.sk_fecha_firma  WHERE d.sk_tiempo    IS NULL) AS huerfanos_firma,
  (SELECT count(*) FROM gold.fact_contrato f LEFT JOIN gold.dim_tiempo    d ON d.sk_tiempo    = f.sk_fecha_inicio WHERE d.sk_tiempo    IS NULL) AS huerfanos_inicio,
  (SELECT count(*) FROM gold.fact_contrato f LEFT JOIN gold.dim_tiempo    d ON d.sk_tiempo    = f.sk_fecha_fin    WHERE d.sk_tiempo    IS NULL) AS huerfanos_fin,
  (SELECT count(*) FROM gold.fact_contrato f LEFT JOIN gold.dim_entidad   d ON d.sk_entidad   = f.sk_entidad      WHERE d.sk_entidad   IS NULL) AS huerfanos_entidad,
  (SELECT count(*) FROM gold.fact_contrato f LEFT JOIN gold.dim_ubicacion d ON d.sk_ubicacion = f.sk_ubicacion    WHERE d.sk_ubicacion IS NULL) AS huerfanos_ubicacion,
  (SELECT count(*) FROM gold.fact_contrato f LEFT JOIN gold.dim_proveedor d ON d.sk_proveedor = f.sk_proveedor    WHERE d.sk_proveedor IS NULL) AS huerfanos_proveedor,
  (SELECT count(*) FROM gold.fact_contrato f LEFT JOIN gold.dim_contrato  d ON d.sk_contrato  = f.sk_contrato     WHERE d.sk_contrato  IS NULL) AS huerfanos_contrato;

\echo '-- 9.6 El grano: oro debe tener exactamente las filas de plata (diferencia 0):'
SELECT
  (SELECT count(*) FROM silver.contratos)   AS plata,
  (SELECT count(*) FROM gold.fact_contrato) AS oro,
  (SELECT count(*) FROM silver.contratos) - (SELECT count(*) FROM gold.fact_contrato) AS diferencia;

\echo '-- 9.7 PK duplicada (debe dar 0):'
SELECT count(*) AS pk_duplicada FROM (
    SELECT sk_fecha_firma, id_fila FROM gold.fact_contrato
    GROUP BY 1, 2 HAVING count(*) > 1
) d;

\echo '-- 9.8 Filas en el miembro desconocido -1 (mide el vacio del origen,'
\echo '--     no es un error del modelo):'
SELECT
  count(*) FILTER (WHERE sk_entidad     = -1) AS sin_entidad,
  count(*) FILTER (WHERE sk_ubicacion   = -1) AS sin_ubicacion,
  count(*) FILTER (WHERE sk_proveedor   = -1) AS sin_proveedor,
  count(*) FILTER (WHERE sk_contrato    = -1) AS sin_clasificacion,
  count(*) FILTER (WHERE sk_fecha_firma = -1) AS sin_fecha_firma,
  count(*) FILTER (WHERE sk_fecha_inicio = -1) AS sin_fecha_inicio,
  count(*) FILTER (WHERE sk_fecha_fin   = -1) AS sin_fecha_fin
FROM gold.fact_contrato;

\echo '-- 9.9 El dinero por anio (billones). Sin atipicos debe acercarse a las'
\echo '--     cifras oficiales (~100 en 2018). valor_gastado debe ser <= limpio:'
SELECT t.anio,
       count(*) AS filas,
       round(sum(f.valor_ajustado) / 1e12, 2)                                    AS billones_bruto,
       round(sum(f.valor_ajustado) FILTER (WHERE NOT f.es_atipico) / 1e12, 2)    AS billones_limpio,
       round(sum(f.valor_gastado) / 1e12, 2)                                     AS billones_gastado
FROM gold.fact_contrato f
JOIN gold.dim_tiempo t ON t.sk_tiempo = f.sk_fecha_firma
GROUP BY t.anio ORDER BY t.anio;

\echo '-- 9.10 Grano contra grano: filas son versiones, no contratos:'
SELECT
  count(*)                                    AS filas,
  count(DISTINCT id_contrato)                 AS contratos_distintos,
  count(*) FILTER (WHERE es_version_contrato) AS filas_con_versiones
FROM gold.fact_contrato;

\echo '-- 9.11 Banderas de calidad en oro:'
SELECT count(*) AS filas,
       count(*) FILTER (WHERE es_atipico)             AS atipicos,
       count(*) FILTER (WHERE es_valor_extremo)       AS extremos,
       count(*) FILTER (WHERE es_valor_cero)          AS valor_cero,
       count(*) FILTER (WHERE es_valor_relleno)       AS valor_relleno,
       count(*) FILTER (WHERE es_valor_repetido)      AS valor_repetido,
       count(*) FILTER (WHERE es_version_contrato)    AS versiones,
       count(*) FILTER (WHERE es_fecha_invalida)      AS fecha_invalida,
       count(*) FILTER (WHERE es_fechas_incoherentes) AS fechas_incoherentes
FROM gold.fact_contrato;

\echo '-- 9.12 dim_tiempo: 22.282 filas (22.281 dias + el -1), sin huecos:'
SELECT
  (SELECT count(*) FROM gold.dim_tiempo) = 22282                       AS filas_ok,
  (SELECT count(*) FROM gold.dim_tiempo WHERE es_sin_fecha) = 1        AS sin_fecha_ok,
  (SELECT count(*) FROM (SELECT generate_series(DATE '2000-01-01'::timestamp,
                                                DATE '2060-12-31'::timestamp,
                                                INTERVAL '1 day')::date AS f
                         EXCEPT SELECT fecha FROM gold.dim_tiempo) h) = 0 AS sin_huecos;

\echo '-- 9.13 tipo_persona por FILA (esperado: NATURAL 10.372.323, JURIDICA'
\echo '--      1.909.481, NO CLASIFICADO 723.598; suman 13.005.402). Una'
\echo '--      diferencia pequena indica documentos con tipos contradictorios:'
SELECT p.tipo_persona, count(*) AS filas
FROM gold.fact_contrato f
JOIN gold.dim_proveedor p ON p.sk_proveedor = f.sk_proveedor
GROUP BY p.tipo_persona ORDER BY filas DESC;

\echo '-- 9.14 Estados sin agrupar (debe dar 0 filas; un estado nuevo no mapeado'
\echo '--      cae en NO REGISTRA y queda fuera de valor_gastado):'
SELECT estado_proceso, count(*) AS combinaciones
FROM gold.dim_contrato
WHERE agrupacion_estado = 'NO REGISTRA' AND estado_proceso <> 'NO REGISTRA'
GROUP BY estado_proceso;

\echo '-- 9.15 Ciclo de vida: filas y valor_gastado por agrupacion de estado:'
SELECT c.agrupacion_estado, c.rango_estado, count(*) AS filas,
       round(sum(f.valor_gastado) / 1e12, 2) AS billones_gastado
FROM gold.fact_contrato f
JOIN gold.dim_contrato c ON c.sk_contrato = f.sk_contrato
GROUP BY 1, 2 ORDER BY 2;

\echo '-- 9.16 valor_gastado no puede exceder el valor ajustado limpio (debe dar 0):'
SELECT count(*) AS gastado_mayor_que_ajustado
FROM gold.fact_contrato
WHERE valor_gastado > coalesce(valor_ajustado, 0);

\echo '-- 9.17 El usuario de solo-lectura ve gold y nada mas:'
SELECT has_schema_privilege('secop_lectura', 'gold',   'USAGE') AS ve_gold,
       has_schema_privilege('secop_lectura', 'silver', 'USAGE') AS ve_silver;

\echo ''
\echo '### Modelo gold listo. Si los hechos no se cargaron, revisar el bloque 6.2.'