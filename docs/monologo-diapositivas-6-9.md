# Monólogo — Diapositivas 6 a 9 (SECOP · Data Warehouse Medallión)

Guion hablado para presentar las diapositivas 06/14 a 09/14.
Duración estimada: 3 a 4 minutos. Tono conversacional, en primera persona plural.

---

## Diapositiva 6 — Volumetría

Antes de hablar de la arquitectura, quiero que vean el tamaño del problema.

La fuente son 10 archivos CSV, uno por año, descargados de SECOP Integrado. En total son
**16.025.993 contratos** que ocupan **14,4 GB** en texto plano.

Miren la tabla: cada año aporta alrededor de un millón y medio de registros, con tamaños que van
de 1,2 a 2 gigabytes. El año con más contratos es 2025, con 2.123.615, y el menor es 2020, con
1.444.812 —justo el año de la pandemia—, algo que tiene sentido.

Ojo con 2026: tiene 1.291.923 registros, pero no es un año completo. Nuestra fecha de corte es el
**29 de septiembre de 2026**, así que ese archivo está incompleto y hay que decirlo cuando analicemos
tendencias, porque comparar 2026 contra años completos nos daría una caída falsa.

Por qué importa esto: 14,4 GB y 16 millones de filas no se analizan con un archivo plano ni con un
`GROUP BY` en una laptop. Este volumen es justamente lo que justifica una arquitectura analítica y
un Data Warehouse. Si fueran mil registros, no valdría la pena.

---

## Diapositiva 7 — Volumetría por capa (Medallión)

Ahora sí, la arquitectura. Trabajamos con el modelo Medallión, que son tres capas: bronce, plata y oro.

**Capa bronce.** Entramos los 10 archivos tal cual, sin transformar nada, todo queda en texto. Esta
tabla se llama `bronze.secop_raw` y tiene las 16 millones de filas. Es la base de todo el proceso y,
más importante, es nuestra copia de respaldo: si algo sale mal más adelante, siempre podemos volver
a esta capa.

**Capa plata.** Aquí ya limpiamos y tipamos los datos: quitamos duplicados, convertimos fechas y
montos a tipos reales, normalizamos textos. El resultado es `silver.contratos`. No cambia el número
de contratos —siguen siendo 16 millones, solo que ahora están limpios y tipados. Eso es importante:
en plata no estamos resumiendo, estamos limpiando.

**Capa oro.** Acá sí ocurre la transformación analítica. Aparece el **modelo estrella**: una tabla
de hechos, `fact_contrato`, y **7 tablas de dimensiones**, cada una con su llave sustituta. Esta es
la capa que se conecta con Power BI y con las consultas del tablero.

Y hay una propiedad que nos da tranquilidad: **cada fila se puede rastrear hasta su archivo de
origen**. Si un número no nos cuadra, podemos preguntar de qué archivo salió y en qué año. Eso es
trazabilidad de punta a punta.

---

## Diapositiva 8 — De dónde salen los datos

Ahora veamos qué columnas tenemos realmente disponibles. La fuente oficial es el dataset
`rpmr-utcd` de SECOP Integrado, y la organizamos en cuatro grupos.

**Entidad**, que es quién contrata: nivel de la entidad, el código de entidad en SECOP, el nombre, el
NIT, el departamento y el municipio. Con esto respondemos RQ01, RQ03 y RQ05.

**Contrato**, que es el contrato firmado con el máximo detalle posible: ID del contrato, ID del
proceso, estado del proceso, modalidad de contratación, tipo de contrato, valor del contrato, origen
y la URL.

**Proveedor**, que es a quién se le contrata: tipo de documento, número de documento y la razón
social del contratista. Con esto responde RQ04.

**Fechas**, que es cuándo: fecha de firma, fecha de inicio de ejecución y fecha de fin de ejecución.
Con esto responde RQ02 y RQ06.

El quinto bloque es el **texto libre**: el objeto del contrato y el objeto del proceso. Es valuable,
pero no entra al modelo porque no es analizable numéricamente. Preferimos dejarlo como atributo
descriptivo.

Y quiero ser honesto con lo que **no** tenemos, porque esto tiene consecuencias directas en el
análisis. La fuente no trae: valor pagado o ejecutado, adiciones y prórrogas, número de
oferentes, presupuesto oficial, lugar de ejecución ni ubicación del proveedor. Por eso, cuando
hablamos de "valor contratado", estamos hablando del **valor firmado en el contrato**, no del valor
realmente pagado. Es una distinción importante y la vamos a aclarar en la presentación.

---

## Diapositiva 9 — Granularidad

Esta diapositiva parece sencilla pero es la más importante del modelo, porque define qué
significa una fila.

**Una fila de la tabla de hechos es un contrato firmado con un proveedor.**

La llave es `id_contrato` más `documento_proveedor`, y ya viene depurada en la capa plata. Es decir,
si el mismo contrato aparece repetido en el archivo, nosotros lo contamos una sola vez.

¿Por qué importa tanto? Porque este es **el nivel más detallado que entrega la fuente**. Si
agregramos desde el principio por entidad o por mes, el proveedor y la modalidad se mezclan en un
número, y esa información se pierde para siempre.

Y eso nos costaría caro, porque hay tres requerimientos que dependen de ese detalle:

- **RQ03**, el porcentaje de contratación directa, necesita saber la modalidad de cada contrato
  individual.
- **RQ04**, los principales proveedores, necesita poder identificar al proveedor contrato por
  contrato, y ver en cuántas entidades aparece.
- **RQ06**, la duración por tipo, necesita la modalidad y el tipo de contrato por separado para
  compararlos.

Entonces la decisión es: subir el detalle al máximo en la tabla de hechos, y dejar que sea el
momento de la consulta donde agrupemos. Así no perdemos nada y respondemos lo que nos piden.

Con esto ya tenemos claro el volumen, la arquitectura y la granularidad. En las siguientes
diapositivas mostramos el modelo estrella y sus siete dimensiones.

---

## Notas de transición

- **6 → 7:** "Ya vimos el volumen. Ahora veamos cómo lo procesamos."
- **7 → 8:** "Ya sabemos cómo lo guardamos. Veamos qué datos tenemos."
- **8 → 9:** "Estas columnas, ¿cómo las combinamos? Eso es la granularidad."
- **9 → 10:** "Con esto definido, les muestro el modelo estrella."

## Tips de uso

- Se recomienda hacer pausa después de las cifras grandes (16.025.993, 14,4 GB) para que el público
  las procese.
- En la diapositiva 8, slowing down en la lista de "no disponible": es el punto donde un jurado suele
  preguntar, así que adelántalo y cierra con la aclaración de "valor firmado ≠ valor pagado".
- En la diapositiva 9, enfatizar la frase "es el nivel más detallado de la fuente": justifica toda la
  decisión de diseño.
- Duración total aproximada de exposición: **3 min 20 s** a ritmo normal.
