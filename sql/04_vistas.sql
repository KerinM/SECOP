-- =====================================================================
-- 04_vistas.sql  ·  SECOP Integrado  ·  Capa de consumo para Power BI
-- Responsable: Isabella (QA / Visualizacion)  ·  RF-13 a RF-20
-- =====================================================================
-- Base de datos : secop_dw
-- Lee           : gold.fact_contrato y las 5 dimensiones (y bronze solo
--                 para contar duplicados eliminados en mv_calidad_datos)
-- Escribe       : vistas materializadas gold.mv_* y vistas gold.v_*
--
-- REGLAS DE ESTE ARCHIVO
--   * Dinero: SIEMPRE valor_ajustado (o valor_gastado), nunca valor_contrato.
--   * Filtro de dinero (el mismo de gold.v_contratos_validos):
--         NOT es_atipico AND NOT es_fecha_invalida AND sk_fecha_firma <> -1
--     Se aplica dentro de cada medida o del WHERE de cada materializada,
--     de modo que todos los totales cuadran entre si.
--   * Los atipicos se CUENTAN en mv_entidad_resumen (RQ12) y en
--     mv_calidad_datos, que ven las filas sin filtrar.
--   * es_anio_parcial: marca el ultimo anio presente en los datos
--     (corte 29/09/2026 -> 2026). No se esconde: la variacion interanual
--     se calcula igual y queda marcada.
--   * Vistas por entidad o proveedor excluyen el miembro -1; las
--     agregaciones generales (anio, geografia) lo conservan para que el
--     total cuadre con las filas de plata.
--   * Power BI se conecta SOLO a gold.v_* y gold.mv_*.
--
-- COMO EJECUTAR (como postgres o secop_etl; tarda varios minutos porque
-- puebla las 8 materializadas leyendo 13 millones de filas):
--   psql -U postgres -h localhost -d secop_dw -f sql/04_vistas.sql
-- Es re-ejecutable: borra y recrea solo los objetos de este archivo.
-- =====================================================================

\set ON_ERROR_STOP on
\pset pager off

-- ---------------------------------------------------------------------
-- 0. Limpieza idempotente (primero vistas, luego materializadas)
-- ---------------------------------------------------------------------
-- Incluye nombres del modelo anterior (7 dimensiones) por si existen.
DROP VIEW IF EXISTS gold.v_top20_proveedores        CASCADE;
DROP VIEW IF EXISTS gold.v_top20_entidades          CASCADE;
DROP VIEW IF EXISTS gold.v_atipicos_entidad         CASCADE;
DROP VIEW IF EXISTS gold.v_no_competitiva_modalidad CASCADE;
DROP VIEW IF EXISTS gold.v_no_competitiva_entidad   CASCADE;
DROP VIEW IF EXISTS gold.v_perfil_tipo_persona      CASCADE;
DROP VIEW IF EXISTS gold.v_estado_contrato          CASCADE;
DROP VIEW IF EXISTS gold.v_participacion_origen     CASCADE;
DROP VIEW IF EXISTS gold.v_tipo_contrato            CASCADE;
DROP VIEW IF EXISTS gold.v_nivel_entidad            CASCADE;
DROP VIEW IF EXISTS gold.v_geografia_departamento   CASCADE;
DROP VIEW IF EXISTS gold.v_estacionalidad           CASCADE;
DROP VIEW IF EXISTS gold.v_evolucion_anual          CASCADE;
DROP VIEW IF EXISTS gold.v_resumen_contratos        CASCADE;
DROP VIEW IF EXISTS gold.v_dim_entidad              CASCADE;

DROP MATERIALIZED VIEW IF EXISTS gold.mv_calidad_datos       CASCADE;
DROP MATERIALIZED VIEW IF EXISTS gold.mv_duracion            CASCADE;
DROP MATERIALIZED VIEW IF EXISTS gold.mv_kpis_globales       CASCADE;
DROP MATERIALIZED VIEW IF EXISTS gold.mv_proveedor_valor     CASCADE;
DROP MATERIALIZED VIEW IF EXISTS gold.mv_geografia           CASCADE;
DROP MATERIALIZED VIEW IF EXISTS gold.mv_entidad_resumen     CASCADE;
DROP MATERIALIZED VIEW IF EXISTS gold.mv_serie_mensual       CASCADE;
DROP MATERIALIZED VIEW IF EXISTS gold.mv_resumen_contratos   CASCADE;
-- Nombres del modelo anterior
DROP MATERIALIZED VIEW IF EXISTS gold.mv_geografia_municipio CASCADE;
DROP MATERIALIZED VIEW IF EXISTS gold.mv_perfil_documental   CASCADE;

-- =====================================================================
-- 1. VISTAS MATERIALIZADAS
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1.1 mv_resumen_contratos  ·  cubo base a grano ANIO
-- Responde RQ02, RQ07, RQ08, RQ10, RQ11, RQ13, RQ14.
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW gold.mv_resumen_contratos AS
SELECT
    t.anio,
    coalesce(e.nivel_entidad, 'NO REGISTRA')  AS nivel_entidad,
    c.tipo_contrato,
    c.modalidad,
    c.es_competitiva,
    c.agrupacion_estado,
    c.rango_estado,
    c.origen,
    p.tipo_persona,
    sum(f.contrato_unidad)::bigint            AS versiones,
    sum(f.valor_ajustado)::numeric(22,2)      AS valor_ajustado,
    sum(f.valor_gastado)::numeric(22,2)       AS valor_gastado
FROM gold.fact_contrato f
JOIN gold.dim_tiempo    t ON t.sk_tiempo   = f.sk_fecha_firma
JOIN gold.dim_entidad   e ON e.sk_entidad  = f.sk_entidad
JOIN gold.dim_contrato  c ON c.sk_contrato = f.sk_contrato
JOIN gold.dim_proveedor p ON p.sk_proveedor = f.sk_proveedor
WHERE NOT f.es_atipico
  AND NOT f.es_fecha_invalida
  AND f.sk_fecha_firma <> -1
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9
WITH NO DATA;

CREATE INDEX ix_mv_resumen_anio ON gold.mv_resumen_contratos (anio);

COMMENT ON MATERIALIZED VIEW gold.mv_resumen_contratos IS
    'Cubo base a grano anio: nivel de entidad, tipo, modalidad, estado, origen y tipo de persona. Solo filas validas (sin atipicos, sin fecha invalida, con fecha de firma). Medidas: versiones, valor_ajustado, valor_gastado.';

-- ---------------------------------------------------------------------
-- 1.2 mv_serie_mensual  ·  anio / trimestre / mes por tipo y modalidad
-- Responde RQ09 y RF-16.
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW gold.mv_serie_mensual AS
SELECT
    t.anio, t.trimestre, t.mes,
    c.tipo_contrato,
    c.modalidad,
    sum(f.contrato_unidad)::bigint        AS versiones,
    sum(f.valor_ajustado)::numeric(22,2)  AS valor_ajustado,
    sum(f.valor_gastado)::numeric(22,2)   AS valor_gastado
FROM gold.fact_contrato f
JOIN gold.dim_tiempo   t ON t.sk_tiempo   = f.sk_fecha_firma
JOIN gold.dim_contrato c ON c.sk_contrato = f.sk_contrato
WHERE NOT f.es_atipico
  AND NOT f.es_fecha_invalida
  AND f.sk_fecha_firma <> -1
GROUP BY 1, 2, 3, 4, 5
WITH NO DATA;

CREATE INDEX ix_mv_serie_anio_mes ON gold.mv_serie_mensual (anio, mes);

COMMENT ON MATERIALIZED VIEW gold.mv_serie_mensual IS
    'Serie mensual por tipo de contrato y modalidad (RQ09, RF-16). Mismo filtro de dinero que el resto.';

-- ---------------------------------------------------------------------
-- 1.3 mv_entidad_resumen  ·  entidad x anio x modalidad
-- Responde RQ01, RQ03 y RQ12. AQUI SE CUENTAN LOS ATIPICOS.
--   versiones_total   todas las versiones con fecha de firma
--   versiones_validas las que pasan el filtro de dinero
--   versiones_atipicas las marcadas es_atipico
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW gold.mv_entidad_resumen AS
SELECT
    f.sk_entidad,
    t.anio,
    c.modalidad,
    c.es_competitiva,
    sum(f.contrato_unidad)::bigint                                   AS versiones_total,
    sum(f.contrato_unidad) FILTER (WHERE NOT f.es_atipico
                                     AND NOT f.es_fecha_invalida)::bigint AS versiones_validas,
    sum(f.contrato_unidad) FILTER (WHERE f.es_atipico)::bigint       AS versiones_atipicas,
    coalesce(sum(f.valor_ajustado) FILTER (WHERE NOT f.es_atipico
                                             AND NOT f.es_fecha_invalida), 0)::numeric(22,2) AS valor_ajustado,
    coalesce(sum(f.valor_gastado)  FILTER (WHERE NOT f.es_atipico
                                             AND NOT f.es_fecha_invalida), 0)::numeric(22,2) AS valor_gastado,
    coalesce(sum(f.valor_ajustado) FILTER (WHERE f.es_atipico), 0)::numeric(22,2)            AS valor_atipico
FROM gold.fact_contrato f
JOIN gold.dim_tiempo   t ON t.sk_tiempo   = f.sk_fecha_firma
JOIN gold.dim_contrato c ON c.sk_contrato = f.sk_contrato
WHERE f.sk_fecha_firma <> -1
GROUP BY 1, 2, 3, 4
WITH NO DATA;

CREATE INDEX ix_mv_entres_entidad ON gold.mv_entidad_resumen (sk_entidad);
CREATE INDEX ix_mv_entres_anio    ON gold.mv_entidad_resumen (anio);

COMMENT ON MATERIALIZED VIEW gold.mv_entidad_resumen IS
    'Entidad x anio x modalidad. Cuenta versiones totales, validas y atipicas (RQ12) y el valor valido (RQ01, RQ03). Incluye sk_entidad = -1; las vistas que la leen lo excluyen.';

-- ---------------------------------------------------------------------
-- 1.4 mv_geografia  ·  anio x departamento x municipio
-- Responde RQ05. La ubicacion es la de la entidad contratante.
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW gold.mv_geografia AS
SELECT
    t.anio,
    u.departamento,
    u.municipio,
    sum(f.contrato_unidad)::bigint        AS versiones,
    sum(f.valor_ajustado)::numeric(22,2)  AS valor_ajustado,
    sum(f.valor_gastado)::numeric(22,2)   AS valor_gastado
FROM gold.fact_contrato f
JOIN gold.dim_tiempo    t ON t.sk_tiempo    = f.sk_fecha_firma
JOIN gold.dim_ubicacion u ON u.sk_ubicacion = f.sk_ubicacion
WHERE NOT f.es_atipico
  AND NOT f.es_fecha_invalida
  AND f.sk_fecha_firma <> -1
GROUP BY 1, 2, 3
WITH NO DATA;

CREATE INDEX ix_mv_geo_anio_depto ON gold.mv_geografia (anio, departamento);

COMMENT ON MATERIALIZED VIEW gold.mv_geografia IS
    'Versiones y valor por anio, departamento y municipio (RQ05). Incluye el par NO REGISTRA para que el total cuadre.';

-- ---------------------------------------------------------------------
-- 1.5 mv_proveedor_valor  ·  una fila por proveedor
-- Responde RQ04: valor, versiones y numero de entidades distintas.
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW gold.mv_proveedor_valor AS
SELECT
    f.sk_proveedor,
    sum(f.contrato_unidad)::bigint        AS versiones,
    count(DISTINCT f.sk_entidad)::int     AS entidades_distintas,
    sum(f.valor_ajustado)::numeric(22,2)  AS valor_ajustado,
    sum(f.valor_gastado)::numeric(22,2)   AS valor_gastado
FROM gold.fact_contrato f
WHERE NOT f.es_atipico
  AND NOT f.es_fecha_invalida
  AND f.sk_fecha_firma <> -1
GROUP BY f.sk_proveedor
WITH NO DATA;

CREATE INDEX ix_mv_provval_valor ON gold.mv_proveedor_valor (valor_ajustado DESC);

COMMENT ON MATERIALIZED VIEW gold.mv_proveedor_valor IS
    'Valor, versiones y entidades distintas por proveedor (RQ04). Incluye sk_proveedor = -1; el top 20 lo excluye.';

-- ---------------------------------------------------------------------
-- 1.6 mv_duracion  ·  duracion por tipo de contrato y modalidad
-- Responde RQ06 y RF-09. Percentiles: no se pueden sacar de un cubo ya
-- agregado, por eso se calculan aqui sobre las filas.
-- Excluye duraciones negativas, fechas incoherentes e invalidas.
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW gold.mv_duracion AS
SELECT
    c.tipo_contrato,
    c.modalidad,
    count(*)::bigint                                                     AS versiones,
    round(avg(f.duracion_dias)::numeric, 1)                              AS promedio_dias,
    round((percentile_cont(0.25) WITHIN GROUP (ORDER BY f.duracion_dias))::numeric, 1) AS p25_dias,
    round((percentile_cont(0.50) WITHIN GROUP (ORDER BY f.duracion_dias))::numeric, 1) AS mediana_dias,
    round((percentile_cont(0.75) WITHIN GROUP (ORDER BY f.duracion_dias))::numeric, 1) AS p75_dias,
    round((percentile_cont(0.95) WITHIN GROUP (ORDER BY f.duracion_dias))::numeric, 1) AS p95_dias
FROM gold.fact_contrato f
JOIN gold.dim_contrato c ON c.sk_contrato = f.sk_contrato
WHERE f.duracion_dias IS NOT NULL
  AND f.duracion_dias >= 0
  AND NOT f.es_fechas_incoherentes
  AND NOT f.es_fecha_invalida
GROUP BY 1, 2
WITH NO DATA;

COMMENT ON MATERIALIZED VIEW gold.mv_duracion IS
    'Duracion en dias por tipo de contrato y modalidad: promedio, mediana y percentiles 25/75/95 (RQ06, RF-09).';

-- ---------------------------------------------------------------------
-- 1.7 mv_kpis_globales  ·  una sola fila (RF-15)
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW gold.mv_kpis_globales AS
SELECT
    count(*)::bigint                                                         AS total_versiones,
    count(*) FILTER (WHERE NOT f.es_atipico AND NOT f.es_fecha_invalida
                       AND f.sk_fecha_firma <> -1)::bigint                   AS versiones_validas,
    count(DISTINCT f.id_contrato)::bigint                                    AS contratos_distintos,
    count(DISTINCT f.id_contrato) FILTER (WHERE f.es_version_contrato)::bigint AS contratos_con_versiones,
    coalesce(sum(f.valor_ajustado) FILTER (WHERE NOT f.es_atipico AND NOT f.es_fecha_invalida
                       AND f.sk_fecha_firma <> -1), 0)::numeric(22,2)        AS valor_contratado,
    coalesce(sum(f.valor_gastado) FILTER (WHERE NOT f.es_atipico AND NOT f.es_fecha_invalida
                       AND f.sk_fecha_firma <> -1), 0)::numeric(22,2)        AS valor_gastado,
    (SELECT count(*) FROM gold.dim_entidad   WHERE sk_entidad   <> -1)::bigint AS entidades,
    (SELECT count(*) FROM gold.dim_proveedor WHERE sk_proveedor <> -1)::bigint AS proveedores,
    (SELECT count(DISTINCT departamento) FROM gold.dim_ubicacion
      WHERE departamento NOT IN ('NO REGISTRA', 'COLOMBIA'))::bigint                           AS departamentos,
    (SELECT count(DISTINCT (departamento, municipio)) FROM gold.dim_ubicacion
      WHERE municipio <> 'NO REGISTRA')::bigint                              AS municipios
FROM gold.fact_contrato f
WITH NO DATA;

COMMENT ON MATERIALIZED VIEW gold.mv_kpis_globales IS
    'KPIs del panel principal (RF-15). contratos_con_versiones cuenta id_contrato distintos con bandera de version; puede diferir de los 554.063 pares contrato-proveedor que cuenta R7b. Entidades, proveedores y municipios son recuentos de las dimensiones sin el miembro -1.';

-- ---------------------------------------------------------------------
-- 1.8 mv_calidad_datos  ·  reporte de anomalias (RF-19)
-- Lee oro SIN filtrar. Los duplicados eliminados salen de bronce - oro
-- (plata = oro = 13.005.402); la base de ese porcentaje es bronce.
-- CORRECCION: las columnas de bronce viven en el alias bz, no en b.
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW gold.mv_calidad_datos AS
WITH base AS (
    SELECT
        count(*)                                                  AS total,
        count(*) FILTER (WHERE sk_fecha_firma  = -1)              AS sin_fecha_firma,
        count(*) FILTER (WHERE sk_fecha_inicio = -1)              AS sin_fecha_inicio,
        count(*) FILTER (WHERE sk_fecha_fin    = -1)              AS sin_fecha_fin,
        count(*) FILTER (WHERE es_fecha_invalida)                 AS fecha_invalida,
        count(*) FILTER (WHERE es_fechas_incoherentes)            AS fechas_incoherentes,
        count(*) FILTER (WHERE es_valor_cero)                     AS valor_cero,
        count(*) FILTER (WHERE es_valor_relleno)                  AS valor_relleno,
        count(*) FILTER (WHERE es_valor_repetido)                 AS valor_repetido,
        count(*) FILTER (WHERE es_version_contrato)               AS version_contrato,
        count(*) FILTER (WHERE es_atipico)                        AS atipicos,
        count(*) FILTER (WHERE es_valor_extremo)                  AS extremos,
        count(*) FILTER (WHERE sk_entidad   = -1)                 AS sin_entidad,
        count(*) FILTER (WHERE sk_ubicacion = -1)                 AS sin_ubicacion,
        count(*) FILTER (WHERE sk_proveedor = -1)                 AS sin_proveedor,
        count(*) FILTER (WHERE sk_contrato  = -1)                 AS sin_clasificacion
    FROM gold.fact_contrato
), bz AS (
    SELECT count(*) AS bronce FROM bronze.secop_raw
)
SELECT v.orden, v.clase, v.indicador, v.regla, v.filas,
       round(100.0 * v.filas / nullif(v.base_filas, 0), 2) AS porcentaje
FROM base b
CROSS JOIN bz
CROSS JOIN LATERAL (VALUES
    ( 1, '0 · Referencia',        'Filas en bronce',                             '-',   bz.bronce,            bz.bronce),
    ( 2, '0 · Referencia',        'Filas en oro (versiones de contrato)',        '-',   b.total,              bz.bronce),
    ( 3, '1 · Duplicados',        'Duplicados exactos eliminados',               'R5',  bz.bronce - b.total,  bz.bronce),
    ( 4, '2 · Fechas',            'Sin fecha de firma valida',                   'R4',  b.sin_fecha_firma,   b.total),
    ( 5, '2 · Fechas',            'Sin fecha de inicio valida',                  'R4',  b.sin_fecha_inicio,  b.total),
    ( 6, '2 · Fechas',            'Sin fecha de fin valida',                     'R4',  b.sin_fecha_fin,     b.total),
    ( 7, '2 · Fechas',            'Filas con alguna fecha imposible',            'R4',  b.fecha_invalida,    b.total),
    ( 8, '2 · Fechas',            'Fecha de fin anterior a la de inicio',        'R4',  b.fechas_incoherentes, b.total),
    ( 9, '3 · Valores',           'Valor en cero o negativo',                    'R6',  b.valor_cero,        b.total),
    (10, '3 · Valores',           'Valor de relleno (8 o mas nueves)',           'R6',  b.valor_relleno,     b.total),
    (11, '3 · Valores',           'Valor repetido en varias filas',              'R7',  b.valor_repetido,    b.total),
    (12, '3 · Valores',           'Versiones de un mismo contrato (SECOP II)',   'R7b', b.version_contrato,  b.total),
    (13, '3 · Valores',           'Valores atipicos (R9 + R9b)',                 'R9',  b.atipicos,          b.total),
    (14, '3 · Valores',           'De ellos, extremos para su entidad',          'R9b', b.extremos,          b.total),
    (15, '4 · Sin registro (-1)', 'Sin entidad',                                 '-',   b.sin_entidad,       b.total),
    (16, '4 · Sin registro (-1)', 'Sin ubicacion',                               '-',   b.sin_ubicacion,     b.total),
    (17, '4 · Sin registro (-1)', 'Sin proveedor',                               '-',   b.sin_proveedor,     b.total),
    (18, '4 · Sin registro (-1)', 'Sin clasificacion del contrato',              '-',   b.sin_clasificacion, b.total)
) AS v(orden, clase, indicador, regla, filas, base_filas)
WITH NO DATA;

COMMENT ON MATERIALIZED VIEW gold.mv_calidad_datos IS
    'Anomalias medidas con cantidad y porcentaje (RF-14, RF-19). Cubre R4 a R9b y los miembros -1. El porcentaje de las filas de referencia y de duplicados es sobre bronce; el resto, sobre oro.';

-- =====================================================================
-- 2. VISTAS DE CONSUMO
-- =====================================================================

-- 2.1 Detalle del cubo base con la marca de anio parcial
CREATE VIEW gold.v_resumen_contratos AS
SELECT r.*,
       (r.anio = max(r.anio) OVER ()) AS es_anio_parcial
FROM gold.mv_resumen_contratos r;

COMMENT ON VIEW gold.v_resumen_contratos IS
    'Cubo base a grano anio con es_anio_parcial (ultimo anio presente: corte 29/09/2026). Para cortes por tipo, modalidad, estado, origen o tipo de persona.';

-- 2.2 Evolucion anual con variacion interanual (RQ02, RF-10, RF-16)
CREATE VIEW gold.v_evolucion_anual AS
WITH anual AS (
    SELECT anio,
           sum(versiones)      AS versiones,
           sum(valor_ajustado) AS valor_ajustado,
           sum(valor_gastado)  AS valor_gastado
    FROM gold.mv_resumen_contratos
    GROUP BY anio
)
SELECT
    anio,
    versiones,
    valor_ajustado,
    valor_gastado,
    round(100.0 * (versiones - lag(versiones) OVER w)
          / nullif(lag(versiones) OVER w, 0), 2)           AS var_versiones_pct,
    round(100.0 * (valor_ajustado - lag(valor_ajustado) OVER w)
          / nullif(lag(valor_ajustado) OVER w, 0), 2)      AS var_valor_pct,
    (anio = max(anio) OVER ())                             AS es_anio_parcial
FROM anual
WINDOW w AS (ORDER BY anio)
ORDER BY anio;

COMMENT ON VIEW gold.v_evolucion_anual IS
    'Serie anual 2017-2026 con variacion interanual contra el anio anterior presente. es_anio_parcial marca el ultimo anio: la variacion se calcula igual pero compara un anio incompleto.';

-- 2.3 Estacionalidad (RQ09)
CREATE VIEW gold.v_estacionalidad AS
SELECT
    anio, trimestre, mes,
    sum(versiones)      AS versiones,
    sum(valor_ajustado) AS valor_ajustado,
    sum(valor_gastado)  AS valor_gastado,
    (anio = max(anio) OVER ()) AS es_anio_parcial
FROM gold.mv_serie_mensual
GROUP BY anio, trimestre, mes;

COMMENT ON VIEW gold.v_estacionalidad IS
    'Versiones y valor por anio, trimestre y mes (RQ09). Para detalle por tipo o modalidad usar gold.mv_serie_mensual.';

-- 2.4 Geografia por departamento (RQ05, RF-11, RF-17)
CREATE VIEW gold.v_geografia_departamento AS
WITH d AS (
    SELECT anio, departamento,
           sum(versiones)      AS versiones,
           sum(valor_ajustado) AS valor_ajustado,
           sum(valor_gastado)  AS valor_gastado
    FROM gold.mv_geografia
    GROUP BY anio, departamento
)
SELECT
    d.anio, d.departamento, d.versiones, d.valor_ajustado, d.valor_gastado,
    round(100.0 * d.versiones
          / nullif(sum(d.versiones) OVER (PARTITION BY d.anio), 0), 2)       AS pct_versiones_anio,
    round(100.0 * d.valor_ajustado
          / nullif(sum(d.valor_ajustado) OVER (PARTITION BY d.anio), 0), 2)  AS pct_valor_anio,
    (d.anio = max(d.anio) OVER ())                                           AS es_anio_parcial
FROM d;

COMMENT ON VIEW gold.v_geografia_departamento IS
    'Versiones y valor por departamento y anio, con participacion sobre el total nacional del anio (resalta Bogota y Antioquia, RF-17). El detalle por municipio esta en gold.mv_geografia.';

-- 2.5 Nacional frente a territorial (RQ07)
CREATE VIEW gold.v_nivel_entidad AS
SELECT
    anio, nivel_entidad,
    sum(versiones)      AS versiones,
    sum(valor_ajustado) AS valor_ajustado,
    round(100.0 * sum(valor_ajustado)
          / nullif(sum(sum(valor_ajustado)) OVER (PARTITION BY anio), 0), 2) AS pct_valor_anio,
    (anio = max(anio) OVER ()) AS es_anio_parcial
FROM gold.mv_resumen_contratos
GROUP BY anio, nivel_entidad;

COMMENT ON VIEW gold.v_nivel_entidad IS
    'Distribucion de versiones y valor entre niveles de entidad por anio (RQ07).';

-- 2.6 Valor total y promedio por tipo de contrato (RQ08)
CREATE VIEW gold.v_tipo_contrato AS
SELECT
    anio, tipo_contrato,
    sum(versiones)      AS versiones,
    sum(valor_ajustado) AS valor_ajustado,
    round(sum(valor_ajustado) / nullif(sum(versiones), 0), 2) AS valor_promedio_por_version,
    (anio = max(anio) OVER ()) AS es_anio_parcial
FROM gold.mv_resumen_contratos
GROUP BY anio, tipo_contrato;

COMMENT ON VIEW gold.v_tipo_contrato IS
    'Valor total y valor promedio por version de contrato segun tipo y anio (RQ08). El promedio es valor_ajustado / versiones.';

-- 2.7 SECOP II frente a SECOP I (RQ11)
CREATE VIEW gold.v_participacion_origen AS
SELECT
    anio, origen,
    sum(versiones)      AS versiones,
    sum(valor_ajustado) AS valor_ajustado,
    round(100.0 * sum(versiones)
          / nullif(sum(sum(versiones)) OVER (PARTITION BY anio), 0), 2)      AS pct_versiones_anio,
    round(100.0 * sum(valor_ajustado)
          / nullif(sum(sum(valor_ajustado)) OVER (PARTITION BY anio), 0), 2) AS pct_valor_anio,
    (anio = max(anio) OVER ()) AS es_anio_parcial
FROM gold.mv_resumen_contratos
GROUP BY anio, origen;

COMMENT ON VIEW gold.v_participacion_origen IS
    'Participacion anual de SECOP I y SECOP II en versiones y valor (RQ11).';

-- 2.8 Estado del contrato (RQ13, RF-22) y valor gastado (RQ14)
CREATE VIEW gold.v_estado_contrato AS
SELECT
    anio, origen, agrupacion_estado, rango_estado,
    sum(versiones)      AS versiones,
    sum(valor_ajustado) AS valor_ajustado,
    sum(valor_gastado)  AS valor_gastado,
    (anio = max(anio) OVER ()) AS es_anio_parcial
FROM gold.mv_resumen_contratos
GROUP BY anio, origen, agrupacion_estado, rango_estado;

COMMENT ON VIEW gold.v_estado_contrato IS
    'Versiones, valor y valor_gastado por agrupacion de estado, origen y anio (RQ13, RQ14). valor_gastado es el valor contratado vigente, no el pagado.';

-- 2.9 Perfil por tipo de persona (RQ10, RF-12)
CREATE VIEW gold.v_perfil_tipo_persona AS
SELECT
    anio, tipo_persona,
    sum(versiones)      AS versiones,
    sum(valor_ajustado) AS valor_ajustado,
    round(100.0 * sum(valor_ajustado)
          / nullif(sum(sum(valor_ajustado)) OVER (PARTITION BY anio), 0), 2) AS pct_valor_anio,
    (anio = max(anio) OVER ()) AS es_anio_parcial
FROM gold.mv_resumen_contratos
GROUP BY anio, tipo_persona;

COMMENT ON VIEW gold.v_perfil_tipo_persona IS
    'Proporcion del valor por tipo de persona y anio (RQ10). tipo_persona se asigna por documento con prioridad JURIDICA.';

-- 2.10 Contratacion no competitiva por entidad (RQ03, RF-08)
CREATE VIEW gold.v_no_competitiva_entidad AS
SELECT
    r.sk_entidad,
    e.codigo_entidad, e.nombre_entidad, e.nivel_entidad,
    r.anio,
    sum(r.versiones_validas)::bigint                                              AS versiones_validas,
    (sum(r.versiones_validas) FILTER (WHERE r.es_competitiva = false))::bigint    AS versiones_no_competitivas,
    round(100.0 * sum(r.versiones_validas) FILTER (WHERE r.es_competitiva = false)
          / nullif(sum(r.versiones_validas), 0), 2)                               AS pct_no_competitiva,
    (r.anio = max(r.anio) OVER ())                                                AS es_anio_parcial
FROM gold.mv_entidad_resumen r
JOIN gold.dim_entidad e ON e.sk_entidad = r.sk_entidad
WHERE r.sk_entidad <> -1
GROUP BY r.sk_entidad, e.codigo_entidad, e.nombre_entidad, e.nivel_entidad, r.anio;

COMMENT ON VIEW gold.v_no_competitiva_entidad IS
    'Porcentaje de versiones por modalidades NO competitivas (contratacion directa, otras formas y regimen especial) por entidad y anio (RQ03). Entidades con pocas versiones dan porcentajes ruidosos: filtrar por versiones_validas.';

CREATE VIEW gold.v_no_competitiva_modalidad AS
SELECT
    r.sk_entidad,
    e.codigo_entidad, e.nombre_entidad, e.nivel_entidad,
    r.anio, r.modalidad, r.es_competitiva,
    sum(r.versiones_validas)::bigint AS versiones_validas,
    round(100.0 * sum(r.versiones_validas)
          / nullif(sum(sum(r.versiones_validas)) OVER (PARTITION BY r.sk_entidad, r.anio), 0), 2)
                                     AS pct_de_la_entidad,
    (r.anio = max(r.anio) OVER ())   AS es_anio_parcial
FROM gold.mv_entidad_resumen r
JOIN gold.dim_entidad e ON e.sk_entidad = r.sk_entidad
WHERE r.sk_entidad <> -1
GROUP BY r.sk_entidad, e.codigo_entidad, e.nombre_entidad, e.nivel_entidad,
         r.anio, r.modalidad, r.es_competitiva;

COMMENT ON VIEW gold.v_no_competitiva_modalidad IS
    'Desglose por modalidad de las versiones de cada entidad y anio. Separa contratacion directa de regimen especial (el indicador agregado esconde esa diferencia).';

-- 2.11 Atipicos por entidad (RQ12)
CREATE VIEW gold.v_atipicos_entidad AS
SELECT
    row_number() OVER (ORDER BY a.versiones_atipicas DESC, a.sk_entidad) AS posicion,
    a.sk_entidad,
    e.codigo_entidad, e.nombre_entidad, e.nivel_entidad,
    a.versiones_total,
    a.versiones_atipicas,
    round(100.0 * a.versiones_atipicas / nullif(a.versiones_total, 0), 2) AS pct_atipicas,
    a.valor_atipico
FROM (
    SELECT sk_entidad,
           sum(versiones_total)::bigint                    AS versiones_total,
           coalesce(sum(versiones_atipicas), 0)::bigint    AS versiones_atipicas,
           sum(valor_atipico)::numeric(22,2)               AS valor_atipico
    FROM gold.mv_entidad_resumen
    WHERE sk_entidad <> -1
    GROUP BY sk_entidad
) a
JOIN gold.dim_entidad e ON e.sk_entidad = a.sk_entidad
WHERE a.versiones_atipicas > 0;

COMMENT ON VIEW gold.v_atipicos_entidad IS
    'Entidades con mas versiones atipicas (RQ12), con su porcentaje y el valor atipico. Solo entidades con al menos una.';

-- 2.12 Top 20 de entidades por valor (RF-07)
CREATE VIEW gold.v_top20_entidades AS
WITH por_entidad AS (
    SELECT sk_entidad,
           sum(versiones_validas)::bigint AS versiones,
           sum(valor_ajustado)            AS valor_ajustado
    FROM gold.mv_entidad_resumen
    WHERE sk_entidad <> -1
    GROUP BY sk_entidad
), tot AS (
    SELECT sum(valor_ajustado) AS valor_nacional FROM por_entidad
), top AS (
    SELECT * FROM por_entidad ORDER BY valor_ajustado DESC, sk_entidad LIMIT 20
)
SELECT
    row_number() OVER (ORDER BY t.valor_ajustado DESC, t.sk_entidad)         AS posicion,
    e.codigo_entidad, e.nombre_entidad, e.nivel_entidad,
    t.versiones, t.valor_ajustado,
    round(100.0 * t.valor_ajustado / nullif(tot.valor_nacional, 0), 3)       AS pct_del_total,
    round(100.0 * sum(t.valor_ajustado) OVER (ORDER BY t.valor_ajustado DESC, t.sk_entidad)
          / nullif(tot.valor_nacional, 0), 3)                                AS pct_acumulado
FROM top t
JOIN gold.dim_entidad e ON e.sk_entidad = t.sk_entidad
CROSS JOIN tot
ORDER BY posicion;

COMMENT ON VIEW gold.v_top20_entidades IS
    'Top 20 de entidades por valor ajustado valido, con porcentaje del total y acumulado (RF-07). Excluye sk_entidad = -1.';

-- 2.13 Top 20 de proveedores, con HHI y entidades distintas (RQ04, RF-07, RF-18)
CREATE VIEW gold.v_top20_proveedores AS
WITH tot AS (
    SELECT sum(valor_ajustado) AS valor_nacional FROM gold.mv_proveedor_valor
), hhi AS (
    SELECT round(sum(power(100.0 * m.valor_ajustado / t.valor_nacional, 2)), 2) AS valor
    FROM gold.mv_proveedor_valor m
    CROSS JOIN tot t
    WHERE t.valor_nacional > 0
), top AS (
    SELECT sk_proveedor, versiones, entidades_distintas, valor_ajustado
    FROM gold.mv_proveedor_valor
    WHERE sk_proveedor <> -1
    ORDER BY valor_ajustado DESC NULLS LAST, sk_proveedor
    LIMIT 20
)
SELECT
    row_number() OVER (ORDER BY t.valor_ajustado DESC, t.sk_proveedor)       AS posicion,
    p.nombre_proveedor, p.documento_proveedor, p.tipo_persona,
    t.versiones, t.entidades_distintas, t.valor_ajustado,
    round(100.0 * t.valor_ajustado / nullif(tot.valor_nacional, 0), 3)       AS pct_del_total,
    round(100.0 * sum(t.valor_ajustado) OVER (ORDER BY t.valor_ajustado DESC, t.sk_proveedor)
          / nullif(tot.valor_nacional, 0), 3)                                AS pct_acumulado,
    hhi.valor                                                                AS hhi_global
FROM top t
JOIN gold.dim_proveedor p ON p.sk_proveedor = t.sk_proveedor
CROSS JOIN tot
CROSS JOIN hhi
ORDER BY posicion;

COMMENT ON VIEW gold.v_top20_proveedores IS
    'Top 20 de proveedores por valor ajustado valido, con entidades distintas, porcentaje del total, acumulado y HHI global (0-10.000). El HHI usa todos los proveedores, incluido -1. Excluye sk_proveedor = -1 del ranking.';

-- =====================================================================
-- 3. REFRESCO
-- =====================================================================
-- Las 8 materializadas leen de gold.fact_contrato y no dependen entre si,
-- asi que el orden no importa. Las vistas v_* no se refrescan: leen de
-- las materializadas.
CREATE OR REPLACE PROCEDURE gold.refrescar_vistas()
LANGUAGE plpgsql
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW gold.mv_resumen_contratos;
    REFRESH MATERIALIZED VIEW gold.mv_serie_mensual;
    REFRESH MATERIALIZED VIEW gold.mv_entidad_resumen;
    REFRESH MATERIALIZED VIEW gold.mv_geografia;
    REFRESH MATERIALIZED VIEW gold.mv_proveedor_valor;
    REFRESH MATERIALIZED VIEW gold.mv_duracion;
    REFRESH MATERIALIZED VIEW gold.mv_kpis_globales;
    REFRESH MATERIALIZED VIEW gold.mv_calidad_datos;
END
$$;

COMMENT ON PROCEDURE gold.refrescar_vistas() IS
    'Refresca las 8 vistas materializadas. Ejecutar tras cada carga de oro: CALL gold.refrescar_vistas();';

-- =====================================================================
-- 4. PERMISOS
-- =====================================================================
-- Las materializadas no heredan los privilegios por defecto de secop_etl
-- si las crea otro rol, asi que se conceden de forma explicita.
GRANT USAGE  ON SCHEMA gold TO secop_lectura;
GRANT SELECT ON ALL TABLES IN SCHEMA gold TO secop_lectura;

-- =====================================================================
-- 5. POBLAR Y VERIFICAR
-- =====================================================================
\echo ''
\echo '=== Poblando las 8 vistas materializadas (varios minutos) ==='
CALL gold.refrescar_vistas();

\echo ''
\echo '=== Verificacion de vistas ==='

\echo '-- V1 Filas por objeto (todas deben ser > 0; kpis = 1; calidad = 18):'
SELECT 'mv_resumen_contratos' AS objeto, count(*) AS filas FROM gold.mv_resumen_contratos
UNION ALL SELECT 'mv_serie_mensual',    count(*) FROM gold.mv_serie_mensual
UNION ALL SELECT 'mv_entidad_resumen',  count(*) FROM gold.mv_entidad_resumen
UNION ALL SELECT 'mv_geografia',        count(*) FROM gold.mv_geografia
UNION ALL SELECT 'mv_proveedor_valor',  count(*) FROM gold.mv_proveedor_valor
UNION ALL SELECT 'mv_duracion',         count(*) FROM gold.mv_duracion
UNION ALL SELECT 'mv_kpis_globales',    count(*) FROM gold.mv_kpis_globales
UNION ALL SELECT 'mv_calidad_datos',    count(*) FROM gold.mv_calidad_datos
UNION ALL SELECT 'v_top20_proveedores', count(*) FROM gold.v_top20_proveedores
UNION ALL SELECT 'v_top20_entidades',   count(*) FROM gold.v_top20_entidades;

\echo '-- V2 RF-14: el total de versiones debe ser 13.005.402 y coincidir con plata:'
SELECT k.total_versiones,
       k.total_versiones = 13005402 AS cuadra_con_plata,
       k.total_versiones = (SELECT count(*) FROM silver.contratos) AS cuadra_con_silver
FROM gold.mv_kpis_globales k;

\echo '-- V3 KPIs completos (RF-15):'
SELECT * FROM gold.mv_kpis_globales;

\echo '-- V4 El valor total debe ser IDENTICO en las 6 fuentes (todo t):'
SELECT
  (SELECT sum(valor_ajustado) FROM gold.mv_resumen_contratos)
    = (SELECT sum(valor_ajustado) FROM gold.mv_serie_mensual)    AS resumen_vs_serie,
  (SELECT sum(valor_ajustado) FROM gold.mv_resumen_contratos)
    = (SELECT sum(valor_ajustado) FROM gold.mv_geografia)        AS resumen_vs_geografia,
  (SELECT sum(valor_ajustado) FROM gold.mv_resumen_contratos)
    = (SELECT sum(valor_ajustado) FROM gold.mv_proveedor_valor)  AS resumen_vs_proveedor,
  (SELECT sum(valor_ajustado) FROM gold.mv_resumen_contratos)
    = (SELECT sum(valor_ajustado) FROM gold.mv_entidad_resumen)  AS resumen_vs_entidad,
  (SELECT sum(valor_ajustado) FROM gold.mv_resumen_contratos)
    = (SELECT valor_contratado FROM gold.mv_kpis_globales)       AS resumen_vs_kpis;

\echo '-- V5 valor_gastado no puede superar el valor ajustado (debe dar t):'
SELECT (SELECT sum(valor_gastado) FROM gold.mv_resumen_contratos)
       <= (SELECT sum(valor_ajustado) FROM gold.mv_resumen_contratos) AS gastado_menor_o_igual;

\echo '-- V6 Evolucion anual (billones). 2018 debe acercarse a 100; 2026 parcial = t:'
SELECT anio, versiones,
       round(valor_ajustado / 1e12, 2) AS billones_valor,
       round(valor_gastado  / 1e12, 2) AS billones_gastado,
       var_versiones_pct, var_valor_pct, es_anio_parcial
FROM gold.v_evolucion_anual
ORDER BY anio;

\echo '-- V7 Top 5 de proveedores con HHI:'
SELECT posicion, nombre_proveedor, tipo_persona, entidades_distintas,
       round(valor_ajustado / 1e12, 3) AS billones, pct_del_total, pct_acumulado, hhi_global
FROM gold.v_top20_proveedores
WHERE posicion <= 5;

\echo '-- V8 Reporte de calidad (RF-19):'
SELECT orden, clase, indicador, regla, filas, porcentaje
FROM gold.mv_calidad_datos
ORDER BY orden;

\echo '-- V9 secop_lectura puede leer todas las vistas y materializadas (todo t):'
SELECT c.relname,
       CASE c.relkind WHEN 'v' THEN 'vista' ELSE 'materializada' END AS tipo,
       has_table_privilege('secop_lectura', c.oid, 'SELECT') AS puede_leer
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'gold'
  AND c.relkind IN ('v', 'm')
ORDER BY c.relkind DESC, c.relname;

\echo ''
\echo '### Vistas listas. Power BI debe conectarse solo a gold.v_* y gold.mv_*'