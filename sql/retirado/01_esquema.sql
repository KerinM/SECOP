-- =====================================================================
-- 01_esquema.sql  ·  SECOP Integrado  ·  Entregable 2 (Kerin)
-- Modelo fisico: capa Staging (fiel al origen) + Silver (tipada y
-- depurada) + Gold (estrella analitica particionada por anio).
-- =====================================================================
-- Origen: SECOP Integrado, 22.670.028 filas, 22 columnas.
-- Las 22 columnas y su orden NO estan inventados: son los fieldName
-- que devuelve https://www.datos.gov.co/api/views/rpmr-utcd.json, y el
-- encabezado que devuelve /resource/rpmr-utcd.csv. El CSV usa
-- exactamente esos nombres, por eso staging puede hacer COPY directo.
--
-- Reejecucion: este script es IDEMPOTENTE. Se puede correr las veces que
-- haga falta sin romper nada. Para reconstruir desde cero:
--     psql -v recrear=1 -f sql/01_esquema.sql
-- Sin -v recrear, si las tablas ya existen no se tocan.
-- =====================================================================

\set ON_ERROR_STOP on
\pset pager off

-- psql no tiene valores por defecto para sus variables, asi que si no se
-- pasa -v recrear=1 el nombre quedaria literal y \if lo interpretaria
-- como una expresion booleana. Por eso se lepone 0 antes de preguntarlo.
\if :{?recrear}
\else
\set recrear 0
\endif

\if :recrear
\echo ''
\echo '### MODO RECREAR: se eliminan las tablas existentes de staging, silver y gold.'
\else
\echo ''
\echo '### MODO NORMAL: solo se crea lo que falta. Use -v recrear=1 para reconstruir.'
\endif

-- ---------------------------------------------------------------------
-- 0. Modo recrear
-- ---------------------------------------------------------------------
\if :recrear
    DROP TABLE IF EXISTS gold.fact_contrato        CASCADE;
    DROP TABLE IF EXISTS gold.dim_tiempo           CASCADE;
    DROP TABLE IF EXISTS gold.dim_entidad          CASCADE;
    DROP TABLE IF EXISTS gold.dim_proveedor        CASCADE;
    DROP TABLE IF EXISTS gold.dim_tipo_contrato    CASCADE;
    DROP TABLE IF EXISTS gold.dim_modalidad         CASCADE;
    DROP TABLE IF EXISTS gold.dim_origen           CASCADE;
    DROP TABLE IF EXISTS gold.dim_tipo_documento   CASCADE;
    DROP TABLE IF EXISTS silver.contrato           CASCADE;
    DROP TABLE IF EXISTS staging.contratos_raw     CASCADE;
\endif

-- =====================================================================
-- 1. Funciones de limpieza  (capa silver)
-- =====================================================================
-- Se definen antes que las tablas porque el ETL las usa al poblar silver.
-- Las tres son IMMUTABLE y PARALLEL SAFE: se pueden usar en indices, en
-- columnas generadas y en consultas que el planificador decia mover.
-- ---------------------------------------------------------------------
-- 1.1 es_fecha_valida
-- Las 3 columnas de fecha del origen vienen en ISO 8601 con hora:
--     "2011-09-16T00:00:00.000"
-- Hay 1.767.413 sin fecha de firma, 106 con anio 2099, 4.000+ con anio
-- 8201 y 1.000+ con anio 1899 (volumetria.md 8.1). Esta funcion
-- devuelve NULL en vez de dejar que un cast reviente la carga.
--
-- POR QUE NO HAY UN BLOQUE EXCEPTION. Un bloque EXCEPTION por fila se
-- pagaria 68 millones de veces en una carga completa (3 fechas x
-- 22.670.028) y ahogaria el COPY.
--
-- Y POR QUE NO SE USA make_date A CIEGAS. Se asumio al principio que
-- make_date devuelve NULL con un mes invalido. Es FALSO: medido en
-- esta base, make_date(9999,99,99), make_date(2019,2,30) y
-- make_date(0,1,1) lanzan los tres "date field value out of range".
-- make_date valida y revienta; no devuelve NULL.
--
-- La solucion es no llamar a make_date hasta tener un triple que sea
-- seguro: anio 1-9999, mes 1-12 y dia dentro del mes. El dia maximo
-- del mes se calcula con make_date(anio, mes, 1), que con mes 1-12
-- nunca falla. Todo va dentro de CASE, que PostgreSQL evalua de forma
-- cortocircuitada: la rama THEN solo se llega a evaluar si la
-- condicion es cierta. Asi la funcion no puede lanzar nunca.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION silver.es_fecha_valida(
    p_texto text,
    p_min   date DEFAULT DATE '1990-01-01',
    p_max   date DEFAULT DATE '2030-12-31'
)
RETURNS date
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    WITH numeros AS (
        SELECT
            CASE WHEN btrim(p_texto) ~ '^\d{4}-\d{2}-\d{2}'
                 THEN substring(btrim(p_texto) FROM 1 FOR 4)::int END AS anio,
            CASE WHEN btrim(p_texto) ~ '^\d{4}-\d{2}-\d{2}'
                 THEN substring(btrim(p_texto) FROM 6 FOR 2)::int END AS mes,
            CASE WHEN btrim(p_texto) ~ '^\d{4}-\d{2}-\d{2}'
                 THEN substring(btrim(p_texto) FROM 9 FOR 2)::int END AS dia
    ), alcance AS (
        SELECT
            n.anio, n.mes, n.dia,
            -- Ultimo dia del mes. make_date(anio, mes, 1) es seguro
            -- porque mes ya quedo validado entre 1 y 12. No se puede
            -- castear date a int directamente, asi que se extrae el dia
            -- del mes del timestamp resultante.
            CASE WHEN n.anio BETWEEN 1 AND 9999 AND n.mes BETWEEN 1 AND 12
                 THEN extract(day FROM
                        (make_date(n.anio, n.mes, 1)
                         + interval '1 month' - interval '1 day'))::int
            END AS dia_maximo
        FROM numeros n
        WHERE n.anio BETWEEN 1 AND 9999
          AND n.mes  BETWEEN 1 AND 12
    ), candidato AS (
        SELECT CASE WHEN a.dia BETWEEN 1 AND a.dia_maximo
                    THEN make_date(a.anio, a.mes, a.dia)
               END AS fecha
        FROM alcance a
    )
    -- Ultimo filtro: el rango plausible. Por eso 1899, 2099 y 8201
    -- devuelven NULL aunque sean fechas de calendario perfectly valid.
    SELECT CASE WHEN c.fecha BETWEEN p_min AND p_max THEN c.fecha END
    FROM candidato c;
$$;

COMMENT ON FUNCTION silver.es_fecha_valida(text, date, date) IS
    'Convierte un texto ISO 8601 a date, o NULL si no es una fecha real o cae fuera de [p_min, p_max]. No lanza excepciones: valida anio, mes y dia antes de llamar a make_date, que en esta version revienta con fechas imposibles.';

-- ---------------------------------------------------------------------
-- 1.2 normaliza_texto
-- Colapsa las diferencias de caja y de espacios que trae el origen.
-- Medido (volumetria.md 8.3): tipo_de_contrato 33 -> ~20 valores,
-- modalidad 38 -> ~22, estado 30 -> ~20, nivel_entidad 7 -> 4.
-- Ojo: el texto de objetos llega con caja rota en el ORIGEN, no aqui
-- ("ADQUISICIoN", "CRIPTOGRaFICOS", "INToS"). normaliza_texto solo
-- limpia la etiqueta de la dimension, no el texto libre.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION silver.normaliza_texto(p_texto text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT nullif(regexp_replace(btrim(p_texto), '\s+', ' ', 'g'), '')
$$;

COMMENT ON FUNCTION silver.normaliza_texto(text) IS
    'Recorta extremos, colapsa espacios internos y devuelve NULL si queda vacio.';

-- ---------------------------------------------------------------------
-- 1.3 normaliza_documento
-- El documento del proveedor NO viene limpio. Formatos reales medidos:
--     "830.084.433-7"   (NIT de persona juridica)
--     "28.428.107"      (cedula de ciudadania)
--     "900123456-7"     (sin separadores)
-- Sin normalizar, la misma persona aparece 3 veces en dim_proveedor y
-- el conteo de 3.364.090 proveedores de la volumetria esta inflado.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION silver.normaliza_documento(p_texto text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT nullif(
        regexp_replace(
            regexp_replace(upper(btrim(coalesce(p_texto, ''))), '[\.\- ]', '', 'g'),
            '\s+', '', 'g'
        ),
    '')
$$;

COMMENT ON FUNCTION silver.normaliza_documento(text) IS
    'Quita puntos, guiones y espacios, y pasa a mayusculas. Deja el documento como clave comparable: 830.084.433-7 = 8300844337.';

-- =====================================================================
-- 2. CAPA STAGING  ·  zona de aterrizaje
-- =====================================================================
-- Las 22 columnas tal cual las manda la API, todas en TEXT.
-- Sin tipos, sin CHECK, sin indices, sin NOT NULL: aqui llega todo,
-- incluso lo roto. El unico trabajo de esta capa es recibir el CSV
-- por COPY lo mas rapido posible.
-- El nombre de las columnas es el fieldName de la API, no un nombre
-- limpio, porque COPY empareja por posicion y el encabezado del CSV
-- trae esos mismos nombres.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.contratos_raw (
    nivel_entidad                  text,
    codigo_entidad_en_secop        text,
    nombre_de_la_entidad           text,
    nit_de_la_entidad              text,
    departamento_entidad           text,
    municipio_entidad              text,
    estado_del_proceso             text,
    modalidad_de_contrataci_n      text,
    objeto_a_contratar             text,
    objeto_del_proceso             text,
    tipo_de_contrato               text,
    fecha_de_firma_del_contrato    text,
    fecha_inicio_ejecuci_n         text,
    fecha_fin_ejecuci_n            text,
    numero_del_contrato            text,
    numero_de_proceso              text,
    valor_contrato                 text,
    nom_raz_social_contratista     text,
    url_contrato                   text,
    origen                         text,
    tipo_documento_proveedor       text,
    documento_proveedor            text
);

COMMENT ON TABLE staging.contratos_raw IS
    'Landing zone de la API SECOP Integrado. 22 columnas text, sin transformar. Origen de linea para silver.contrato.';

-- =====================================================================
-- 3. CAPA SILVER  ·  tipada, depurada, fiel al origen
-- =====================================================================
-- Se conservan los 22 nombres de origen para que la linea hacia el
-- origen sea rastreable fila por fila. Se agregan las columnas de
-- calidad y la llave sintetica.
-- silver NO deduplica: guarda las 22.670.028 filas. Es una capa de
-- auditoria; el grano lo define gold.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS silver.contrato (
    -- 22 columnas del origen, ya tipadas
    nivel_entidad                  text,
    codigo_entidad_en_secop        text,
    nombre_de_la_entidad           text,
    nit_de_la_entidad              text,
    departamento_entidad           text,
    municipio_entidad              text,
    estado_del_proceso             text,
    modalidad_de_contrataci_n      text,
    objeto_a_contratar             text,
    objeto_del_proceso             text,
    tipo_de_contrato               text,
    fecha_de_firma_del_contrato    date,
    fecha_inicio_ejecuci_n         date,
    fecha_fin_ejecuci_n            date,
    numero_del_contrato            text,
    numero_de_proceso              text,
    valor_contrato                 numeric(18,2),
    nom_raz_social_contratista     text,
    url_contrato                   text,
    origen                         text,
    tipo_documento_proveedor       text,
    documento_proveedor            text,

    -- La fecha cruda, para no perder lo que es_fecha_valida() rechazo.
    -- Sirve de evidencia cuando una fecha sale absurda (2099, 8201, 1899).
    fecha_firma_texto              text,

    -- Llave sintetica. El numero_del_contrato NO es clave: 4.621.012
    -- filas (20,38%) lo comparten (volumetria.md 3.8).
    id_contrato                    bigint GENERATED ALWAYS AS IDENTITY,

    -- Grupo de contratos repetidos, para poder agregar sin perder detalle.
    -- Rellena el ETL con dense_rank() sobre numero_del_contrato.
    id_grupo                       bigint,
    es_contrato_repetido           boolean NOT NULL DEFAULT false
);

COMMENT ON TABLE silver.contrato IS
    'Silver: copia tipada y depurada del origen, 22.670.028 filas, sin deduplicar. Las fechas imposibles quedaron en NULL y su texto original en fecha_firma_texto.';

COMMENT ON COLUMN silver.contrato.id_grupo IS
    'dense_rank() sobre numero_del_contrato. Permite contar contratos reales (18.049.016) sin perder las 4.621.012 filas de programas de revisedado.';
COMMENT ON COLUMN silver.contrato.fecha_firma_texto IS
    'Texto original de fecha_de_firma_del_contrato, conservado para auditar rechazos de es_fecha_valida().';

-- Indices de apoyo para poblar gold y para las consultas de control.
-- En silver se acepta el costo: es una capa intermedia que se
-- reconstruye desde staging, no la capa de consulta analitica.
CREATE INDEX IF NOT EXISTS ix_silver_num_contrato
    ON silver.contrato (numero_del_contrato);
CREATE INDEX IF NOT EXISTS ix_silver_firma
    ON silver.contrato (fecha_de_firma_del_contrato);

-- =====================================================================
-- 4. CAPA GOLD  ·  estrella analitica
-- =====================================================================
-- 8 dimensiones, NO 9. volumetria.md 6.3 lista dim_ubicacion, pero eso
-- solapa con dim_entidad, que ya lleva departamento y municipio
-- (17.183 entidades contra 1.131 municipios): un municipio no puede
-- depender de dos dimensiones a la vez. dim_entidad absorbe la
-- ubicacion y se documenta en decisiones_tecnicas.md.
--
-- Las 6 dimensiones de texto declaran COLLATE secop_ci en su clave.
-- secop_ci es la collation ICU no determinista creada en la sesion 1,
-- y hace que 'Compraventa' y 'COMPRAVENTA' sean la MISMA clave. Asi
-- las 6 dimensiones se normalizan solas, sin tabla de mapeo y sin
-- riesgo de que el ETL olvide un caso. Efecto medido esperado en
-- tipo_de_contrato: 33 crudos -> ~20 filas.
-- ---------------------------------------------------------------------

-- 4.1 dim_tiempo
-- Calendario, no derivada de los datos.
--
-- Arranca en 1900 y no en 1990 a proposito. fecha_firma es clave foranea
-- contra esta tabla, y las 1.767.413 filas sin fecha de firma se guardan
-- con el centinela DATE '1900-01-01'. Si el calendario empezara en 1990,
-- la FK de esas 1,77M filas fallaria en la carga.
--
-- El centinela no se confunde con ninguna fecha real: es_fecha_valida
-- rechaza por defecto todo lo anterior a 1990, asi que si fecha_firma
-- vale 1900-01-01 es porque la fila no tenia fecha, siempre.
CREATE TABLE IF NOT EXISTS gold.dim_tiempo (
    fecha           date PRIMARY KEY,
    anio            smallint NOT NULL,
    trimestre       smallint NOT NULL,
    mes             smallint  NOT NULL,
    dia             smallint  NOT NULL,
    nombre_mes      text      NOT NULL,
    dia_semana      smallint  NOT NULL,
    nombre_dia      text      NOT NULL,
    es_fin_de_semana boolean  NOT NULL,
    CONSTRAINT dim_tiempo_rango
        CHECK (fecha BETWEEN DATE '1900-01-01' AND DATE '2030-12-31')
);

COMMENT ON TABLE gold.dim_tiempo IS
    'Calendario 1900-2030 generado con generate_series, no derivado de los contratos. Empieza en 1900 para que la clave foranea fecha_firma pueda apuntar al centinela 1900-01-01.';

-- 4.2 dim_entidad
-- Absorbe la ubicacion (departamento + municipio). Es la dimension mas
-- grande despues de proveedor: 17.183 entidades.
CREATE TABLE IF NOT EXISTS gold.dim_entidad (
    id_entidad            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo_entidad        text COLLATE secop_ci NOT NULL,
    nombre_entidad        text,
    nit_entidad           text,
    nivel_entidad         text,
    departamento          text,
    municipio             text,
    CONSTRAINT dim_entidad_codigo_key UNIQUE (codigo_entidad)
);

COMMENT ON TABLE gold.dim_entidad IS
    'Entidad contratante. Clave natural codigo_entidad_en_secop, que es unico. Incluye departamento y municipio: por eso no existe dim_ubicacion (volumetria.md 6.3 la listaba por separado).';

-- 4.3 dim_proveedor
-- La dimension mas grande: 3.364.090 filas segun volumetria.md 6.3.
-- La clave es el documento NORMALIZADO, no el crudo. El origen trae
-- "830.084.433-7", "830084433-7" y "28.428.107" para la misma gente.
-- Guardar el crudo como clave daria 3 filas por persona.
CREATE TABLE IF NOT EXISTS gold.dim_proveedor (
    id_proveedor      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    documento         text COLLATE secop_ci NOT NULL,
    documento_crudo   text,
    tipo_documento    text,
    razon_social      text,
    CONSTRAINT dim_proveedor_documento_key UNIQUE (documento)
);

COMMENT ON TABLE gold.dim_proveedor IS
    'Proveedor / contratista. La clave es documento normalizado (sin puntos ni guiones). documento_crudo conserva el valor tal como vino de la API, porque el NIT y la cedula tienen formatos distintos.';

-- 4.4 a 4.9  Las seis dimensiones de texto normalizado por secop_ci
CREATE TABLE IF NOT EXISTS gold.dim_tipo_contrato (
    id_tipo_contrato  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo            text COLLATE secop_ci NOT NULL,
    descripcion       text,
    CONSTRAINT dim_tipo_contrato_codigo_key UNIQUE (codigo)
);

CREATE TABLE IF NOT EXISTS gold.dim_modalidad (
    id_modalidad      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo            text COLLATE secop_ci NOT NULL,
    descripcion       text,
    CONSTRAINT dim_modalidad_codigo_key UNIQUE (codigo)
);

CREATE TABLE IF NOT EXISTS gold.dim_estado (
    id_estado         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo            text COLLATE secop_ci NOT NULL,
    descripcion       text,
    CONSTRAINT dim_estado_codigo_key UNIQUE (codigo)
);

CREATE TABLE IF NOT EXISTS gold.dim_origen (
    id_origen         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo            text COLLATE secop_ci NOT NULL,
    descripcion       text,
    CONSTRAINT dim_origen_codigo_key UNIQUE (codigo)
);

COMMENT ON TABLE gold.dim_origen IS
    'Plataforma de origen: SECOPI y SECOPII. 2 valores (volumetria.md 6.3).';

CREATE TABLE IF NOT EXISTS gold.dim_tipo_documento (
    id_tipo_documento integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo            text COLLATE secop_ci NOT NULL,
    descripcion       text,
    CONSTRAINT dim_tipo_documento_codigo_key UNIQUE (codigo)
);

-- Poblar el calendario. ON CONFLICT por si se reejecuta.
--
-- El cast a ::timestamp es OBLIGATORIO y no es cosmetico. Si se pasa un
-- DATE tal cual, PostgreSQL resuelve generate_series a la sobrecarga de
-- TIMESTAMPTZ, y con la zona America/Bogota sumar '1 day' a un timestamptz
-- preserva la hora local: al cruzar un cambio de horario la hora se
-- desvia, la deriva se acumula ano tras ano y la serie termina ANTES de
-- tiempo. Medido en esta base: terminaba el 2030-12-30 con 14.974 filas
-- en vez de 14.975, dejando fuera el 2030-12-31. Como fecha_firma es
-- clave foranea contra esta tabla, ese dia habria hecho fallar el COPY.
--
-- El cast a ::timestamp tambien evita que la serie termine antes de tiempo.
INSERT INTO gold.dim_tiempo (
    fecha, anio, trimestre, mes, dia, nombre_mes, dia_semana, nombre_dia, es_fin_de_semana
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
    extract(isodow  FROM d) >= 6
FROM generate_series(DATE '1900-01-01'::timestamp,
                     DATE '2030-12-31'::timestamp,
                     INTERVAL '1 day') AS d
ON CONFLICT (fecha) DO NOTHING;

-- =====================================================================
-- 5. gold.fact_contrato  ·  tabla de hechos, particionada por anio
-- =====================================================================
-- Particionada por RANGE sobre fecha_firma. Anos con datos reales:
-- 2000 a 2026 (volumetria.md 7.2).
--
-- SOBRE LA CLAVE PRIMARIA. PostgreSQL no permite PK ni UNIQUE que no
-- incluyan la clave de particion. Ademas 1.767.413 filas (7,80%) NO
-- tienen fecha de firma, y una columna de PK no admite NULL. Las dos
-- cosas juntas obligan a una decision, y no es banal:
--
--   La PK es (fecha_firma, id_contrato) y por eso fecha_firma es
--   NOT NULL. Las filas sin fecha valida, o con fecha imposible, caen
--   en fact_contrato_pre2000 con fecha_firma = DATE '1900-01-01'.
--
-- El dato NO se pierde ni se mezcla con el resto:
--   * fecha_firma_es_centinela = true las marca de forma inequivoca.
--   * fecha_firma_original guarda la fecha real cuando se pudo parsear
--     (por ejemplo 1899-11-27) y NULL cuando no se pudo.
-- Cualquier KPI de contratistas o de tiempo debe filtrar
-- fecha_firma_es_centinela = false.
--
-- SOBRE LOS INDICES. volumetria.md 6.5 preveia un B-tree
-- ix_fact_fecha_firma (346 MiB) y en la misma tabla lo comparaba con un
-- BRIN (2,1 MiB). Se elige solo el BRIN por una razon que el documento
-- no menciona: como la PK empieza por fecha_firma, el B-tree de la PK
-- ya resuelve rangos de fecha. El indice adicional era redundante.
-- Con eso el tamano de indices baja de los ~2,5 GiB previstos a ~1,7 GiB.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS gold.fact_contrato (
    id_contrato                 bigint GENERATED ALWAYS AS IDENTITY,

    -- Clave de particion, y a la vez clave foranea de la 8ma dimension
    -- (dim_tiempo). Es una sola columna que cumple los dos papeles: asi
    -- son 7 FKs int = 28 B, que es lo que presupone volumetria.md 6.3.
    -- NOT NULL por la razon del bloque de arriba.
    fecha_firma                 date    NOT NULL
                                CONSTRAINT fk_fact_tiempo
                                REFERENCES gold.dim_tiempo(fecha),
    fecha_firma_es_centinela    boolean NOT NULL DEFAULT false,
    fecha_firma_original        date,

    fecha_inicio                date,
    fecha_fin                   date,

    -- Dias de duracion, derivado.
    duracion_dias               integer GENERATED ALWAYS AS (fecha_fin - fecha_inicio) STORED,

    numero_contrato             text,
    numero_proceso              text,
    valor_contrato              numeric(18,2),

    -- Se conservan LAS DOS columnas de objeto. volumetria.md 6.3
    -- proponia descartar objeto_del_proceso porque se creia que
    -- duplicaba el 100% de objeto_a_contratar. Medido sobre la API, NO
    -- es cierto: es la misma frase con la caja distinta
    -- ("ADQUISICIoN" vs "ADQUISICION"). Descartarla perderia el texto
    -- en mayusculas original. Se conserva y se documenta.
    objeto_contrato             text,
    objeto_proceso              text,
    url_contrato                text,

    -- Las 7 claves foraneas enteras. La 8ma dimension (dim_tiempo) se
    -- alcanza por fecha_firma, declarada mas arriba.
    id_entidad                  integer NOT NULL
                                REFERENCES gold.dim_entidad(id_entidad),
    id_proveedor                integer NOT NULL
                                REFERENCES gold.dim_proveedor(id_proveedor),
    id_tipo_contrato            integer NOT NULL
                                REFERENCES gold.dim_tipo_contrato(id_tipo_contrato),
    id_modalidad                integer NOT NULL
                                REFERENCES gold.dim_modalidad(id_modalidad),
    id_estado                   integer NOT NULL
                                REFERENCES gold.dim_estado(id_estado),
    id_origen                   integer NOT NULL
                                REFERENCES gold.dim_origen(id_origen),
    id_tipo_documento           integer NOT NULL
                                REFERENCES gold.dim_tipo_documento(id_tipo_documento)
    -- NO se pone WITH (fillfactor = 90) aqui. Una tabla particionada es
    -- virtual: no tiene almacenamiento propio, asi que el servidor rechaza
    -- los parametros de almacenamiento en la padre. El fillfactor se aplica
    -- a cada particion, en el bloque 5.1.
    ,
    -- La PK va DENTRO del CREATE TABLE y no en un ALTER TABLE aparte, para
    -- que el script sea idempotente de verdad. Un ALTER TABLE ... ADD
    -- CONSTRAINT PRIMARY KEY suelto se ejecuta una vez y la segunda vez
    -- falla con "no se permiten multiples llaves primarias", que es
    -- exactamente lo que paso.
    -- Compuesta porque el particionado lo obliga: no puede haber una PK que
    -- no incluya la clave de particion. Y de paso cubre los rangos de
    -- fecha, asi que no hace falta un B-tree extra sobre fecha_firma.
    CONSTRAINT fact_contrato_pk PRIMARY KEY (fecha_firma, id_contrato)
) PARTITION BY RANGE (fecha_firma);

-- PK declarada dentro del CREATE TABLE, mas arriba. No hace falta aqui un
-- ALTER TABLE: hacerlo por separado rompia la reejecucion del script.

COMMENT ON TABLE gold.fact_contrato IS
    'Tabla de hechos de contratos. Grano: 1 fila por registro del origen (22.670.028), sin deduplicar. Particionada por RANGE sobre fecha_firma (2000-2027). Las filas sin fecha valida van a fact_contrato_pre2000 con fecha_firma = 1900-01-01 y fecha_firma_es_centinela = true.';
COMMENT ON COLUMN gold.fact_contrato.fecha_firma_original IS
    'Fecha de firma real cuando se pudo parsear aunque fuera imposible (1899, 2099). NULL cuando el origen no tenia fecha o no era una fecha.';
COMMENT ON COLUMN gold.fact_contrato.duracion_dias IS
    'fecha_fin - fecha_inicio. Es NULL si falta cualquiera de las dos fechas (date - date en SQL devuelve NULL, no -1). Para medir duracion hay que filtrar ademas fecha_firma_es_centinela = false.';

-- ---------------------------------------------------------------------
-- 5.1 Particiones
-- ---------------------------------------------------------------------
-- 27 anos con datos (2000-2026) + 2027 como proyeccion + cuarentena
-- previa a 2000 + una por defecto para lo que pase de 2028. Son 30.
-- volumetria.md 7.2 estimaba 29; la diferencia es que la cuarentena va
-- antes de 2000, no en un rango de seguridad intermedio.
--
-- fillfactor 90 en TODAS las particiones, a proposito: volumetria.md 6.2
-- proyecta 983,8 B/fila CON esta holgura. Ponerlo en 100 daria un numero
-- real mas chico que la proyeccion y no se podria validar el calculo.
CREATE TABLE IF NOT EXISTS gold.fact_contrato_pre2000
    PARTITION OF gold.fact_contrato
    FOR VALUES FROM (DATE '1900-01-01') TO (DATE '2000-01-01')
    WITH (fillfactor = 90);
COMMENT ON TABLE gold.fact_contrato_pre2000 IS
    'Cuarentena: contratos de 1994-1999 y filas sin fecha valida o con fecha imposible. En la ultima parte, fecha_firma = 1900-01-01 y fecha_firma_es_centinela = true.';

DO $crear_particiones$
DECLARE
    v_anio integer;
BEGIN
    -- El esquema va como %I propio. Con un solo %I el nombre sale sin
    -- cualificar y estas 28 particiones se crean en public, no en gold:
    -- public tiene USAGE concedido a PUBLIC, asi que la tabla de hechos
    -- quedaria accesible a cualquier rol que conecte.
    FOR v_anio IN 2000..2027 LOOP
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
    'Particion por defecto: fechas posteriores a 2028, que a dia de hoy no deberia haber ninguna.';

-- ---------------------------------------------------------------------
-- 5.2 Indices
-- ---------------------------------------------------------------------
-- La PK (fecha_firma, id_contrato) ya cubre los rangos de fecha: es un
-- B-tree con fecha_firma como columna leader. Por eso NO existe
-- ix_fact_fecha_firma, y si un BRIN encima.
CREATE INDEX IF NOT EXISTS ix_fact_fecha_brin
    ON gold.fact_contrato USING brin (fecha_firma)
    WITH (pages_per_range = 32, autosummarize = on);

CREATE INDEX IF NOT EXISTS ix_fact_proveedor
    ON gold.fact_contrato (id_proveedor);

CREATE INDEX IF NOT EXISTS ix_fact_entidad
    ON gold.fact_contrato (id_entidad);

CREATE INDEX IF NOT EXISTS ix_fact_num_contrato
    ON gold.fact_contrato (numero_contrato);

-- NO hay indice sobre valor_contrato suelto: ix_fact_anio_valor ya lo
-- cubre con la fecha delante, y 802.977 filas en cero sobre 22,67M no
-- lo hacen util como punto de entrada. Medido: 639 MB recuperados.

-- Indice compuesto para el corte por anio, que es la consulta mas
-- frecuente del proyecto.
CREATE INDEX IF NOT EXISTS ix_fact_anio_valor
    ON gold.fact_contrato (fecha_firma, valor_contrato);

-- =====================================================================
-- 6. Vista de conveniencia
-- =====================================================================
-- Denormaliza para que el usuario de solo-lectura no tenga que escribir
-- los 8 JOIN. gold es el unico esquema que ve secop_lectura.
CREATE OR REPLACE VIEW gold.v_contratos AS
SELECT
    f.id_contrato,
    f.fecha_firma,
    f.fecha_firma_es_centinela,
    t.anio,
    f.numero_contrato,
    f.numero_proceso,
    f.valor_contrato,
    f.fecha_inicio,
    f.fecha_fin,
    f.duracion_dias,
    e.nombre_entidad,
    e.nivel_entidad,
    e.departamento,
    e.municipio,
    p.razon_social,
    p.documento         AS documento_proveedor,
    td.descripcion      AS tipo_documento,
    tc.descripcion      AS tipo_contrato,
    m.descripcion       AS modalidad,
    es.descripcion      AS estado,
    o.descripcion       AS origen,
    f.objeto_contrato,
    f.objeto_proceso,
    f.url_contrato
FROM gold.fact_contrato f
JOIN gold.dim_entidad        e  ON e.id_entidad           = f.id_entidad
JOIN gold.dim_proveedor      p  ON p.id_proveedor         = f.id_proveedor
JOIN gold.dim_tipo_contrato  tc ON tc.id_tipo_contrato    = f.id_tipo_contrato
JOIN gold.dim_modalidad      m  ON m.id_modalidad         = f.id_modalidad
JOIN gold.dim_estado         es ON es.id_estado           = f.id_estado
JOIN gold.dim_origen         o  ON o.id_origen            = f.id_origen
JOIN gold.dim_tipo_documento td ON td.id_tipo_documento   = f.id_tipo_documento
JOIN gold.dim_tiempo         t  ON t.fecha                = f.fecha_firma;

COMMENT ON VIEW gold.v_contratos IS
    'Vista denormalizada de contratos, con los 8 JOIN resueltos. Para consumo de secop_lectura.';

-- =====================================================================
-- 7. Permisos
-- =====================================================================
-- secop_lectura solo ve gold. El ALTER DEFAULT PRIVILEGES de la sesion 1
-- (FOR ROLE secop_etl) ya hace que las tablas nuevas le sean legibles sin
-- volver a dar GRANT. El permiso sobre las funciones y la vista hay que
-- darlos a mano.
GRANT USAGE ON SCHEMA gold TO secop_lectura;
GRANT SELECT ON ALL TABLES IN SCHEMA gold TO secop_lectura;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA silver TO secop_lectura;

-- =====================================================================
-- 8. Verificacion
-- =====================================================================
\echo ''
\echo '=== 8. Verificacion del esquema ==='

\echo '-- Tablas por capa:'
SELECT schemaname, count(*) AS tablas
FROM pg_tables
WHERE schemaname IN ('staging','silver','gold')
GROUP BY schemaname
ORDER BY schemaname;

\echo '-- Particiones de fact_contrato (deben ser 30):'
SELECT count(*) AS particiones
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
JOIN pg_class p ON p.oid = i.inhparent
WHERE p.relname = 'fact_contrato';

\echo '-- Columnas por tabla (el origen tiene 22):'
SELECT table_schema, table_name, count(*) AS columnas
FROM information_schema.columns
WHERE (table_schema, table_name) IN
      (('staging','contratos_raw'), ('silver','contrato'), ('gold','fact_contrato'))
GROUP BY table_schema, table_name
ORDER BY table_schema, table_name;

\echo '-- Filas de dim_tiempo (1900-01-01 a 2030-12-31 = 47.847 dias):'
SELECT count(*) AS dias, min(fecha) AS primera, max(fecha) AS ultima
FROM gold.dim_tiempo;

\echo '-- dim_tiempo debe ser COMPLETA y llegar hasta 1900-01-01, porque'
\echo '-- fecha_firma apunta con clave foranea al centinela 1900-01-01:'
\echo '--   1. filas = (2030-12-31 - 1900-01-01) + 1'
\echo '--   2. no hay huecos'
\echo '--   3. no hay dias repetidos'
\echo '--   4. el centinela 1900-01-01 existe'
SELECT
    (SELECT count(*) FROM gold.dim_tiempo) = 47847
        AS filas_correctas,
    (SELECT count(*) FROM gold.dim_tiempo WHERE fecha = DATE '2030-12-31') = 1
        AS incluye_2030_12_31,
    (SELECT count(*) FROM gold.dim_tiempo WHERE fecha = DATE '1900-01-01') = 1
        AS incluye_centinela_1900,
    (SELECT count(*) FROM (
        SELECT generate_series(DATE '1900-01-01', DATE '2030-12-31', INTERVAL '1 day')::date AS f
        EXCEPT
        SELECT fecha FROM gold.dim_tiempo
    ) AS h) = 0
        AS sin_huecos,
    (SELECT count(DISTINCT fecha) FROM gold.dim_tiempo)
        = (SELECT count(*) FROM gold.dim_tiempo)
        AS sin_repetidos;

\echo '-- La FK de fecha_firma contra dim_tiempo tiene que funcionar para las'
\echo '-- 1,77M filas sin fecha. Se comprueba con el centinela:'
SELECT count(*) AS centinela_resuelto_en_dim_tiempo
FROM gold.dim_tiempo
WHERE fecha = (SELECT COALESCE(fecha_de_firma_del_contrato, DATE '1900-01-01')
               FROM (VALUES (NULL::date)) AS v(fecha_de_firma_del_contrato));

\echo '-- secop_lectura ve gold y NO ve staging ni silver:'
SELECT has_schema_privilege('secop_lectura','gold','USAGE')    AS ve_gold,
       has_schema_privilege('secop_lectura','staging','USAGE') AS ve_staging,
       has_schema_privilege('secop_lectura','silver','USAGE')  AS ve_silver;

\echo '-- es_fecha_valida contra casos reales medidos. TODOS deben salir NULL'
\echo '-- menos las dos primeras, y ninguno debe lanzar error:'
SELECT nota,
       texto,
       silver.es_fecha_valida(texto) AS resultado
FROM (VALUES
    ('fecha normal',                  '2011-09-16T00:00:00.000', '2011-09-16'),
    ('ultimo dia del calendario',     '2030-12-31T00:00:00.000', '2030-12-31'),
    ('anio 1899, antes del minimo',   '1899-11-27T00:00:00.000', 'NULL esperado'),
    ('anio 2099, tras el maximo',      '2099-12-30T00:00:00.000', 'NULL esperado'),
    ('anio 8201',                     '8201-12-21T00:00:00.000', 'NULL esperado'),
    ('mes 99, no existe',             '9999-99-99',              'NULL esperado'),
    ('29 de febrero de 2019',         '2019-02-29T00:00:00.000', 'NULL esperado'),
    ('anio 0',                        '0000-01-01T00:00:00.000', 'NULL esperado'),
    ('vacio',                         '',                        'NULL esperado'),
    ('texto que no es fecha',         'ADQUISICIoN DE SIETE',    'NULL esperado'),
    ('nulo',                          NULL,                      'NULL esperado')
) AS t(nota, texto, esperado);

\echo '-- Las 6 dimensiones de texto deben usar la collation secop_ci, que es'
\echo '-- lo que hace que Compraventa y COMPRAVENTA sean la misma clave:'
SELECT table_name,
       count(*) FILTER (WHERE collation_name = 'secop_ci') AS cols_secop_ci
FROM information_schema.columns
WHERE table_schema = 'gold' AND table_name LIKE 'dim_%'
GROUP BY table_name
ORDER BY table_name;

\echo ''
\echo '### Estructura creada. La carga va en scripts/descargar_secop.py y scripts/cargar_secop.py'
