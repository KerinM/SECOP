-- =====================================================================
--  01b_trazabilidad_bronce.sql  ·  TRAZABILIDAD DE LA CAPA BRONCE
--  Responsable: Jose (Ingeniero ETL)
--  Requiere: bronze.secop_raw cargada (01_cargar_bronce.sql)
-- =====================================================================
--  Por qué: la carga dejó en archivo_origen el mismo valor para todas las
--  filas. Cada CSV traía solo los contratos FIRMADOS en un año
--  (secop_2017.csv = firmados en 2017), así que el año de la fecha de firma
--  dice exactamente de qué archivo salió cada fila.
--  Solo cambia esa columna de metadatos; los datos del CSV no se tocan.
--
--  En pgAdmin (Query Tool): correr cada bloque por separado.
--  El VACUUM debe ir SOLO (no se puede correr junto con otra instrucción).
-- =====================================================================

-- 1. Revisión previa: solo deben aparecer los años 2017 a 2026
SELECT left(fecha_de_firma_del_contrato, 4) AS anio, count(*)
FROM bronze.secop_raw GROUP BY 1 ORDER BY 1;

-- 2. Marcar el archivo de origen de cada fila (≈ 1 hora con 16 millones de filas)
--    Resultado esperado: UPDATE 16025993
UPDATE bronze.secop_raw
SET archivo_origen = 'secop_' || left(fecha_de_firma_del_contrato, 4) || '.csv';

-- 3. Liberar el espacio que dejó el UPDATE y actualizar estadísticas (correr SOLO)
VACUUM ANALYZE bronze.secop_raw;

-- 4. Verificación: 10 archivos con rangos de id_fila seguidos y sin cruzarse,
--    terminando en 16.025.993 (los archivos se cargaron en orden 2017 → 2026)
SELECT archivo_origen, count(*) AS filas, min(id_fila) AS desde, max(id_fila) AS hasta
FROM bronze.secop_raw
GROUP BY 1 ORDER BY 1;

-- 5. Bitácora: una fila por archivo
--    filas_portal = conteo que reporta datos.gov.co para ese año (2017 verificado).
--    Mientras esté vacío, el estado dice REVISAR.
DELETE FROM bronze.log_cargas;
INSERT INTO bronze.log_cargas (archivo, filas_portal, filas_cargadas)
SELECT archivo_origen,
       CASE archivo_origen WHEN 'secop_2017.csv' THEN 1498976 END,
       count(*)
FROM bronze.secop_raw
GROUP BY 1 ORDER BY 1;

SELECT * FROM bronze.log_cargas ORDER BY archivo;
