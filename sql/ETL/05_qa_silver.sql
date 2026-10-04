-- =====================================================================
-- 05_qa_silver.sql  ·  PRUEBAS DE CALIDAD DE LA CAPA PLATA
-- Responsable: Jose (Ingeniero ETL)
-- Requiere: silver.contratos (02_silver_limpieza.sql)
-- Correr cada prueba por separado en el Query Tool (seleccionar + F5)
-- =====================================================================


-- ---------------------------------------------------------------------
-- PRUEBA 1. VALIDACIONES AUTOMÁTICAS (todas deben dar 0 → OK)
--   Una sola pasada por la tabla. Cada fila es una regla de limpieza:
--   si "encontrados" no es 0, la regla dejó algo sin corregir.
-- ---------------------------------------------------------------------
WITH c AS (
    SELECT
        count(*) AS total,
        -- R1: textos en mayúsculas, sin tildes ni espacios sobrantes
        count(*) FILTER (WHERE concat_ws('|', nivel_entidad, nombre_entidad, departamento, municipio,
                                         estado_proceso, modalidad, tipo_contrato, nombre_proveedor)
                               ~ '[a-záéíóúñ]')                                         AS r1_minusculas,
        count(*) FILTER (WHERE concat_ws('|', nivel_entidad, nombre_entidad, departamento, municipio,
                                         estado_proceso, modalidad, tipo_contrato, nombre_proveedor)
                               ~ '[ÁÉÍÓÚÑ]')                                            AS r1_tildes,
        -- (columna por columna: un texto que traiga '|' adentro no cuenta como error)
        count(*) FILTER (WHERE nivel_entidad    ~ '\s{2,}|^\s|\s$' OR nombre_entidad ~ '\s{2,}|^\s|\s$'
                            OR departamento     ~ '\s{2,}|^\s|\s$' OR municipio      ~ '\s{2,}|^\s|\s$'
                            OR estado_proceso   ~ '\s{2,}|^\s|\s$' OR modalidad      ~ '\s{2,}|^\s|\s$'
                            OR tipo_contrato    ~ '\s{2,}|^\s|\s$' OR nombre_proveedor ~ '\s{2,}|^\s|\s$')
                                                                                         AS r1_espacios,
        count(*) FILTER (WHERE nivel_entidad    ~ '^\||\|$' OR nombre_entidad ~ '^\||\|$'
                            OR departamento     ~ '^\||\|$' OR municipio      ~ '^\||\|$'
                            OR estado_proceso   ~ '^\||\|$' OR modalidad      ~ '^\||\|$'
                            OR tipo_contrato    ~ '^\||\|$' OR nombre_proveedor ~ '^\||\|$')
                                                                                         AS r1_barras_sueltas,
        -- R2: nulos disfrazados que siguen como texto
        count(*) FILTER (WHERE 'NO DEFINIDO' IN (nivel_entidad, departamento, municipio, estado_proceso,
                                                 modalidad, tipo_contrato, tipo_doc_proveedor)
                            OR 'NO REGISTRA' IN (nivel_entidad, departamento, municipio, estado_proceso,
                                                 modalidad, tipo_contrato, tipo_doc_proveedor)
                            OR 'N/A'         IN (nivel_entidad, departamento, municipio, estado_proceso,
                                                 modalidad, tipo_contrato, tipo_doc_proveedor))
                                                                                         AS r2_nulos_disfrazados,
        -- R4: fechas fuera del rango válido
        count(*) FILTER (WHERE fecha_firma  NOT BETWEEN DATE '2000-01-01' AND CURRENT_DATE)     AS r4_firma_fuera_rango,
        count(*) FILTER (WHERE fecha_inicio NOT BETWEEN DATE '2000-01-01' AND DATE '2060-12-31') AS r4_inicio_fuera_rango,
        count(*) FILTER (WHERE fecha_fin    NOT BETWEEN DATE '2000-01-01' AND DATE '2060-12-31') AS r4_fin_fuera_rango,
        -- R4: fin antes del inicio y sin bandera
        count(*) FILTER (WHERE fecha_fin < fecha_inicio AND NOT flag_fechas_incoherentes)        AS r4_incoherentes_sin_bandera,
        -- R6: valor en cero o negativo sin bandera / valores de relleno 999...
        count(*) FILTER (WHERE valor_contrato <= 0 AND NOT flag_valor_cero)                      AS r6_cero_sin_bandera,
        count(*) FILTER (WHERE valor_contrato::text ~ '^9{8,}(\.0+)?$')                          AS r6_relleno_sin_limpiar,
        -- R7: el valor ajustado nunca puede superar el valor original
        count(*) FILTER (WHERE valor_contrato > 0 AND valor_ajustado > valor_contrato)           AS r7_ajustado_mayor,
        -- R8: NIT y documento solo con dígitos
        count(*) FILTER (WHERE nit_entidad !~ '^\d+$')                                           AS r8_nit_no_numerico,
        count(*) FILTER (WHERE documento_proveedor !~ '^\d+$')                                   AS r8_documento_no_numerico
    FROM silver.contratos
)
SELECT p.regla, p.prueba, p.encontrados,
       CASE WHEN p.encontrados = 0 THEN 'OK' ELSE 'REVISAR' END AS estado
FROM c, LATERAL (VALUES
    ('R1', 'Textos con minúsculas',                       c.r1_minusculas),
    ('R1', 'Textos con tildes',                           c.r1_tildes),
    ('R1', 'Textos con espacios dobles o sobrantes',      c.r1_espacios),
    ('R1', 'Barras | sueltas al inicio o al final',       c.r1_barras_sueltas),
    ('R2', 'Nulos disfrazados (NO DEFINIDO, N/A...)',     c.r2_nulos_disfrazados),
    ('R4', 'Fecha de firma fuera de rango',               c.r4_firma_fuera_rango),
    ('R4', 'Fecha de inicio fuera de rango',              c.r4_inicio_fuera_rango),
    ('R4', 'Fecha de fin fuera de rango',                 c.r4_fin_fuera_rango),
    ('R4', 'Fin antes del inicio sin marcar',             c.r4_incoherentes_sin_bandera),
    ('R6', 'Valor en cero sin marcar',                    c.r6_cero_sin_bandera),
    ('R6', 'Valores de relleno (999...) sin limpiar',     c.r6_relleno_sin_limpiar),
    ('R7', 'Valor ajustado mayor que el original',        c.r7_ajustado_mayor),
    ('R8', 'NIT de entidad con caracteres no numéricos',  c.r8_nit_no_numerico),
    ('R8', 'Documento de proveedor no numérico',          c.r8_documento_no_numerico)
) AS p(regla, prueba, encontrados);


-- ---------------------------------------------------------------------
-- PRUEBA 2. DUPLICADOS (R5): debe dar 0
--   Misma llave que usó la deduplicación en 02_silver_limpieza.sql
-- ---------------------------------------------------------------------
SELECT count(*) AS grupos_duplicados_en_plata
FROM (
    SELECT 1
    FROM silver.contratos
    GROUP BY origen, id_contrato, id_proceso, documento_proveedor, valor_contrato, fecha_firma
    HAVING count(*) > 1
) d;


-- ---------------------------------------------------------------------
-- PRUEBA 3. COMPLETITUD: % de vacíos (NULL) por columna
--   No todos tienen que ser 0: un NULL en plata significa "el dato venía
--   vacío, era 'NO DEFINIDO' o era imposible". Se reporta, no se inventa.
-- ---------------------------------------------------------------------
WITH c AS (
    SELECT count(*) AS total,
           count(*) FILTER (WHERE id_contrato         IS NULL) AS id_contrato,
           count(*) FILTER (WHERE codigo_entidad      IS NULL) AS codigo_entidad,
           count(*) FILTER (WHERE nit_entidad         IS NULL) AS nit_entidad,
           count(*) FILTER (WHERE departamento        IS NULL) AS departamento,
           count(*) FILTER (WHERE municipio           IS NULL) AS municipio,
           count(*) FILTER (WHERE modalidad           IS NULL) AS modalidad,
           count(*) FILTER (WHERE tipo_contrato       IS NULL) AS tipo_contrato,
           count(*) FILTER (WHERE fecha_firma         IS NULL) AS fecha_firma,
           count(*) FILTER (WHERE fecha_inicio        IS NULL) AS fecha_inicio,
           count(*) FILTER (WHERE fecha_fin           IS NULL) AS fecha_fin,
           count(*) FILTER (WHERE valor_contrato      IS NULL) AS valor_contrato,
           count(*) FILTER (WHERE documento_proveedor IS NULL) AS documento_proveedor,
           count(*) FILTER (WHERE nombre_proveedor    IS NULL) AS nombre_proveedor
    FROM silver.contratos
)
SELECT p.columna, p.vacios, round(100.0 * p.vacios / c.total, 2) AS pct_vacios
FROM c, LATERAL (VALUES
    ('id_contrato', c.id_contrato), ('codigo_entidad', c.codigo_entidad), ('nit_entidad', c.nit_entidad),
    ('departamento', c.departamento), ('municipio', c.municipio), ('modalidad', c.modalidad),
    ('tipo_contrato', c.tipo_contrato), ('fecha_firma', c.fecha_firma), ('fecha_inicio', c.fecha_inicio),
    ('fecha_fin', c.fecha_fin), ('valor_contrato', c.valor_contrato),
    ('documento_proveedor', c.documento_proveedor), ('nombre_proveedor', c.nombre_proveedor)
) AS p(columna, vacios)
ORDER BY pct_vacios DESC;


-- ---------------------------------------------------------------------
-- PRUEBA 4. BANDERAS DE CALIDAD: cuántas filas marcó cada regla
-- ---------------------------------------------------------------------
SELECT count(*)                                         AS total_plata,
       count(*) FILTER (WHERE flag_fecha_invalida)      AS fecha_invalida,
       count(*) FILTER (WHERE flag_fechas_incoherentes) AS fechas_incoherentes,
       count(*) FILTER (WHERE flag_valor_cero)          AS valor_cero,
       count(*) FILTER (WHERE flag_valor_relleno)       AS valor_relleno,
       count(*) FILTER (WHERE flag_valor_repetido)      AS valor_repetido,
       count(*) FILTER (WHERE flag_valor_atipico)       AS valor_atipico
FROM silver.contratos;


-- ---------------------------------------------------------------------
-- PRUEBA 5. CATEGORÍAS UNIFICADAS (R1 + R3)
--   En bronce nivel_entidad tenía 7 variantes; aquí deben quedar pocas
-- ---------------------------------------------------------------------
SELECT nivel_entidad, count(*) AS filas FROM silver.contratos GROUP BY 1 ORDER BY 2 DESC;
SELECT modalidad,     count(*) AS filas FROM silver.contratos GROUP BY 1 ORDER BY 2 DESC;


-- ---------------------------------------------------------------------
-- PRUEBA 6. ANTES Y DESPUÉS (bronce vs. plata por id_fila)
--   Ejemplos reales de cada regla. Se une por id_fila (trazabilidad).
-- ---------------------------------------------------------------------
-- 6.1 Textos (R1, R2, R3)
SELECT s.id_fila,
       b.nivel_entidad        AS nivel_bronce,  s.nivel_entidad AS nivel_plata,
       b.departamento_entidad AS depto_bronce,  s.departamento  AS depto_plata,
       b.municipio_entidad    AS muni_bronce,   s.municipio     AS muni_plata
FROM silver.contratos s
JOIN bronze.secop_raw b USING (id_fila)
WHERE b.nivel_entidad <> s.nivel_entidad
   OR b.departamento_entidad IS DISTINCT FROM s.departamento
LIMIT 10;

-- 6.2 Fechas imposibles (R4)
SELECT s.id_fila,
       b.fecha_inicio_ejecucion AS inicio_bronce, s.fecha_inicio AS inicio_plata,
       b.fecha_fin_ejecucion    AS fin_bronce,    s.fecha_fin    AS fin_plata,
       s.flag_fecha_invalida
FROM silver.contratos s
JOIN bronze.secop_raw b USING (id_fila)
WHERE s.flag_fecha_invalida
LIMIT 10;

-- 6.3 Valores de relleno (R6)
SELECT s.id_fila, b.valor_contrato AS valor_bronce, s.valor_contrato AS valor_plata, s.flag_valor_relleno
FROM silver.contratos s
JOIN bronze.secop_raw b USING (id_fila)
WHERE s.flag_valor_relleno
LIMIT 10;

-- 6.4 NIT (R8)
SELECT s.id_fila, b.nit_de_la_entidad AS nit_bronce, s.nit_entidad AS nit_plata
FROM silver.contratos s
JOIN bronze.secop_raw b USING (id_fila)
WHERE b.nit_de_la_entidad IS DISTINCT FROM s.nit_entidad
LIMIT 10;

-- 6.5 Valor repetido repartido (R7): el contrato que más se repetía en bronce
--     Antes se sumaba el valor completo en cada fila; ahora suma el valor real
SELECT id_contrato,
       count(*)                       AS filas_en_plata,
       count(DISTINCT documento_proveedor) AS proveedores,
       max(valor_contrato)            AS valor_contrato,
       sum(valor_contrato)            AS suma_sin_ajustar,
       sum(valor_ajustado)            AS suma_ajustada
FROM silver.contratos
WHERE id_contrato = '18-4-7947515'
GROUP BY id_contrato;


-- ---------------------------------------------------------------------
-- PRUEBA 7. CORRECCIÓN DE VALORES (R7b y R9b) · requiere 02c
--   Todas deben dar 0 → OK
-- ---------------------------------------------------------------------
WITH versiones AS (            -- contratos SECOP II con varias versiones
    SELECT id_contrato, coalesce(documento_proveedor, '') AS doc,
           count(*) FILTER (WHERE NOT flag_version_contrato) AS sin_marcar,
           sum(valor_ajustado) AS suma, min(valor_contrato) AS minimo, max(valor_contrato) AS maximo
    FROM silver.contratos
    WHERE origen = 'SECOPII' AND id_contrato IS NOT NULL AND valor_contrato > 0
    GROUP BY 1, 2
    HAVING count(*) > 1 AND count(DISTINCT valor_contrato) > 1
),
med AS (
    SELECT codigo_entidad, percentile_cont(0.5) WITHIN GROUP (ORDER BY valor_contrato) AS mediana
    FROM silver.contratos WHERE valor_contrato > 0
    GROUP BY codigo_entidad HAVING count(*) >= 30
)
SELECT p.regla, p.prueba, p.encontrados,
       CASE WHEN p.encontrados = 0 THEN 'OK' ELSE 'REVISAR' END AS estado
FROM (VALUES
    ('R7b', 'Contratos con versiones sin ajustar',
        (SELECT count(*) FROM versiones WHERE sin_marcar > 0)),
    ('R7b', 'Contratos cuya suma no queda entre su mínimo y su máximo',
        (SELECT count(*) FROM versiones WHERE suma NOT BETWEEN minimo - 1 AND maximo + 1)),
    ('R9b', 'Valores extremos sin marcar como atípicos',
        (SELECT count(*) FROM silver.contratos s JOIN med m USING (codigo_entidad)
          WHERE NOT s.flag_valor_atipico AND s.valor_contrato > 1e12
            AND s.valor_contrato > 100000 * m.mediana)),
    ('R9b', 'Extremos marcados pero no excluidos (sin flag_valor_atipico)',
        (SELECT count(*) FROM silver.contratos WHERE flag_valor_extremo AND NOT flag_valor_atipico))
) AS p(regla, prueba, encontrados);


-- ---------------------------------------------------------------------
-- PRUEBA 8. ¿LAS VERSIONES SON DE VERDAD EL MISMO CONTRATO? (R7b)
--   Para cada contrato SECOP II con varias versiones, revisa si sus filas
--   tienen distinto proceso, distinta fecha de firma o distinta entidad.
--   Esperado: "grupos" ≈ 554.063 y las otras 3 columnas en 0 o casi 0.
--   Si alguna sale alta, la regla R7b debe exigir también mismo proceso y fecha.
-- ---------------------------------------------------------------------
SELECT count(*) AS grupos,
       count(*) FILTER (WHERE procesos  > 1) AS con_distinto_proceso,
       count(*) FILTER (WHERE fechas    > 1) AS con_distinta_fecha_firma,
       count(*) FILTER (WHERE entidades > 1) AS con_distinta_entidad
FROM (
    SELECT id_contrato, coalesce(documento_proveedor, '') AS doc,
           count(DISTINCT id_proceso)     AS procesos,
           count(DISTINCT fecha_firma)    AS fechas,
           count(DISTINCT codigo_entidad) AS entidades
    FROM silver.contratos
    WHERE origen = 'SECOPII' AND id_contrato IS NOT NULL AND valor_contrato > 0
    GROUP BY 1, 2
    HAVING count(*) > 1 AND count(DISTINCT valor_contrato) > 1
) g;


-- ---------------------------------------------------------------------
-- PRUEBA 9. TOTALES POR AÑO Y LOS 10 VALORES MÁS ALTOS DE UN AÑO
--   9.1 Totales en billones de pesos. Comparar billones_sin_atipicos con
--       las cifras oficiales (≈ 100 billones en 2018; ≈ 111 en ene–oct 2023).
-- ---------------------------------------------------------------------
SELECT extract(year FROM fecha_firma) AS anio,
       count(*) AS contratos,
       round(sum(valor_ajustado) / 1e12, 2) AS billones_total,
       round(sum(valor_ajustado) FILTER (WHERE NOT flag_valor_atipico) / 1e12, 2) AS billones_sin_atipicos
FROM silver.contratos
GROUP BY 1 ORDER BY 1;

--   9.2 Los 10 valores más altos de un año (cambiar 2025 por el año a revisar).
--       Sirve para ver qué hay detrás de un total con atípicos muy alto.
SELECT id_fila, nombre_entidad, nombre_proveedor, valor_contrato,
       flag_valor_atipico, flag_valor_extremo
FROM silver.contratos
WHERE extract(year FROM fecha_firma) = 2025
ORDER BY valor_contrato DESC NULLS LAST
LIMIT 10;
