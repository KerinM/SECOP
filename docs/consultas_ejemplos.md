# Consultas de ejemplo

**Responsable:** Kerin · **Base:** `secop_dw` · **Rol de conexión:** `secop_lectura` (solo `gold`)
**Requerimientos:** RQ01-RQ14, RF-07 a RF-13

Todas las consultas leen **solo** de `gold.v_*`, `gold.mv_*` y `gold.fact_contrato`. Todo dinero usa `valor_ajustado` o `valor_gastado`, nunca `valor_contrato`, y las vistas ya excluyen atípicos y fechas inválidas.

**Cómo leer las cifras.** Los valores en billones son de pesos colombianos. 2026 es un año **parcial** (corte 29/09/2026). La columna *Tiempo* se mide con `\timing` (ver sección 3); la meta de RNF-02 es < 5 s.

---

## 1. Consultas por requerimiento

| # | RQ | Qué responde | Fuente | Tiempo |
|---|---|---|---|---|
| 1 | RQ01 | Valor y número de contratos por entidad y año | `mv_entidad_resumen` | por medir |
| 2 | RQ02 | Evolución anual con variación interanual | `v_evolucion_anual` | por medir |
| 3 | RQ03 | % de contratación no competitiva por entidad | `v_no_competitiva_entidad` | por medir |
| 4 | RQ03 | Desglose por modalidad | `v_no_competitiva_modalidad` | por medir |
| 5 | RQ04 | Top 20 de proveedores, HHI y entidades distintas | `v_top20_proveedores` | por medir |
| 6 | RQ05 | Departamentos con mayor valor | `v_geografia_departamento` | por medir |
| 7 | RQ05 | Municipios con mayor valor | `mv_geografia` | por medir |
| 8 | RQ06 | Duración por tipo y modalidad | `mv_duracion` | por medir |
| 9 | RQ07 | Nacional frente a territorial | `v_nivel_entidad` | por medir |
| 10 | RQ08 | Valor total y promedio por tipo | `v_tipo_contrato` | por medir |
| 11 | RQ09 | Estacionalidad mensual | `v_estacionalidad` | por medir |
| 12 | RQ10 | Personas naturales y jurídicas | `v_perfil_tipo_persona` | por medir |
| 13 | RQ11 | SECOP II frente a SECOP I | `v_participacion_origen` | por medir |
| 14 | RQ12 | Entidades con más atípicos | `v_atipicos_entidad` | por medir |
| 15 | RQ13 | Estado de los contratos | `v_estado_contrato` | por medir |
| 16 | RQ14 | Valor gastado por entidad y año | `mv_entidad_resumen` | por medir |
| 17 | RQ14 | Valor gastado por tipo y año | `mv_resumen_contratos` | por medir |
| 18 | RF-08 | Posible fraccionamiento (mínima cuantía, 30 días) | `fact_contrato` | por medir |
| 19 | RF-15 | KPIs globales | `mv_kpis_globales` | por medir |
| 20 | RF-19 | Reporte de calidad | `mv_calidad_datos` | por medir |

---

### 1. RQ01 · Valor y número de contratos por entidad y año

```sql
SELECT e.nombre_entidad, e.nivel_entidad,
       sum(r.versiones_validas)                AS versiones,
       round(sum(r.valor_ajustado) / 1e9, 1)   AS miles_de_millones
FROM gold.mv_entidad_resumen r
JOIN gold.dim_entidad e ON e.sk_entidad = r.sk_entidad
WHERE r.anio = 2025 AND r.sk_entidad <> -1
GROUP BY e.nombre_entidad, e.nivel_entidad
ORDER BY sum(r.valor_ajustado) DESC NULLS LAST
LIMIT 20;
```

El top 20 con porcentaje acumulado está en `gold.v_top20_entidades`.

### 2. RQ02 · Evolución anual 2017-2026

```sql
SELECT anio, versiones,
       round(valor_ajustado / 1e12, 2) AS billones,
       var_versiones_pct, var_valor_pct, es_anio_parcial
FROM gold.v_evolucion_anual
ORDER BY anio;
```

Medido: 2018 = 102,54 billones (oficial ≈ 100). La variación de 2026 compara un año incompleto.

### 3. RQ03 · Porcentaje de contratación no competitiva por entidad

```sql
SELECT nombre_entidad, nivel_entidad, versiones_validas,
       versiones_no_competitivas, pct_no_competitiva
FROM gold.v_no_competitiva_entidad
WHERE anio = 2025 AND versiones_validas >= 100
ORDER BY pct_no_competitiva DESC, versiones_validas DESC
LIMIT 20;
```

El filtro `versiones_validas >= 100` evita porcentajes ruidosos de entidades con pocas versiones. Como ≈ 89,7 % de las filas son no competitivas, el ranking se satura cerca del 100 %: leer junto con la consulta 4.

### 4. RQ03 · Desglose por modalidad de una entidad

```sql
SELECT modalidad, es_competitiva, versiones_validas, pct_de_la_entidad
FROM gold.v_no_competitiva_modalidad
WHERE anio = 2025 AND nombre_entidad LIKE '%VALLEDUPAR%'
ORDER BY versiones_validas DESC
LIMIT 15;
```

Separa contratación directa de régimen especial, que el indicador agregado esconde.

### 5. RQ04 · Concentración de proveedores

```sql
SELECT posicion, nombre_proveedor, tipo_persona, entidades_distintas,
       round(valor_ajustado / 1e12, 3) AS billones,
       pct_del_total, pct_acumulado, hhi_global
FROM gold.v_top20_proveedores
ORDER BY posicion;
```

Medido: el top lo abre el Consorcio Renting Blindados (10,219 billones, 0,887 %); HHI global 79,45 de 10.000, es decir, mercado poco concentrado.

### 6. RQ05 · Departamentos con mayor valor

```sql
SELECT departamento, versiones,
       round(valor_ajustado / 1e12, 2) AS billones,
       pct_valor_anio
FROM gold.v_geografia_departamento
WHERE anio = 2025
ORDER BY valor_ajustado DESC
LIMIT 10;
```

### 7. RQ05 · Municipios con mayor valor

```sql
SELECT departamento, municipio, sum(versiones) AS versiones,
       round(sum(valor_ajustado) / 1e12, 3) AS billones
FROM gold.mv_geografia
WHERE anio = 2025 AND municipio <> 'NO REGISTRA'
GROUP BY departamento, municipio
ORDER BY sum(valor_ajustado) DESC
LIMIT 15;
```

La ubicación es la de la entidad contratante, no la del lugar de ejecución.

### 8. RQ06 · Duración por tipo y modalidad

```sql
SELECT tipo_contrato, modalidad, versiones,
       promedio_dias, mediana_dias, p25_dias, p75_dias, p95_dias
FROM gold.mv_duracion
ORDER BY versiones DESC
LIMIT 15;
```

Excluye duraciones negativas, fechas incoherentes e inválidas.

### 9. RQ07 · Nacional frente a territorial

```sql
SELECT anio, nivel_entidad, versiones,
       round(valor_ajustado / 1e12, 2) AS billones, pct_valor_anio
FROM gold.v_nivel_entidad
ORDER BY anio, valor_ajustado DESC;
```

### 10. RQ08 · Valor total y promedio por tipo de contrato

```sql
SELECT tipo_contrato, versiones,
       round(valor_ajustado / 1e12, 2) AS billones,
       valor_promedio_por_version
FROM gold.v_tipo_contrato
WHERE anio = 2025
ORDER BY valor_ajustado DESC NULLS LAST;
```

### 11. RQ09 · Estacionalidad

```sql
SELECT mes, round(avg(versiones)) AS versiones_promedio,
       round(avg(valor_ajustado) / 1e12, 2) AS billones_promedio
FROM gold.v_estacionalidad
WHERE anio BETWEEN 2017 AND 2025          -- años completos
GROUP BY mes
ORDER BY mes;
```

Se excluye 2026 para no sesgar los meses finales.

### 12. RQ10 · Personas naturales y jurídicas

```sql
SELECT anio, tipo_persona, versiones,
       round(valor_ajustado / 1e12, 2) AS billones, pct_valor_anio
FROM gold.v_perfil_tipo_persona
ORDER BY anio, tipo_persona;
```

La clasificación es **por documento y con prioridad JURIDICA**; debe decirse al presentar el resultado.

### 13. RQ11 · SECOP II frente a SECOP I

```sql
SELECT anio, origen, versiones, pct_versiones_anio, pct_valor_anio
FROM gold.v_participacion_origen
ORDER BY anio, origen;
```

### 14. RQ12 · Entidades con más contratos atípicos

```sql
SELECT posicion, nombre_entidad, versiones_total, versiones_atipicas,
       pct_atipicas, round(valor_atipico / 1e12, 2) AS billones_atipicos
FROM gold.v_atipicos_entidad
ORDER BY posicion
LIMIT 20;
```

### 15. RQ13 · Estado de los contratos

```sql
SELECT agrupacion_estado, rango_estado, origen, sum(versiones) AS versiones,
       round(sum(valor_ajustado) / 1e12, 2) AS billones
FROM gold.v_estado_contrato
WHERE anio = 2025
GROUP BY agrupacion_estado, rango_estado, origen
ORDER BY rango_estado, origen;
```

«ANULADO» no existe en la fuente; las cancelaciones son 84 filas (0,0006 %).

### 16. RQ14 · Valor gastado por entidad y año

```sql
SELECT r.anio, e.nombre_entidad,
       round(sum(r.valor_gastado) / 1e9, 1) AS gastado_miles_de_millones
FROM gold.mv_entidad_resumen r
JOIN gold.dim_entidad e ON e.sk_entidad = r.sk_entidad
WHERE r.anio = 2025 AND r.sk_entidad <> -1
GROUP BY r.anio, e.nombre_entidad
ORDER BY sum(r.valor_gastado) DESC NULLS LAST
LIMIT 20;
```

**«Gastado» es el valor contratado vigente, no el pagado.**

### 17. RQ14 · Valor gastado por tipo y año

```sql
SELECT anio, tipo_contrato,
       round(sum(valor_gastado) / 1e12, 2) AS billones_gastado
FROM gold.mv_resumen_contratos
GROUP BY anio, tipo_contrato
ORDER BY anio, sum(valor_gastado) DESC NULLS LAST;
```

### 18. RF-08 · Posible fraccionamiento: mínima cuantía al mismo proveedor en 30 días

```sql
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
```

Cuenta **versiones**, no contratos distintos. Es un indicio para revisar, no una prueba de fraccionamiento. Filtra por `sk_fecha_firma` para que PostgreSQL lea una sola partición.

### 19. RF-15 · KPIs globales

```sql
SELECT total_versiones, versiones_validas, contratos_distintos,
       contratos_con_versiones, entidades, proveedores,
       departamentos, municipios,
       round(valor_contratado / 1e12, 1) AS billones_contratado,
       round(valor_gastado    / 1e12, 1) AS billones_gastado
FROM gold.mv_kpis_globales;
```

### 20. RF-19 · Reporte de calidad

```sql
SELECT orden, clase, indicador, regla, filas, porcentaje
FROM gold.mv_calidad_datos
ORDER BY orden;
```

---

## 2. Trazabilidad hasta el CSV (RNF-06)

Requiere un rol con acceso a `silver` y `bronze` (`secop_etl` o `postgres`; `secop_lectura` no lo tiene a propósito):

```sql
SELECT f.id_fila, b.archivo_origen, f.valor_ajustado, s.valor_contrato
FROM gold.fact_contrato f
JOIN silver.contratos s USING (id_fila)
JOIN bronze.secop_raw b USING (id_fila)
WHERE f.sk_fecha_firma BETWEEN 20180101 AND 20181231
LIMIT 10;
```

## 3. Cómo medir el tiempo de cada consulta

```powershell
$psql = "C:\Program Files\PostgreSQL\18\bin\psql.exe"
$env:PGCLIENTENCODING = "UTF8"
$env:PGPASSWORD = Read-Host "Clave de secop_lectura"
# consultas.sql lleva \timing on al inicio y las 20 consultas
& $psql -U secop_lectura -h localhost -d secop_dw -w -f consultas.sql 2>&1 | Tee-Object logs\tiempos_consultas.txt
```

Anotar en la columna *Tiempo* el `Duración:` de cada una. Si alguna pasa de 5 s, medirla con `EXPLAIN (ANALYZE, BUFFERS)`.

## 4. Reglas que cumplen todas

1. Dinero: `valor_ajustado` o `valor_gastado`, nunca `valor_contrato`.
2. Filtro único `NOT es_atipico AND NOT es_fecha_invalida AND sk_fecha_firma <> -1`, ya aplicado en las vistas.
3. Las consultas por entidad o proveedor excluyen el miembro `-1`.
4. 2026 es parcial (corte 29/09/2026).
5. Los `top N` sobre medidas que pueden ser NULL llevan `NULLS LAST`.