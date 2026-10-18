\echo '-- A. Particiones de fact_contrato por esquema (esperado: 13 en gold)'
SELECT n.nspname AS esquema, count(*) AS particiones
FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE i.inhparent = 'gold.fact_contrato'::regclass
GROUP BY n.nspname;

\echo '-- B. Objetos de gold SIN permiso SELECT para secop_lectura (esperado: 0)'
SELECT count(*) AS sin_permiso
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'gold'
  AND c.relkind IN ('r', 'p', 'v', 'm')
  AND NOT has_table_privilege('secop_lectura', c.oid, 'SELECT');

\echo '-- C. Tamano real de las tablas de gold (para volumetria.md 5.3)'
SELECT relname AS tabla, n_live_tup AS filas,
       pg_size_pretty(pg_total_relation_size(relid)) AS total
FROM pg_stat_user_tables
WHERE schemaname = 'gold'
ORDER BY pg_total_relation_size(relid) DESC;

\echo '-- D. Conciliar cifras de plata con las de oro'
SELECT count(*) FILTER (WHERE flag_valor_atipico)        AS atipicos,
       count(*) FILTER (WHERE flag_valor_extremo)        AS extremos_r9b,
       count(*) FILTER (WHERE flag_fechas_incoherentes)  AS fin_antes_inicio,
       count(*) FILTER (WHERE flag_fecha_invalida)       AS fecha_invalida,
       round(100.0 * count(*) FILTER (WHERE fecha_inicio IS NULL) / count(*), 2) AS pct_inicio_vacio
FROM silver.contratos;

\echo '-- E. Los 46 vacios (esperado: validas_null = 0, validas_cero = pct_vacio = 46)'
SELECT count(*) FILTER (WHERE versiones_validas IS NULL) AS validas_null,
       count(*) FILTER (WHERE versiones_validas = 0)     AS validas_cero,
       count(*) FILTER (WHERE pct_no_competitiva IS NULL) AS pct_vacio
FROM gold.v_no_competitiva_entidad;