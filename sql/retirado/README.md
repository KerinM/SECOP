# Archivos retirados

Los tres archivos de esta carpeta pertenecen al **modelo anterior**, al que el proyecto
ya no le sirve. Se conservan solo por historico: `docs/decisiones_tecnicas.md` cita
varias veces el DDL viejo para explicar por que el modelo actual es como es.

> **No ejecutes nada de esta carpeta.** El pipeline vigente esta en `sql/ETL/`.

## Que era este modelo

| | Modelo retirado | Modelo vigente |
|---|---|---|
| Base de datos | `secop_integrado` | `secop_dw` |
| Entrada | `staging.contratos_raw` (22 columnas `text`, copia cruda) | `bronze.secop_raw` |
| Limpieza | `silver.contrato`, **sin deduplicar** | `silver.contratos`, deduplicada y tipada |
| Filas | 22.670.028 | 13.005.402 |
| Dinero | se sumaba `valor_contrato`, sin ajustar | `valor_ajustado`, excluyendo `flag_valor_atipico` |
| Origen de los datos | descarga paginada con `descargar_secop.py` (454 paginas de 50.000 filas) | `sql/ETL/01_cargar_bronce.sql` (`COPY` de 10 CSV) |
| Oro | `sql/retirado/01_esquema.sql` | `sql/02_modelo_gold.sql` |

## Por que se retiro

El problema no era el modelo, era **que la base estaba mal**.

El origen publica una ficha web con su propio conteo, y ese conteo no coincide con los
registros reales. Con el modelo viejo, sumar `valor_contrato` sin deduplicar ni separar
versiones produce **≈ 692 billones para 2018**, cuando el valor real es **≈ 100**. Es un
factor de ~6.900. Cualquier tablero construido sobre esa capa oro estaba contando
dinero que no existe.

El pipeline actual corrige las tres cosas:

1. **Cuenta con `count(*)` sobre la base, nunca con la ficha web.**
2. **Deduplica y separa por version** de contrato, dejando 13.005.402 filas.
3. **Usa `valor_ajustado`** y excluye `flag_valor_atipico = true`.

## Que hacer si necesitas reconstruir el modelo viejo

Nada. Para reconstruir el actual:

1. `sql/00_instalacion.sql` crea `secop_dw` y los esquemas.
2. `sql/ETL/README_ETL.md` documenta el orden de bronce y plata.
3. `sql/02_modelo_gold.sql` construye la capa oro desde `silver.contratos`.

## Archivos

| Archivo | Que era |
|---|---|
| `01_esquema.sql` | DDL del modelo retirado: staging + silver + oro particionado por ano |
| `descargar_secop.py` | Descarga paginada de la API (454 peticiones de 50.000 filas, 6 hilos) |
| `cargar_secop.py` | `COPY` a `staging.contratos_raw`, con retries y validacion de conteo |

`cargar_secop.py` verifica contra **22.670.028** filas, asi que hoy fallaria aunque se
lograra ejecutar: la base ya no tiene ese volumen.