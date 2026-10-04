-- =====================================================================
-- eda_perfilado.sql  ·  EXPLORACIÓN DE BRONCE (solo consultas, no cambia nada)
-- Requiere: las funciones de 02_silver_limpieza.sql
-- Sus resultados justifican las reglas de limpieza R1–R9
-- =====================================================================
-- ---------------------------------------------------------------------
-- 3. EDA: PERFILADO SOBRE BRONCE (consultas de exploración)
-- ---------------------------------------------------------------------
-- 3.1 Variantes de escritura de una misma categoría
SELECT nivel_entidad, count(*) AS filas
FROM bronze.secop_raw GROUP BY 1 ORDER BY 2 DESC;

-- 3.2 Completitud: % de filas sin dato real (NULL o 'NO DEFINIDO')
SELECT round(100.0 * count(*) FILTER (WHERE silver.limpiar_texto(documento_proveedor) IS NULL) / count(*), 2) AS pct_sin_documento,
       round(100.0 * count(*) FILTER (WHERE silver.limpiar_texto(municipio_entidad)   IS NULL) / count(*), 2) AS pct_sin_municipio,
       round(100.0 * count(*) FILTER (WHERE silver.a_fecha(fecha_de_firma_del_contrato) IS NULL) / count(*), 2) AS pct_sin_fecha_firma
FROM bronze.secop_raw;

-- 3.3 Validez: rango de fechas y valores
SELECT min(silver.a_fecha(fecha_inicio_ejecucion)) AS inicio_min,
       max(silver.a_fecha(fecha_fin_ejecucion))    AS fin_max,
       count(*) FILTER (WHERE silver.a_numero(valor_contrato) = 0) AS contratos_en_cero,
       max(silver.a_numero(valor_contrato))        AS valor_max
FROM bronze.secop_raw;

-- 3.4 Unicidad: mismo ID de contrato con el mismo valor en muchas filas
SELECT numero_del_contrato, valor_contrato, count(*) AS filas
FROM bronze.secop_raw
GROUP BY 1, 2 HAVING count(*) > 1
ORDER BY 3 DESC LIMIT 10;

