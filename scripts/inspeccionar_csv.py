"""Revisa encabezado, numero de columnas y formato de fechas de los CSV SECOP."""
import csv
import sys
from pathlib import Path

COLUMNAS_ESPERADAS = 22
POSICIONES_FECHA = {11: "firma", 12: "inicio", 13: "fin"}  # base 0, orden de staging.contratos_raw

csv.field_size_limit(2**31 - 1)


def inspeccionar(archivo: Path, mostrar_encabezado: bool) -> None:
    with archivo.open("r", encoding="utf-8-sig", newline="") as flujo:
        lector = csv.reader(flujo)
        encabezado = next(lector)
        primera = next(lector)

    estado = "OK" if len(encabezado) == COLUMNAS_ESPERADAS else "REVISAR"
    print(f"{archivo.name}: {len(encabezado)} columnas [{estado}]")

    if mostrar_encabezado:
        for posicion, nombre in enumerate(encabezado):
            print(f"   {posicion:2d}  {nombre}")
        for posicion, etiqueta in POSICIONES_FECHA.items():
            print(f"   fecha {etiqueta}: {primera[posicion]!r}")


def main() -> int:
    if len(sys.argv) != 2:
        print("Uso: python inspeccionar_csv.py <carpeta con los CSV>")
        return 1
    archivos = sorted(Path(sys.argv[1]).glob("secop_*.csv"))
    if not archivos:
        print("No hay secop_*.csv en esa carpeta")
        return 1
    for indice, archivo in enumerate(archivos):
        inspeccionar(archivo, mostrar_encabezado=(indice == 0))
    return 0


if __name__ == "__main__":
    sys.exit(main())