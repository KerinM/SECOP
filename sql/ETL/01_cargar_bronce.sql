-- =====================================================================
--  01_cargar_bronce.sql  ·  CAPA BRONCE (carga de los 10 CSV)
--  Responsable: Jose (Ingeniero ETL)
--  Bodega de datos SECOP Integrado · Arquitectura Medallón en PostgreSQL
--  Bases de Datos Avanzadas · Universidad Popular del Cesar · 2026
--  Fuente: datos.gov.co, SECOP Integrado (rpmr-utcd), descarga 29/09/2026
-- =====================================================================
--  Cómo se corre (psql, abierto en la carpeta donde están los 10 CSV):
--    1) CREATE DATABASE secop_dw;
--    2) \c secop_dw
--    3) \i 01_cargar_bronce.sql
--  Después correr 01b_trazabilidad_bronce.sql (marca el archivo de origen
--  de cada fila y llena la bitácora con una fila por CSV).
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. ESQUEMAS (una capa = un esquema) Y EXTENSIONES
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS bronze;   -- dato crudo, tal cual llega
CREATE SCHEMA IF NOT EXISTS silver;   -- dato limpio, tipado y validado
CREATE SCHEMA IF NOT EXISTS gold;     -- modelo estrella para análisis
CREATE EXTENSION IF NOT EXISTS unaccent;


-- ---------------------------------------------------------------------
-- 1. CAPA BRONCE: copia fiel del CSV
--    Todo en TEXT para que ninguna fila se rechace por tipo de dato
--    ('NO DEFINIDO' en un NIT, fechas imposibles, etc.). Se valida en plata.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bronze.secop_raw (
    id_fila                      BIGSERIAL PRIMARY KEY,   -- trazabilidad fila a fila
    nivel_entidad                TEXT,
    codigo_entidad_en_secop      TEXT,
    nombre_de_la_entidad         TEXT,
    nit_de_la_entidad            TEXT,
    departamento_entidad         TEXT,
    municipio_entidad            TEXT,
    estado_del_proceso           TEXT,
    modalidad_de_contratacion    TEXT,
    objeto_a_contratar           TEXT,
    objeto_del_proceso           TEXT,
    tipo_de_contrato             TEXT,
    fecha_de_firma_del_contrato  TEXT,
    fecha_inicio_ejecucion       TEXT,
    fecha_fin_ejecucion          TEXT,
    numero_del_contrato          TEXT,
    numero_de_proceso            TEXT,
    valor_contrato               TEXT,
    nom_raz_social_contratista   TEXT,
    url_contrato                 TEXT,
    origen                       TEXT,
    tipo_documento_proveedor     TEXT,
    documento_proveedor          TEXT,
    fecha_carga                  TIMESTAMP NOT NULL DEFAULT now(),
    archivo_origen               TEXT      NOT NULL DEFAULT 'SECOP_Integrado_20260929.csv'
);

-- Carga masiva: un archivo por año (2017-2026).
-- \copy es un comando de psql: cada uno debe ir en UNA sola línea.
\echo 'Cargando secop_2017.csv ...'
\copy bronze.secop_raw (nivel_entidad, codigo_entidad_en_secop, nombre_de_la_entidad, nit_de_la_entidad, departamento_entidad, municipio_entidad, estado_del_proceso, modalidad_de_contratacion, objeto_a_contratar, objeto_del_proceso, tipo_de_contrato, fecha_de_firma_del_contrato, fecha_inicio_ejecucion, fecha_fin_ejecucion, numero_del_contrato, numero_de_proceso, valor_contrato, nom_raz_social_contratista, url_contrato, origen, tipo_documento_proveedor, documento_proveedor) FROM 'secop_2017.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\echo 'Cargando secop_2018.csv ...'
\copy bronze.secop_raw (nivel_entidad, codigo_entidad_en_secop, nombre_de_la_entidad, nit_de_la_entidad, departamento_entidad, municipio_entidad, estado_del_proceso, modalidad_de_contratacion, objeto_a_contratar, objeto_del_proceso, tipo_de_contrato, fecha_de_firma_del_contrato, fecha_inicio_ejecucion, fecha_fin_ejecucion, numero_del_contrato, numero_de_proceso, valor_contrato, nom_raz_social_contratista, url_contrato, origen, tipo_documento_proveedor, documento_proveedor) FROM 'secop_2018.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\echo 'Cargando secop_2019.csv ...'
\copy bronze.secop_raw (nivel_entidad, codigo_entidad_en_secop, nombre_de_la_entidad, nit_de_la_entidad, departamento_entidad, municipio_entidad, estado_del_proceso, modalidad_de_contratacion, objeto_a_contratar, objeto_del_proceso, tipo_de_contrato, fecha_de_firma_del_contrato, fecha_inicio_ejecucion, fecha_fin_ejecucion, numero_del_contrato, numero_de_proceso, valor_contrato, nom_raz_social_contratista, url_contrato, origen, tipo_documento_proveedor, documento_proveedor) FROM 'secop_2019.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\echo 'Cargando secop_2020.csv ...'
\copy bronze.secop_raw (nivel_entidad, codigo_entidad_en_secop, nombre_de_la_entidad, nit_de_la_entidad, departamento_entidad, municipio_entidad, estado_del_proceso, modalidad_de_contratacion, objeto_a_contratar, objeto_del_proceso, tipo_de_contrato, fecha_de_firma_del_contrato, fecha_inicio_ejecucion, fecha_fin_ejecucion, numero_del_contrato, numero_de_proceso, valor_contrato, nom_raz_social_contratista, url_contrato, origen, tipo_documento_proveedor, documento_proveedor) FROM 'secop_2020.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\echo 'Cargando secop_2021.csv ...'
\copy bronze.secop_raw (nivel_entidad, codigo_entidad_en_secop, nombre_de_la_entidad, nit_de_la_entidad, departamento_entidad, municipio_entidad, estado_del_proceso, modalidad_de_contratacion, objeto_a_contratar, objeto_del_proceso, tipo_de_contrato, fecha_de_firma_del_contrato, fecha_inicio_ejecucion, fecha_fin_ejecucion, numero_del_contrato, numero_de_proceso, valor_contrato, nom_raz_social_contratista, url_contrato, origen, tipo_documento_proveedor, documento_proveedor) FROM 'secop_2021.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\echo 'Cargando secop_2022.csv ...'
\copy bronze.secop_raw (nivel_entidad, codigo_entidad_en_secop, nombre_de_la_entidad, nit_de_la_entidad, departamento_entidad, municipio_entidad, estado_del_proceso, modalidad_de_contratacion, objeto_a_contratar, objeto_del_proceso, tipo_de_contrato, fecha_de_firma_del_contrato, fecha_inicio_ejecucion, fecha_fin_ejecucion, numero_del_contrato, numero_de_proceso, valor_contrato, nom_raz_social_contratista, url_contrato, origen, tipo_documento_proveedor, documento_proveedor) FROM 'secop_2022.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\echo 'Cargando secop_2023.csv ...'
\copy bronze.secop_raw (nivel_entidad, codigo_entidad_en_secop, nombre_de_la_entidad, nit_de_la_entidad, departamento_entidad, municipio_entidad, estado_del_proceso, modalidad_de_contratacion, objeto_a_contratar, objeto_del_proceso, tipo_de_contrato, fecha_de_firma_del_contrato, fecha_inicio_ejecucion, fecha_fin_ejecucion, numero_del_contrato, numero_de_proceso, valor_contrato, nom_raz_social_contratista, url_contrato, origen, tipo_documento_proveedor, documento_proveedor) FROM 'secop_2023.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\echo 'Cargando secop_2024.csv ...'
\copy bronze.secop_raw (nivel_entidad, codigo_entidad_en_secop, nombre_de_la_entidad, nit_de_la_entidad, departamento_entidad, municipio_entidad, estado_del_proceso, modalidad_de_contratacion, objeto_a_contratar, objeto_del_proceso, tipo_de_contrato, fecha_de_firma_del_contrato, fecha_inicio_ejecucion, fecha_fin_ejecucion, numero_del_contrato, numero_de_proceso, valor_contrato, nom_raz_social_contratista, url_contrato, origen, tipo_documento_proveedor, documento_proveedor) FROM 'secop_2024.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\echo 'Cargando secop_2025.csv ...'
\copy bronze.secop_raw (nivel_entidad, codigo_entidad_en_secop, nombre_de_la_entidad, nit_de_la_entidad, departamento_entidad, municipio_entidad, estado_del_proceso, modalidad_de_contratacion, objeto_a_contratar, objeto_del_proceso, tipo_de_contrato, fecha_de_firma_del_contrato, fecha_inicio_ejecucion, fecha_fin_ejecucion, numero_del_contrato, numero_de_proceso, valor_contrato, nom_raz_social_contratista, url_contrato, origen, tipo_documento_proveedor, documento_proveedor) FROM 'secop_2025.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\echo 'Cargando secop_2026.csv ...'
\copy bronze.secop_raw (nivel_entidad, codigo_entidad_en_secop, nombre_de_la_entidad, nit_de_la_entidad, departamento_entidad, municipio_entidad, estado_del_proceso, modalidad_de_contratacion, objeto_a_contratar, objeto_del_proceso, tipo_de_contrato, fecha_de_firma_del_contrato, fecha_inicio_ejecucion, fecha_fin_ejecucion, numero_del_contrato, numero_de_proceso, valor_contrato, nom_raz_social_contratista, url_contrato, origen, tipo_documento_proveedor, documento_proveedor) FROM 'secop_2026.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

-- Bitácora de cargas (01b_trazabilidad_bronce.sql la rehace con una fila por archivo)
CREATE TABLE IF NOT EXISTS bronze.log_cargas (
    id_carga        SERIAL PRIMARY KEY,
    archivo         TEXT,
    filas_portal    BIGINT,
    filas_cargadas  BIGINT,
    fecha_carga     TIMESTAMP DEFAULT now(),
    estado          TEXT GENERATED ALWAYS AS
                    (CASE WHEN filas_portal = filas_cargadas THEN 'OK' ELSE 'REVISAR' END) STORED
);
INSERT INTO bronze.log_cargas (archivo, filas_portal, filas_cargadas)
SELECT 'secop_2017.csv a secop_2026.csv', count(*), count(*) FROM bronze.secop_raw;


-- Total cargado (debe pasar de 10.000.000; en nuestra carga: 16.025.993)
SELECT count(*) AS filas_bronce FROM bronze.secop_raw;
