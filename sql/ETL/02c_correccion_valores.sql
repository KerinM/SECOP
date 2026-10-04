-- =====================================================================
-- 02c_correccion_valores.sql  ·  CORRECCIÓN DE VALORES DE LA CAPA PLATA
-- Responsable: Jose (Ingeniero ETL)
-- Requiere: silver.contratos (02_silver_limpieza.sql)
-- =====================================================================
-- Hallazgo: al comparar los totales por año con las cifras de Colombia
-- Compra Eficiente, 2018 sumaba ≈ 692 billones frente a ≈ 100 oficiales.
-- Causas encontradas:
--   R7b. En SECOP II un mismo contrato aparece varias veces (estado
--        MODIFICADO), una fila por cada modificación, con valores
--        distintos. Se sumaba varias veces.
--   R9b. Valores imposibles para su entidad (ej. una alcaldía con un
--        contrato de 25 billones) que R9 no marcaba, porque R9 compara
--        solo contra contratos del mismo tipo.
-- Nada se borra: se ajusta valor_ajustado y se marcan las filas.
--
-- En pgAdmin: correr cada PASO por separado (seleccionar + F5).
-- Si se vuelve a correr, los UPDATE dan 0 (no se aplica dos veces).
-- =====================================================================


-- ---------------------------------------------------------------------
-- PASO 1. Columnas nuevas para marcar las filas (instantáneo)
-- ---------------------------------------------------------------------
ALTER TABLE silver.contratos ADD COLUMN IF NOT EXISTS flag_version_contrato BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE silver.contratos ADD COLUMN IF NOT EXISTS flag_valor_extremo    BOOLEAN NOT NULL DEFAULT false;


-- ---------------------------------------------------------------------
-- PASO 2. R7b · VERSIONES DE UN MISMO CONTRATO EN SECOP II
--   En SECOP II el id del contrato (CO1.PCCNTR...) es único. Si el mismo
--   contrato y el mismo proveedor aparecen en varias filas con valores
--   distintos, son versiones (modificaciones) del mismo contrato.
--   El dataset no trae la fecha de cada modificación, así que no se sabe
--   cuál es la vigente: el contrato se cuenta UNA vez con el valor
--   PROMEDIO de sus versiones (cada fila vale valor_contrato / n, y las
--   n filas juntas suman el promedio).
--   Se parte de valor_contrato (no de valor_ajustado) para no dividir dos
--   veces filas que R7 ya había repartido.
--
--   2a. Conteo previo (no cambia nada). Anotar el número.
-- ---------------------------------------------------------------------
WITH g AS (
    SELECT id_contrato, coalesce(documento_proveedor, '') AS doc, count(*) AS n
    FROM silver.contratos
    WHERE origen = 'SECOPII' AND id_contrato IS NOT NULL
      AND valor_contrato > 0 AND NOT flag_version_contrato
    GROUP BY id_contrato, coalesce(documento_proveedor, '')
    HAVING count(*) > 1 AND count(DISTINCT valor_contrato) > 1
)
SELECT count(*) AS contratos_con_versiones, sum(n) AS filas_a_ajustar FROM g;

-- ---------------------------------------------------------------------
--   2b. Ajuste. El UPDATE debe dar el mismo número que filas_a_ajustar.
-- ---------------------------------------------------------------------
WITH g AS (
    SELECT id_contrato, coalesce(documento_proveedor, '') AS doc, count(*) AS n
    FROM silver.contratos
    WHERE origen = 'SECOPII' AND id_contrato IS NOT NULL
      AND valor_contrato > 0 AND NOT flag_version_contrato
    GROUP BY id_contrato, coalesce(documento_proveedor, '')
    HAVING count(*) > 1 AND count(DISTINCT valor_contrato) > 1
)
UPDATE silver.contratos s
SET valor_ajustado        = round(s.valor_contrato / g.n, 2),
    flag_version_contrato = true
FROM g
WHERE s.origen = 'SECOPII'
  AND s.id_contrato = g.id_contrato
  AND coalesce(s.documento_proveedor, '') = g.doc
  AND s.valor_contrato > 0
  AND NOT s.flag_version_contrato;


-- ---------------------------------------------------------------------
-- PASO 3. R9b · VISTA PREVIA de valores imposibles (no cambia nada)
--   Contrato de más de 1 billón de pesos que además vale más de 100.000
--   veces la mediana de su entidad (solo entidades con 30+ contratos).
--   Revisar la lista antes del paso 4.
-- ---------------------------------------------------------------------
WITH med AS (
    SELECT codigo_entidad,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY valor_contrato) AS mediana
    FROM silver.contratos
    WHERE valor_contrato > 0
    GROUP BY codigo_entidad
    HAVING count(*) >= 30
)
SELECT s.id_fila, s.nombre_entidad, s.nombre_proveedor, s.tipo_contrato,
       s.valor_contrato, round(s.valor_contrato / m.mediana) AS veces_la_mediana
FROM silver.contratos s
JOIN med m USING (codigo_entidad)
WHERE NOT s.flag_valor_atipico
  AND s.valor_contrato > 1e12
  AND s.valor_contrato > 100000 * m.mediana
ORDER BY s.valor_contrato DESC;


-- ---------------------------------------------------------------------
-- PASO 4. R9b · MARCAR los valores imposibles
--   Se marcan como atípicos (flag_valor_atipico) para que oro y Power BI
--   los excluyan de los totales, y con flag_valor_extremo para saber la
--   causa. El UPDATE debe dar el mismo número de filas que el paso 3.
-- ---------------------------------------------------------------------
WITH med AS (
    SELECT codigo_entidad,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY valor_contrato) AS mediana
    FROM silver.contratos
    WHERE valor_contrato > 0
    GROUP BY codigo_entidad
    HAVING count(*) >= 30
)
UPDATE silver.contratos s
SET flag_valor_extremo = true,
    flag_valor_atipico = true
FROM med m
WHERE s.codigo_entidad = m.codigo_entidad
  AND NOT s.flag_valor_atipico
  AND s.valor_contrato > 1e12
  AND s.valor_contrato > 100000 * m.mediana;


-- ---------------------------------------------------------------------
-- PASO 5. Verificación: totales por año (billones de pesos)
--   Comparar billones_sin_atipicos con las cifras oficiales
--   (≈ 100 billones/año en 2018; ≈ 111 billones en ene–oct 2023).
-- ---------------------------------------------------------------------
SELECT extract(year FROM fecha_firma) AS anio,
       count(*) AS contratos,
       round(sum(valor_ajustado) / 1e12, 2) AS billones_total,
       round(sum(valor_ajustado) FILTER (WHERE NOT flag_valor_atipico) / 1e12, 2) AS billones_sin_atipicos
FROM silver.contratos
GROUP BY 1 ORDER BY 1;
