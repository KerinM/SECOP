-- =====================================================================
-- 02b_correccion_barras.sql  ·  CORRECCIÓN PUNTUAL DE LA CAPA PLATA
-- Responsable: Jose (Ingeniero ETL)
-- Hallazgo de QA: textos con '|' suelta al inicio o al final que la
-- versión anterior de limpiar_texto() no quitaba.
-- Este script: 1) actualiza la función (igual que en 02_silver_limpieza.sql)
--              2) corrige SOLO las filas afectadas (no hay que rehacer plata)
-- =====================================================================

-- 1. Nueva versión de la regla R1
CREATE OR REPLACE FUNCTION silver.limpiar_texto(t TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN v IN ('', 'NO DEFINIDO', 'NO DEFINIDA', 'SIN DESCRIPCION',
                           'NO REGISTRA', 'N/A', 'NA', 'NULL', '-')
                THEN NULL ELSE v END
    FROM (SELECT upper(regexp_replace(
                     regexp_replace(public.unaccent('public.unaccent', t), '\s+', ' ', 'g'),
                     '^[\s|]+|[\s|]+$', '', 'g')) AS v) s
$$;

-- 2. Corrección de las filas afectadas
--    (aplicar la función a un texto ya limpio no lo cambia, así que es seguro)
UPDATE silver.contratos SET
    nivel_entidad    = silver.limpiar_texto(nivel_entidad),
    nombre_entidad   = silver.limpiar_texto(nombre_entidad),
    departamento     = silver.homologar('departamento',  silver.limpiar_texto(departamento)),
    municipio        = silver.homologar('municipio',     silver.limpiar_texto(municipio)),
    estado_proceso   = silver.limpiar_texto(estado_proceso),
    modalidad        = silver.homologar('modalidad',     silver.limpiar_texto(modalidad)),
    tipo_contrato    = silver.homologar('tipo_contrato', silver.limpiar_texto(tipo_contrato)),
    nombre_proveedor = silver.limpiar_texto(nombre_proveedor)
WHERE nivel_entidad    ~ '^\||\|$' OR nombre_entidad ~ '^\||\|$'
   OR departamento     ~ '^\||\|$' OR municipio      ~ '^\||\|$'
   OR estado_proceso   ~ '^\||\|$' OR modalidad      ~ '^\||\|$'
   OR tipo_contrato    ~ '^\||\|$' OR nombre_proveedor ~ '^\||\|$';
