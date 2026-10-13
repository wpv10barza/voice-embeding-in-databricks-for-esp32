# Exportador MP4 URP — streaming 2020–2025

**Alcance:** inventariar recursivamente el Drive universitario y seleccionar únicamente `*.mp4` cuyos nombres contengan una fecha calendaria válida 2020-01-01 a 2025-12-31. Los clips se ordenan por fecha, nombre y ruta. Para cada mes: un solo MP4 final y un archivo `ene-2020.7z` ... `dic-2025.7z` que contiene ese MP4. Los originales no se eliminan.

**Streaming:** rclone usa el remoto `urp:` y expone un servidor HTTP solo en `127.0.0.1` dentro del runner. FFmpeg lee los MP4 originales mediante HTTP Range, sin descargarlos completos al Windows del usuario. Se crean segmentos temporales y 7z en el runner de Actions, consumiendo tiempo, disco y cuota cloud; no existe compresión de MP4 dentro de Drive sin procesamiento externo.

**Ruta de código:** `tools/drive-exportador/`. **Workflow:** `.github/workflows/drive-mp4-exportador.yml`. Los archivos universitarios NO se publican en GitHub. **Este repositorio existente es público** y por ello el workflow bloquea por diseño cualquier inventario/ejecución real de Drive. El push de rama solo comprueba fechas e inventario con datos sintéticos; no usa secretos. Para procesar Drive real se requiere publicar esta carpeta/workflow en un repositorio **privado** y agregar `RCLONE_CONFIG_B64` del remoto `urp:` conectado a `201920425@urp.edu.pe` en GitHub Actions secrets. No poner credenciales en commits, comentarios ni logs.

### Ejecutar pruebas sin Drive

```bash
cd tools/drive-exportador
python3 -m unittest discover -s tests -v
python3 exportador_cloud.py --mes inventario --dry-run --fixture-json tests/fixture_lsjson.json --min-videos 3 --logs logs_prueba
```

### Descargar código del Git push desde Windows (sin MP4)

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\drive-exportador\scripts\02_BAJAR_GIT_CON_LOG.ps1
```

Script con `git clone` / `git pull --ff-only`, checkout limitado (sparse), salida del commit y log en `%LOCALAPPDATA%\ExportadorMP4\Logs\git_pull_*.log`. Descarga únicamente el **código**, no los videos ni los archivos comprimidos.

### Ejecución cloud real (solo repositorio privado)

1. Configurar rclone con cuenta URP, remote llamado `urp` y verificar `rclone lsd urp:`.
2. Codificar la configuración rclone local en Base64 y guardarla en el secreto `RCLONE_CONFIG_B64`; nunca ponerla en repositorio.
3. GitHub Actions → workflow → Run workflow: `mes=inventario` con simulación para obtener `inventario_fechados.csv`, `sin_fecha.csv`, `resumen_meses.csv`, `proceso.log` y `estado.txt`.
4. Revisar mes y tamaño; ejecutar por ejemplo `mes=2024-05`, `simulacion=false`, `max_gb=6`. Repetir por cada mes validado. Carpetas de salida `urp:Videos_Unidos_2020_2025_7z/`; logs en subcarpeta `logs/` y artefactos de Actions.
5. `BLOQUEADO_LIMITE_GB` significa que hay que usar un runner con mayor capacidad o modificar prudentemente la política. Archivos de 1 GB o más no se bajan al PC; sí se procesan en servidor temporal con limitaciones de espacio.

**Precaución:** El estado `EXISTE_NO_SOBRESCRITO` conserva el archivo 7z previo. No se asume cobertura completa de un mes sin contrastar inventario; no se borran los originales.