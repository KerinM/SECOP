-- =====================================================================
-- 02_silver_limpieza.sql  ·  CAPA PLATA
-- Responsable: Jose (Ingeniero ETL)
-- Requiere: bronze.secop_raw cargada (01_cargar_bronce.sql)
-- Ejecutar en psql:  \i 02_silver_limpieza.sql
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS unaccent;

-- ---------------------------------------------------------------------
-- 2. FUNCIONES DE LIMPIEZA (esquema silver)
-- ---------------------------------------------------------------------
-- R1 + R2. Texto en MAYÚSCULAS, sin tildes ni espacios dobles.
--          Quita espacios y barras '|' sueltas al inicio y al final ('ACME SAS|' → 'ACME SAS').
--          Las barras internas se conservan ('ALCALDIA | SECRETARIA' viene así de SECOP).
--          Los "nulos disfrazados" ('NO DEFINIDO', 'Sin Descripcion'...) pasan a NULL.
CREATE OR REPLACE FUNCTION silver.limpiar_texto(t TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN v IN ('', 'NO DEFINIDO', 'NO DEFINIDA', 'SIN DESCRIPCION',
                           'NO REGISTRA', 'N/A', 'NA', 'NULL', '-')
                THEN NULL ELSE v END
    FROM (SELECT upper(regexp_replace(
                     regexp_replace(public.unaccent('public.unaccent', t), '\s+', ' ', 'g'),
                     '^[\s|]+|[\s|]+$', '', 'g')) AS v) s
$$;

-- Fecha segura: acepta AAAA-MM-DD, MM/DD/AAAA o 'AAAA Mon DD'; lo inválido → NULL
CREATE OR REPLACE FUNCTION silver.a_fecha(t TEXT) RETURNS DATE
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    t := btrim(t);
    IF t ~ '^\d{4}-\d{2}-\d{2}' THEN
        RETURN to_date(left(t, 10), 'YYYY-MM-DD');
    ELSIF t ~ '^\d{2}/\d{2}/\d{4}' THEN
        RETURN to_date(left(t, 10), 'MM/DD/YYYY');
    ELSIF t ~ '^\d{4} [A-Za-z]{3} \d{2}' THEN
        RETURN to_date(left(t, 11), 'YYYY Mon DD');
    END IF;
    RETURN NULL;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END $$;

-- Número seguro: quita $ , espacios; lo que no sea número → NULL
CREATE OR REPLACE FUNCTION silver.a_numero(t TEXT) RETURNS NUMERIC
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN NULLIF(regexp_replace(t, '[^0-9.-]', '', 'g'), '')::NUMERIC;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END $$;

-- Solo dígitos y sin ceros a la izquierda: '        68296517' → '68296517'
CREATE OR REPLACE FUNCTION silver.solo_digitos(t TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT NULLIF(ltrim(regexp_replace(t, '\D', '', 'g'), '0'), '')
$$;

-- R8. Dígito de verificación del NIT (algoritmo módulo 11 de la DIAN)
CREATE OR REPLACE FUNCTION silver.dv_nit(nit TEXT) RETURNS INT
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    pesos INT[] := ARRAY[3, 7, 13, 17, 19, 23, 29, 37, 41, 43, 47, 53, 59, 67, 71];
    suma  INT := 0;
    n     INT := length(nit);
    r     INT;
BEGIN
    IF nit IS NULL OR nit !~ '^\d{1,15}$' THEN
        RETURN NULL;
    END IF;
    FOR i IN 1..n LOOP
        suma := suma + substr(nit, n - i + 1, 1)::INT * pesos[i];
    END LOOP;
    r := suma % 11;
    RETURN CASE WHEN r > 1 THEN 11 - r ELSE r END;
END $$;

-- R8. NIT sin dígito de verificación:
--     '890905211-1' → 890905211 · '8999990619' → 899999061 (DV 9 válido) · '0899999061' → 899999061
CREATE OR REPLACE FUNCTION silver.nit_base(t TEXT) RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    d TEXT;
BEGIN
    IF t ~ '^\s*\d[\d.\s]*-\s*\d\s*$' THEN            -- viene con guion: NNNNNNNNN-D
        RETURN silver.solo_digitos(split_part(t, '-', 1));
    END IF;
    d := silver.solo_digitos(t);
    IF d IS NULL OR length(d) NOT BETWEEN 5 AND 11 THEN
        RETURN NULL;                                    -- 'NO DEFINIDO', 'SANTANDER - INSTITUC'
    END IF;
    IF length(d) >= 10 AND silver.dv_nit(left(d, -1)) = right(d, 1)::INT THEN
        RETURN left(d, -1);                             -- DV pegado al final
    END IF;
    RETURN d;
END $$;


-- ---------------------------------------------------------------------
-- 4. CATÁLOGO DE HOMOLOGACIÓN (R3): un valor oficial por categoría
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS silver.homologacion (
    campo           TEXT NOT NULL,
    valor_origen    TEXT NOT NULL,      -- ya pasado por limpiar_texto()
    valor_estandar  TEXT NOT NULL,
    PRIMARY KEY (campo, valor_origen)
);
INSERT INTO silver.homologacion (campo, valor_origen, valor_estandar) VALUES
    ('departamento',  'DISTRITO CAPITAL DE BOGOTA',                              'BOGOTA D.C.'),
    ('municipio',     'BOGOTA',                                                  'BOGOTA D.C.'),
    ('tipo_contrato', 'SUMINISTROS',                                             'SUMINISTRO'),
    ('tipo_contrato', 'OTRO TIPO DE CONTRATO',                                   'OTRO'),
    ('modalidad',     'CONTRATACION DIRECTA (LEY 1150 DE 2007)',                 'CONTRATACION DIRECTA'),
    ('modalidad',     'CONTRATACION DIRECTA (CON OFERTAS)',                      'CONTRATACION DIRECTA'),
    ('modalidad',     'CONTRATACION DIRECTA MENOR CUANTIA',                      'CONTRATACION DIRECTA'),
    ('modalidad',     'CONTRATACION REGIMEN ESPECIAL',                           'REGIMEN ESPECIAL'),
    ('modalidad',     'CONTRATACION REGIMEN ESPECIAL (CON OFERTAS)',             'REGIMEN ESPECIAL'),
    ('modalidad',     'CONTRATACION MINIMA CUANTIA',                             'MINIMA CUANTIA'),
    ('modalidad',     'SELECCION ABREVIADA DE MENOR CUANTIA (LEY 1150 DE 2007)', 'SELECCION ABREVIADA'),
    ('modalidad',     'SELECCION ABREVIADA DE MENOR CUANTIA',                    'SELECCION ABREVIADA'),
    ('modalidad',     'SELECCION ABREVIADA SUBASTA INVERSA',                     'SELECCION ABREVIADA'),
    ('modalidad',     'SUBASTA',                                                 'SELECCION ABREVIADA'),
    ('modalidad',     'LICITACION OBRA PUBLICA',                                 'LICITACION PUBLICA'),
    ('modalidad',     'LICITACION PUBLICA OBRA PUBLICA',                         'LICITACION PUBLICA'),
    ('modalidad',     'CONCURSO DE MERITOS ABIERTO',                             'CONCURSO DE MERITOS')
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION silver.homologar(p_campo TEXT, p_valor TEXT) RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT coalesce((SELECT h.valor_estandar FROM silver.homologacion h
                     WHERE h.campo = p_campo AND h.valor_origen = p_valor), p_valor)
$$;


-- ---------------------------------------------------------------------
-- 5. CAPA PLATA: silver.contratos
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS silver.contratos;
CREATE TABLE silver.contratos (
    id_fila                   BIGINT PRIMARY KEY,     -- = bronze.secop_raw.id_fila
    origen                    TEXT,
    id_contrato               TEXT,
    id_proceso                TEXT,
    nivel_entidad             TEXT,
    codigo_entidad            TEXT,
    nombre_entidad            TEXT,
    nit_entidad               TEXT,
    departamento              TEXT,
    municipio                 TEXT,
    estado_proceso            TEXT,
    modalidad                 TEXT,
    tipo_contrato             TEXT,
    objeto_contrato           TEXT,
    fecha_firma               DATE,
    fecha_inicio              DATE,
    fecha_fin                 DATE,
    valor_contrato            NUMERIC(18,2),
    tipo_doc_proveedor        TEXT,
    documento_proveedor       TEXT,
    nombre_proveedor          TEXT,
    url_contrato              TEXT,
    -- banderas de calidad: se marca, no se borra
    flag_fecha_invalida       BOOLEAN NOT NULL DEFAULT false,
    flag_fechas_incoherentes  BOOLEAN NOT NULL DEFAULT false,
    flag_valor_cero           BOOLEAN NOT NULL DEFAULT false,
    flag_valor_relleno        BOOLEAN NOT NULL DEFAULT false,
    flag_valor_repetido       BOOLEAN NOT NULL DEFAULT false,
    flag_valor_atipico        BOOLEAN NOT NULL DEFAULT false,
    valor_ajustado            NUMERIC(18,2)
);

INSERT INTO silver.contratos (
    id_fila, origen, id_contrato, id_proceso, nivel_entidad, codigo_entidad, nombre_entidad,
    nit_entidad, departamento, municipio, estado_proceso, modalidad, tipo_contrato, objeto_contrato,
    fecha_firma, fecha_inicio, fecha_fin, valor_contrato, tipo_doc_proveedor, documento_proveedor,
    nombre_proveedor, url_contrato,
    flag_fecha_invalida, flag_fechas_incoherentes, flag_valor_cero, flag_valor_relleno,
    flag_valor_repetido, valor_ajustado)
WITH limpio AS (                                   -- R1, R2, R3, R8: limpieza y tipado
    SELECT
        b.id_fila,
        b.fecha_carga::date                                                         AS fecha_corte,
        silver.limpiar_texto(b.origen)                                              AS origen,
        NULLIF(btrim(b.numero_del_contrato), '')                                    AS id_contrato,
        NULLIF(btrim(b.numero_de_proceso), '')                                      AS id_proceso,
        silver.limpiar_texto(b.nivel_entidad)                                       AS nivel_entidad,
        silver.limpiar_texto(b.codigo_entidad_en_secop)                             AS codigo_entidad,
        silver.limpiar_texto(b.nombre_de_la_entidad)                                AS nombre_entidad,
        silver.nit_base(b.nit_de_la_entidad)                                        AS nit_entidad,
        silver.homologar('departamento',  silver.limpiar_texto(b.departamento_entidad))      AS departamento,
        silver.homologar('municipio',     silver.limpiar_texto(b.municipio_entidad))         AS municipio,
        silver.limpiar_texto(b.estado_del_proceso)                                  AS estado_proceso,
        silver.homologar('modalidad',     silver.limpiar_texto(b.modalidad_de_contratacion)) AS modalidad,
        silver.homologar('tipo_contrato', silver.limpiar_texto(b.tipo_de_contrato))          AS tipo_contrato,
        silver.limpiar_texto(b.objeto_a_contratar)                                  AS objeto_contrato,
        silver.a_fecha(b.fecha_de_firma_del_contrato)                               AS fecha_firma,
        silver.a_fecha(b.fecha_inicio_ejecucion)                                    AS fecha_inicio,
        silver.a_fecha(b.fecha_fin_ejecucion)                                       AS fecha_fin,
        silver.a_numero(b.valor_contrato)                                           AS valor,
        silver.limpiar_texto(b.tipo_documento_proveedor)                            AS tipo_doc,
        CASE WHEN silver.limpiar_texto(b.tipo_documento_proveedor) LIKE 'NIT%'
             THEN silver.nit_base(b.documento_proveedor)
             ELSE silver.solo_digitos(b.documento_proveedor) END                    AS documento_proveedor,
        silver.limpiar_texto(b.nom_raz_social_contratista)                          AS nombre_proveedor,
        NULLIF(btrim(b.url_contrato), '')                                           AS url_contrato
    FROM bronze.secop_raw b
),
validado AS (                                      -- R4, R6: lo imposible pasa a NULL
    SELECT l.*,
        CASE WHEN l.fecha_firma  BETWEEN DATE '2000-01-01' AND l.fecha_corte       THEN l.fecha_firma  END AS firma_ok,
        CASE WHEN l.fecha_inicio BETWEEN DATE '2000-01-01' AND DATE '2060-12-31'   THEN l.fecha_inicio END AS inicio_ok,
        CASE WHEN l.fecha_fin    BETWEEN DATE '2000-01-01' AND DATE '2060-12-31'   THEN l.fecha_fin    END AS fin_ok,
        CASE WHEN l.valor::text !~ '^9{8,}(\.0+)?$'                                THEN l.valor        END AS valor_ok
    FROM limpio l
),
dedup AS (                                         -- R5: duplicados → se conserva 1
    SELECT v.*,
        ROW_NUMBER() OVER (PARTITION BY origen, id_contrato, id_proceso, documento_proveedor,
                                        valor_ok, firma_ok
                           ORDER BY id_fila) AS rn
    FROM validado v
)
SELECT
    id_fila, origen, id_contrato, id_proceso, nivel_entidad, codigo_entidad, nombre_entidad,
    nit_entidad, departamento, municipio, estado_proceso, modalidad, tipo_contrato, objeto_contrato,
    firma_ok, inicio_ok, fin_ok, valor_ok, tipo_doc, documento_proveedor, nombre_proveedor, url_contrato,
    (fecha_firma IS NOT NULL AND firma_ok IS NULL)
      OR (fecha_inicio IS NOT NULL AND inicio_ok IS NULL)
      OR (fecha_fin IS NOT NULL AND fin_ok IS NULL)                     AS flag_fecha_invalida,
    coalesce(fin_ok < inicio_ok, false)                                 AS flag_fechas_incoherentes,
    coalesce(valor_ok <= 0, false)                                      AS flag_valor_cero,
    (valor IS NOT NULL AND valor_ok IS NULL)                            AS flag_valor_relleno,
    -- R7: mismo contrato + mismo valor en N filas → el valor es del proceso: se prorratea
    (id_contrato IS NOT NULL AND count(*) OVER w > 1)                   AS flag_valor_repetido,
    CASE WHEN id_contrato IS NOT NULL THEN round(valor_ok / count(*) OVER w, 2)
         ELSE valor_ok END                                              AS valor_ajustado
FROM dedup
WHERE rn = 1
WINDOW w AS (PARTITION BY origen, id_contrato, valor_ok);

-- R9: atípicos con la regla de Tukey sobre log10(valor), por tipo de contrato (no se borran)
WITH limites AS (
    SELECT tipo_contrato,
           percentile_cont(0.25) WITHIN GROUP (ORDER BY log(valor_contrato)::float8) AS q1,
           percentile_cont(0.75) WITHIN GROUP (ORDER BY log(valor_contrato)::float8) AS q3
    FROM silver.contratos
    WHERE valor_contrato > 0
    GROUP BY tipo_contrato
)
UPDATE silver.contratos s
SET flag_valor_atipico = true
FROM limites l
WHERE s.tipo_contrato IS NOT DISTINCT FROM l.tipo_contrato
  AND s.valor_contrato > 0
  AND log(s.valor_contrato)::float8 NOT BETWEEN l.q1 - 3 * (l.q3 - l.q1)
                                            AND l.q3 + 3 * (l.q3 - l.q1);



-- ---------------------------------------------------------------------
-- 6. RESULTADO DE LA LIMPIEZA: bronce vs. plata
-- ---------------------------------------------------------------------
SELECT 'bronce' AS capa, count(*) AS filas FROM bronze.secop_raw
UNION ALL
SELECT 'plata',          count(*)          FROM silver.contratos;

-- Cuántas filas quedaron marcadas por cada regla de calidad
SELECT count(*) FILTER (WHERE flag_fecha_invalida)      AS fecha_invalida,
       count(*) FILTER (WHERE flag_fechas_incoherentes) AS fechas_incoherentes,
       count(*) FILTER (WHERE flag_valor_cero)          AS valor_cero,
       count(*) FILTER (WHERE flag_valor_relleno)       AS valor_relleno,
       count(*) FILTER (WHERE flag_valor_repetido)      AS valor_repetido,
       count(*) FILTER (WHERE flag_valor_atipico)       AS valor_atipico
FROM silver.contratos;
