#!/usr/bin/env python3

import os
import shutil
from pathlib import Path

# Origen: scripts .sh ubicados directamente en el home
SOURCE_DIR = Path(os.environ.get("SOURCE_DIR", Path.home()))

# Destino: carpeta documentos dentro de este repositorio
DEST_DIR = Path(os.environ.get("DEST_DIR", Path(__file__).resolve().parent / "documentos"))


def cargar_documentos():
    DEST_DIR.mkdir(parents=True, exist_ok=True)

    # Solo los .sh del nivel superior del home
    archivos = sorted(
        archivo for archivo in SOURCE_DIR.glob("*.sh") if archivo.is_file()
    )

    if not archivos:
        print(f"No se encontraron documentos .sh en {SOURCE_DIR}")
        return 1

    # Copiar primero (sobrescribe la version anterior si existe)
    actuales = set()
    for origen in archivos:
        actuales.add(origen.name)
        shutil.copy2(origen, DEST_DIR / origen.name)
        print(f"Copiado: {origen.name}")

    # Eliminar versiones anteriores que ya no existen en el origen
    for destino in DEST_DIR.glob("*.sh"):
        if destino.is_file() and destino.name not in actuales:
            destino.unlink()
            print(f"Eliminado anterior: {destino.name}")

    print(f"Documentos actualizados en: {DEST_DIR}")
    return 0


if __name__ == "__main__":
    raise SystemExit(cargar_documentos())
