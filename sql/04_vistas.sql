-- =====================================================================
-- 04_vistas.sql  ·  SECOP Integrado  ·  Capa de consumo para Power BI
-- Responsable: Isabella (QA / Visualizacion)  ·  RF-13 a RF-20
-- =====================================================================

\set ON_ERROR_STOP on
\pset pager off

-- ---------------------------------------------------------------------
-- 0. Limpieza idempotente (orden inverso a las dependencias)
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS gold.v_top20_proveedores        CASCADE;
DROP VIEW IF EXISTS gold.v_geografia_departamento   CASCADE;
DROP VIEW IF EXISTS gold.v_evolucion_anual          CASCADE;
DROP MATERIALIZED VIEW IF EXISTS gold.mv_calidad_datos        CASCADE;
DROP MATERIALIZED VIEW IF EXISTS gold.mv_perfil_documental    CASCADE;
DROP MATERIALIZED VIEW IF EXISTS gold.mv_proveedor_valor      CASCADE;
DROP MATERIALIZED VIEW IF EXISTS gold.mv_kpis_globales        CASCADE;
DROP MATERIALIZED VIEW IF EXISTS gold.mv_geografia_municipio  CASCADE;
DROP MATERIALIZED VIEW IF EXISTS gold.mv_resumen_contratos    CASCADE;
DROP VIEW IF EXISTS gold.v_dim_entidad              CASCADE;

-- ---------------------------------------------------------------------
-- 1. v_dim_entidad  ·  punto unico de normalizacion geografica
-- ---------------------------------------------------------------------
CREATE VIEW gold.v_dim_entidad AS
SELECT
    e.id_entidad,
    e.codigo_entidad,
    e.nombre_entidad,
    e.nit_entidad,
    coalesce(silver.normaliza_texto(e.nivel_entidad), 'No Definido')  AS nivel_entidad,
    coalesce(silver.normaliza_texto(e.departamento), 'No Definido')   AS departamento,
    coalesce(silver.normaliza_texto(e.municipio), 'No Definido')      AS municipio
FROM gold.dim_entidad e;

COMMENT ON VIEW gold.v_dim_entidad IS
    'Entidad con departamento, municipio y nivel normalizados. Punto unico para corregir variantes geograficas (RF-05, RF-11).';

-- ---------------------------------------------------------------------
-- 2. mv_resumen_contratos  ·  cubo base para tablero, filtros y evolucion
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW gold.mv_resumen_contratos AS
SELECT
    extract(year    FROM f.fecha_firma)::int             AS anio,
    extract(quarter FROM f.fecha_firma)::int             AS trimestre,
    e.departamento,
    e.nivel_entidad,
    coalesce(tc.descripcion, tc.codigo)                  AS tipo_contrato,
    coalesce(m.descripcion,  m.codigo)                   AS modalidad,
    coalesce(es.descripcion, es.codigo)                  AS estado,
    coalesce(o.descripcion,  o.codigo)                   AS origen,
    count(*)                                             AS contratos,
    count(*) FILTER (WHERE f.valor_contrato > 0
                       AND f.valor_contrato < 1000000000000)  AS contratos_con_valor,
    coalesce(sum(f.valor_contrato) FILTER (WHERE f.valor_contrato > 0
                       AND f.valor_contrato < 1000000000000), 0)::numeric(20,2) AS valor_total
FROM gold.fact_contrato f
JOIN gold.v_dim_entidad     e  ON e.id_entidad        = f.id_entidad
JOIN gold.dim_tipo_contrato tc ON tc.id_tipo_contrato = f.id_tipo_contrato
JOIN gold.dim_modalidad     m  ON m.id_modalidad      = f.id_modalidad
JOIN gold.dim_estado        es ON es.id_estado        = f.id_estado
JOIN gold.dim_origen        o  ON o.id_origen         = f.id_origen
WHERE NOT f.fecha_firma_es_centinela
  AND f.fecha_firma >= DATE '1994-01-01'
  AND f.fecha_firma <  DATE '2027-01-01'
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
WITH NO DATA;

CREATE INDEX ix_mv_resumen_anio_depto
    ON gold.mv_resumen_contratos (anio, departamento);

COMMENT ON MATERIALIZED VIEW gold.mv_resumen_contratos IS
    'Cubo base. Excluye fecha centinela y anios fuera de 1994-2026 (D-05). valor_total excluye 0 y >= 1e12 (D-06). Fuente de v_evolucion_anual y v_geografia_departamento.';

-- ---------------------------------------------------------------------
-- 3. v_evolucion_anual  ·  RF-16 / RF-10
-- ---------------------------------------------------------------------
CREATE VIEW gold.v_evolucion_anual AS
WITH anual AS (
    SELECT anio,
           sum(contratos)   AS contratos,
           sum(valor_total) AS valor_total
    FROM gold.mv_resumen_contratos
    GROUP BY anio
)
SELECT
    anio,
    contratos,
    valor_total,
    round(100.0 * (contratos - lag(contratos) OVER w)
          / nullif(lag(contratos) OVER w, 0), 2)         AS var_contratos_pct,
    round(100.0 * (valor_total - lag(valor_total) OVER w)
          / nullif(lag(valor_total) OVER w, 0), 2)       AS var_valor_pct
FROM anual
WINDOW w AS (ORDER BY anio)
ORDER BY anio;

COMMENT ON VIEW gold.v_evolucion_anual IS
    'Serie anual de contratos y valor con variacion interanual contra el anio anterior presente (RF-10, RF-16). Para desglose por trimestre, tipo o modalidad usar mv_resumen_contratos.';

-- ---------------------------------------------------------------------
-- 4. Geografia  ·  RF-17 / RF-11
-- ---------------------------------------------------------------------
CREATE VIEW gold.v_geografia_departamento AS
SELECT
    anio,
    departamento,
    sum(contratos)   AS contratos,
    sum(valor_total) AS valor_total,
    round(100.0 * sum(contratos)
          / nullif(sum(sum(contratos)) OVER (PARTITION BY anio), 0), 2)   AS pct_contratos_anio,
    round(100.0 * sum(valor_total)
          / nullif(sum(sum(valor_total)) OVER (PARTITION BY anio), 0), 2) AS pct_valor_anio
FROM gold.mv_resumen_contratos
GROUP BY anio, departamento;

COMMENT ON VIEW gold.v_geografia_departamento IS
    'Contratos y valor por departamento y anio, con participacion sobre el total nacional del anio (resalta Bogota y Antioquia, RF-17).';

CREATE MATERIALIZED VIEW gold.mv_geografia_municipio AS
SELECT
    extract(year FROM f.fecha_firma)::int   AS anio,
    e.departamento,
    e.municipio,
    count(*)                                AS contratos,
    coalesce(sum(f.valor_contrato) FILTER (WHERE f.valor_contrato > 0
                       AND f.valor_contrato < 1000000000000), 0)::numeric(20,2) AS valor_total
FROM gold.fact_contrato f
JOIN gold.v_dim_entidad e ON e.id_entidad = f.id_entidad
WHERE NOT f.fecha_firma_es_centinela
  AND f.fecha_firma >= DATE '1994-01-01'
  AND f.fecha_firma <  DATE '2027-01-01'
GROUP BY 1, 2, 3
WITH NO DATA;

CREATE INDEX ix_mv_geo_mun ON gold.mv_geografia_municipio (departamento, municipio);

-- ---------------------------------------------------------------------
-- 5. mv_kpis_globales  ·  RF-15
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW gold.mv_kpis_globales AS
SELECT
    count(*)                                                        AS total_contratos,
    count(*) FILTER (WHERE NOT f.fecha_firma_es_centinela)          AS contratos_con_fecha_valida,
    count(*) FILTER (WHERE f.fecha_firma_es_centinela)              AS contratos_sin_fecha_valida,
    coalesce(sum(f.valor_contrato) FILTER (WHERE f.valor_contrato > 0
                       AND f.valor_contrato < 1000000000000), 0)::numeric(20,2) AS valor_total_contratado,
    (SELECT count(*) FROM gold.dim_entidad)                         AS entidades,
    (SELECT count(*) FROM gold.dim_proveedor)                       AS proveedores,
    (SELECT count(DISTINCT departamento) FROM gold.v_dim_entidad
      WHERE lower(departamento) NOT IN ('no definido', 'colombia')) AS departamentos,
    (SELECT count(DISTINCT municipio) FROM gold.v_dim_entidad
      WHERE municipio <> 'No Definido')                             AS municipios
FROM gold.fact_contrato f
WITH NO DATA;

COMMENT ON MATERIALIZED VIEW gold.mv_kpis_globales IS
    'KPIs del panel principal (RF-15). Cada cifra debe coincidir con su consulta SQL equivalente.';

-- ---------------------------------------------------------------------
-- 6. Proveedores  ·  RF-18 / RF-12
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW gold.mv_proveedor_valor AS
SELECT
    f.id_proveedor,
    count(*)                                                        AS contratos,
    coalesce(sum(f.valor_contrato) FILTER (WHERE f.valor_contrato > 0
                       AND f.valor_contrato < 1000000000000), 0)::numeric(20,2) AS valor_total
FROM gold.fact_contrato f
GROUP BY f.id_proveedor
WITH NO DATA;

CREATE INDEX ix_mv_provval_valor ON gold.mv_proveedor_valor (valor_total DESC);

CREATE VIEW gold.v_top20_proveedores AS
WITH tot AS (
    SELECT sum(valor_total) AS valor_nacional,
           round(sum(power(100.0 * valor_total / nullif((SELECT sum(valor_total)
                  FROM gold.mv_proveedor_valor), 0), 2)), 2) AS hhi
    FROM gold.mv_proveedor_valor
), top AS (
    SELECT id_proveedor, contratos, valor_total
    FROM gold.mv_proveedor_valor
    ORDER BY valor_total DESC, id_proveedor
    LIMIT 20
)
SELECT
    row_number() OVER (ORDER BY t.valor_total DESC, t.id_proveedor)     AS posicion,
    p.razon_social,
    p.documento,
    p.tipo_documento,
    t.contratos,
    t.valor_total,
    round(100.0 * t.valor_total / nullif(tot.valor_nacional, 0), 3)      AS pct_del_total,
    round(100.0 * sum(t.valor_total) OVER (ORDER BY t.valor_total DESC, t.id_proveedor)
          / nullif(tot.valor_nacional, 0), 3)                            AS pct_acumulado,
    tot.hhi                                                              AS hhi_global
FROM top t
JOIN gold.dim_proveedor p ON p.id_proveedor = t.id_proveedor
CROSS JOIN tot
ORDER BY posicion;

COMMENT ON VIEW gold.v_top20_proveedores IS
    'Top 20 de proveedores por valor contratado, con % del total, % acumulado y HHI global (0-10.000). Debe coincidir con la consulta de RF-07.';

CREATE MATERIALIZED VIEW gold.mv_perfil_documental AS
SELECT
    coalesce(td.descripcion, td.codigo)                             AS tipo_documento,
    count(*)                                                        AS contratos,
    count(DISTINCT f.id_proveedor)                                  AS proveedores,
    coalesce(sum(f.valor_contrato) FILTER (WHERE f.valor_contrato > 0
                       AND f.valor_contrato < 1000000000000), 0)::numeric(20,2) AS valor_total
FROM gold.fact_contrato f
JOIN gold.dim_tipo_documento td ON td.id_tipo_documento = f.id_tipo_documento
GROUP BY 1
WITH NO DATA;

COMMENT ON MATERIALIZED VIEW gold.mv_perfil_documental IS
    'Contratos, proveedores y valor por tipo documental (RF-12). Permite resaltar la proporcion de "NO DEFINIDO" y separar persona natural de juridica en el tablero.';

-- ---------------------------------------------------------------------
-- 7. mv_calidad_datos  ·  RF-14 / RF-19
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW gold.mv_calidad_datos AS
WITH base AS (
    SELECT
        count(*)                                                        AS total,
        count(*) FILTER (WHERE fecha_firma_es_centinela)                AS sin_fecha_valida,
        count(*) FILTER (WHERE fecha_firma_es_centinela
                           AND fecha_firma_original IS NOT NULL)        AS fecha_imposible_con_original,
        count(*) FILTER (WHERE valor_contrato = 0)                      AS valor_cero,
        count(*) FILTER (WHERE valor_contrato >= 1000000000000)         AS valor_centinela,
        count(*) FILTER (WHERE fecha_fin < fecha_inicio)                AS fin_antes_de_inicio,
        count(*) FILTER (WHERE fecha_fin IS NULL)                       AS sin_fecha_fin
    FROM gold.fact_contrato
), rep AS (
    SELECT coalesce(sum(n), 0)::bigint AS filas_repetidas
    FROM (SELECT count(*) AS n
          FROM gold.fact_contrato
          WHERE numero_contrato IS NOT NULL
          GROUP BY numero_contrato
          HAVING count(*) > 1) g
)
SELECT v.orden, v.clase, v.indicador, v.filas,
       round(100.0 * v.filas / nullif(b.total, 0), 2) AS porcentaje
FROM base b, rep r,
LATERAL (VALUES
    (1, '1 · Fechas imposibles o ausentes', 'Sin fecha de firma valida (centinela 1900-01-01)', b.sin_fecha_valida),
    (2, '1 · Fechas imposibles o ausentes', 'Fecha imposible con valor original conservado',     b.fecha_imposible_con_original),
    (3, '1 · Fechas imposibles o ausentes', 'Sin fecha de fin de ejecucion',                     b.sin_fecha_fin),
    (4, '1 · Fechas imposibles o ausentes', 'Fecha de fin anterior a la de inicio',              b.fin_antes_de_inicio),
    (5, '2 · Duplicados de numero de contrato', 'Filas que comparten numero_contrato',           r.filas_repetidas),
    (6, '4 · Valores cero y centinela',     'valor_contrato = 0',                                b.valor_cero),
    (7, '4 · Valores cero y centinela',     'valor_contrato >= 1e12 (centinela)',                b.valor_centinela),
    (8, '0 · Total de referencia',          'Total de filas en fact_contrato',                   b.total)
) AS v(orden, clase, indicador, filas)
WITH NO DATA;

COMMENT ON MATERIALIZED VIEW gold.mv_calidad_datos IS
    'Anomalias medidas sobre gold con cantidad y porcentaje (RF-14, RF-19). La clase 3 (mayusculas) se mide en sql/05_qa.sql contra silver.';

-- ---------------------------------------------------------------------
-- 8. Refresco
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE gold.refrescar_vistas()
LANGUAGE plpgsql
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW gold.mv_resumen_contratos;
    REFRESH MATERIALIZED VIEW gold.mv_geografia_municipio;
    REFRESH MATERIALIZED VIEW gold.mv_kpis_globales;
    REFRESH MATERIALIZED VIEW gold.mv_proveedor_valor;
    REFRESH MATERIALIZED VIEW gold.mv_perfil_documental;
    REFRESH MATERIALIZED VIEW gold.mv_calidad_datos;
END
$$;

COMMENT ON PROCEDURE gold.refrescar_vistas() IS
    'Refresca las 6 vistas materializadas. Ejecutar tras cada carga: CALL gold.refrescar_vistas();';

-- ---------------------------------------------------------------------
-- 9. Permisos
-- ---------------------------------------------------------------------
GRANT USAGE  ON SCHEMA gold TO secop_lectura;
GRANT SELECT ON ALL TABLES IN SCHEMA gold TO secop_lectura;

-- ---------------------------------------------------------------------
-- 10. Poblar y verificar
-- ---------------------------------------------------------------------
\echo ''
\echo '=== Poblando vistas materializadas (puede tardar varios minutos) ==='
CALL gold.refrescar_vistas();

\echo ''
\echo '-- Filas por objeto:'
SELECT 'mv_resumen_contratos'   AS objeto, count(*) AS filas FROM gold.mv_resumen_contratos
UNION ALL SELECT 'mv_geografia_municipio', count(*) FROM gold.mv_geografia_municipio
UNION ALL SELECT 'mv_kpis_globales',       count(*) FROM gold.mv_kpis_globales
UNION ALL SELECT 'mv_proveedor_valor',     count(*) FROM gold.mv_proveedor_valor
UNION ALL SELECT 'mv_perfil_documental',   count(*) FROM gold.mv_perfil_documental
UNION ALL SELECT 'mv_calidad_datos',       count(*) FROM gold.mv_calidad_datos
UNION ALL SELECT 'v_evolucion_anual',      count(*) FROM gold.v_evolucion_anual
UNION ALL SELECT 'v_top20_proveedores',    count(*) FROM gold.v_top20_proveedores;

\echo '-- RF-14: el total de contratos debe ser 22.670.028:'
SELECT total_contratos, total_contratos = 22670028 AS cuadra_con_api
FROM gold.mv_kpis_globales;

\echo '-- secop_lectura puede leer todas las vistas de este script:'
SELECT c.relname, has_table_privilege('secop_lectura', c.oid, 'SELECT') AS puede_leer
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'gold'
  AND c.relkind IN ('v', 'm')
ORDER BY c.relname;

\echo ''
\echo '### Vistas listas. Power BI debe conectarse solo a gold.v_* y gold.mv_*'