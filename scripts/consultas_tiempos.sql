\timing on

SELECT e.nombre_entidad, e.nivel_entidad,
       sum(r.versiones_validas)                AS versiones,
       round(sum(r.valor_ajustado) / 1e9, 1)   AS miles_de_millones
FROM gold.mv_entidad_resumen r
JOIN gold.dim_entidad e ON e.sk_entidad = r.sk_entidad
WHERE r.anio = 2025 AND r.sk_entidad <> -1
GROUP BY e.nombre_entidad, e.nivel_entidad
ORDER BY sum(r.valor_ajustado) DESC NULLS LAST
LIMIT 20;

SELECT anio, versiones,
       round(valor_ajustado / 1e12, 2) AS billones,
       var_versiones_pct, var_valor_pct, es_anio_parcial
FROM gold.v_evolucion_anual
ORDER BY anio;

SELECT nombre_entidad, nivel_entidad, versiones_validas,
       versiones_no_competitivas, pct_no_competitiva
FROM gold.v_no_competitiva_entidad
WHERE anio = 2025 AND versiones_validas >= 100
ORDER BY pct_no_competitiva DESC NULLS LAST, versiones_validas DESC
LIMIT 20;

SELECT nombre_entidad, anio, modalidad, es_competitiva,
       versiones_validas, pct_de_la_entidad
FROM gold.v_no_competitiva_modalidad
WHERE nombre_entidad LIKE '%VALLEDUPAR%' AND anio = 2025
ORDER BY nombre_entidad, versiones_validas DESC
LIMIT 15;

SELECT posicion, nombre_proveedor, tipo_persona, entidades_distintas,
       round(valor_ajustado / 1e12, 3) AS billones,
       pct_del_total, pct_acumulado, hhi_global
FROM gold.v_top20_proveedores
ORDER BY posicion;

SELECT departamento, versiones,
       round(valor_ajustado / 1e12, 2) AS billones,
       pct_valor_anio
FROM gold.v_geografia_departamento
WHERE anio = 2025
ORDER BY valor_ajustado DESC
LIMIT 10;

SELECT departamento, municipio, sum(versiones) AS versiones,
       round(sum(valor_ajustado) / 1e12, 3) AS billones
FROM gold.mv_geografia
WHERE anio = 2025 AND municipio <> 'NO REGISTRA'
GROUP BY departamento, municipio
ORDER BY sum(valor_ajustado) DESC
LIMIT 15;

SELECT tipo_contrato, modalidad, versiones,
       promedio_dias, mediana_dias, p25_dias, p75_dias, p95_dias
FROM gold.mv_duracion
ORDER BY versiones DESC
LIMIT 15;

SELECT anio, nivel_entidad, versiones,
       round(valor_ajustado / 1e12, 2) AS billones, pct_valor_anio
FROM gold.v_nivel_entidad
ORDER BY anio, valor_ajustado DESC;

SELECT tipo_contrato, versiones,
       round(valor_ajustado / 1e12, 2) AS billones,
       valor_promedio_por_version
FROM gold.v_tipo_contrato
WHERE anio = 2025
ORDER BY valor_ajustado DESC NULLS LAST;

SELECT mes, round(avg(versiones)) AS versiones_promedio,
       round(avg(valor_ajustado) / 1e12, 2) AS billones_promedio
FROM gold.v_estacionalidad
WHERE anio BETWEEN 2017 AND 2025          -- años completos
GROUP BY mes
ORDER BY mes;

SELECT anio, tipo_persona, versiones,
       round(valor_ajustado / 1e12, 2) AS billones, pct_valor_anio
FROM gold.v_perfil_tipo_persona
ORDER BY anio, tipo_persona;

SELECT anio, origen, versiones, pct_versiones_anio, pct_valor_anio
FROM gold.v_participacion_origen
ORDER BY anio, origen;

SELECT posicion, nombre_entidad, versiones_total, versiones_atipicas,
       pct_atipicas, round(valor_atipico / 1e12, 2) AS billones_atipicos
FROM gold.v_atipicos_entidad
ORDER BY posicion
LIMIT 20;

SELECT agrupacion_estado, rango_estado, origen, sum(versiones) AS versiones,
       round(sum(valor_ajustado) / 1e12, 2) AS billones
FROM gold.v_estado_contrato
WHERE anio = 2025
GROUP BY agrupacion_estado, rango_estado, origen
ORDER BY rango_estado, origen;

SELECT r.anio, e.nombre_entidad,
       round(sum(r.valor_gastado) / 1e9, 1) AS gastado_miles_de_millones
FROM gold.mv_entidad_resumen r
JOIN gold.dim_entidad e ON e.sk_entidad = r.sk_entidad
WHERE r.anio = 2025 AND r.sk_entidad <> -1
GROUP BY r.anio, e.nombre_entidad
ORDER BY sum(r.valor_gastado) DESC NULLS LAST
LIMIT 20;

SELECT anio, tipo_contrato,
       round(sum(valor_gastado) / 1e12, 2) AS billones_gastado
FROM gold.mv_resumen_contratos
GROUP BY anio, tipo_contrato
ORDER BY anio, sum(valor_gastado) DESC NULLS LAST;

WITH mc AS (
    SELECT f.sk_entidad, f.sk_proveedor, t.fecha
    FROM gold.fact_contrato f
    JOIN gold.dim_contrato c ON c.sk_contrato = f.sk_contrato
    JOIN gold.dim_tiempo   t ON t.sk_tiempo   = f.sk_fecha_firma
    WHERE c.modalidad = 'MINIMA CUANTIA'
      AND f.sk_fecha_firma BETWEEN 20250101 AND 20251231
      AND NOT f.es_atipico
      AND f.sk_entidad <> -1 AND f.sk_proveedor <> -1
), ventana AS (
    SELECT sk_entidad, sk_proveedor,
           count(*) OVER (PARTITION BY sk_entidad, sk_proveedor
                          ORDER BY fecha
                          RANGE BETWEEN INTERVAL '29 days' PRECEDING AND CURRENT ROW) AS en_30_dias
    FROM mc
)
SELECT e.nombre_entidad, p.nombre_proveedor, max(v.en_30_dias) AS max_versiones_en_30_dias
FROM ventana v
JOIN gold.dim_entidad   e ON e.sk_entidad   = v.sk_entidad
JOIN gold.dim_proveedor p ON p.sk_proveedor = v.sk_proveedor
GROUP BY e.nombre_entidad, p.nombre_proveedor
HAVING max(v.en_30_dias) >= 5
ORDER BY max_versiones_en_30_dias DESC
LIMIT 20;

SELECT total_versiones, versiones_validas, contratos_distintos,
       contratos_con_versiones, entidades, proveedores,
       departamentos, municipios,
       round(valor_contratado / 1e12, 1) AS billones_contratado,
       round(valor_gastado    / 1e12, 1) AS billones_gastado
FROM gold.mv_kpis_globales;

SELECT orden, clase, indicador, regla, filas, porcentaje
FROM gold.mv_calidad_datos
ORDER BY orden;
