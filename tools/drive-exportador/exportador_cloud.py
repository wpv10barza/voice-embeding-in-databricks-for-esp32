#!/usr/bin/env python3
"""Inventario/union mensual MP4 de Google Drive sin bajar originales al PC.

Se ejecuta en GitHub Actions. rclone serve http proporciona lecturas HTTP Range a
ffmpeg; los ficheros intermedios se almacenan solo en el runner temporal.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import logging
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path

MESES = ('ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic')
DATE_RE = re.compile(r'(?<!\d)(20(?:20|21|22|23|24|25))[-_. ]?(0[1-9]|1[0-2])[-_. ]?([0-3]\d)(?!\d)')
LOG = logging.getLogger('exportador')


def fecha_nombre(nombre: str) -> dt.date | None:
    for m in DATE_RE.finditer(Path(nombre).stem):
        try:
            return dt.datetime.strptime(''.join(m.groups()), '%Y%m%d').date()
        except ValueError:
            continue
    return None


def registrar_csv(path: Path, filas: list[dict], columnas: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('w', newline='', encoding='utf-8-sig') as f:
        w = csv.DictWriter(f, fieldnames=columnas, extrasaction='ignore')
        w.writeheader()
        w.writerows(filas)


def ejecutar(args: list[str], stdout=None, timeout=None) -> subprocess.CompletedProcess:
    LOG.info('Ejecutando: %s', ' '.join(args[:3]) if len(args) >= 3 else args[0])
    res = subprocess.run(args, stdout=stdout or subprocess.PIPE, stderr=subprocess.PIPE,
                         text=(stdout is None), timeout=timeout, check=False)
    if res.returncode:
        error = (res.stderr or '')
        if isinstance(error, bytes):
            error = error.decode('utf-8', 'replace')
        raise RuntimeError(f'{args[0]} salió con código {res.returncode}: {error[-2500:]}')
    return res


def listar_remoto(remote: str) -> list[dict]:
    # rclone pagina internamente cuando enumera carpetas de muchos archivos.
    cmd = ['rclone', 'lsjson', '--recursive', '--files-only', remote]
    LOG.info('Inventariando la unidad remota (puede tardar).')
    # Captura JSON de metadatos, NO binarios MP4.
    raw = ejecutar(cmd, timeout=3600).stdout
    datos = json.loads(raw)
    if not isinstance(datos, list):
        raise ValueError('rclone lsjson no devolvió una lista de archivos')
    return datos


def inventario(datos: list[dict], prefijo_destino: str) -> tuple[list[dict], list[dict]]:
    filas, ignorados = [], []
    destino = prefijo_destino.strip('/').casefold()
    for obj in datos:
        p = str(obj.get('Path', '')).replace('\\', '/').lstrip('/')
        if not p or not p.lower().endswith('.mp4'):
            continue
        if destino and (p.casefold() == destino or p.casefold().startswith(destino + '/')):
            continue
        base = Path(p).name
        fecha = fecha_nombre(base)
        fila = {'ruta': p, 'nombre': base, 'bytes': int(obj.get('Size') or 0),
                'fecha': fecha.isoformat() if fecha else '',
                'mes': fecha.strftime('%Y-%m') if fecha else '',
                'motivo': '' if fecha else 'SIN_FECHA_VALIDA_EN_NOMBRE'}
        (filas if fecha else ignorados).append(fila)
    filas.sort(key=lambda x: (x['fecha'], x['nombre'].casefold(), x['ruta']))
    ignorados.sort(key=lambda x: x['ruta'])
    return filas, ignorados


def escribir_reportes(logdir: Path, filas: list[dict], ignorados: list[dict]) -> list[dict]:
    columns = ['ruta', 'nombre', 'bytes', 'fecha', 'mes', 'motivo']
    registrar_csv(logdir / 'inventario_fechados.csv', filas, columns)
    registrar_csv(logdir / 'sin_fecha.csv', ignorados, columns)
    por_mes = defaultdict(list)
    for x in filas:
        por_mes[x['mes']].append(x)
    resumen = []
    for yr in range(2020, 2026):
        for mm in range(1, 13):
            clave = f'{yr}-{mm:02}'
            grupo = por_mes.get(clave, [])
            resumen.append({'mes': clave, 'videos': len(grupo),
                            'bytes': sum(v['bytes'] for v in grupo),
                            'estado': 'IDENTIFICADO' if grupo else 'NO_IDENTIFICADO'})
    registrar_csv(logdir / 'resumen_meses.csv', resumen, ['mes', 'videos', 'bytes', 'estado'])
    (logdir / 'resumen.json').write_text(json.dumps({
        'fechados': len(filas), 'sin_fecha': len(ignorados),
        'meses_con_video': sum(1 for x in resumen if x['videos']),
        'meses': resumen}, ensure_ascii=False, indent=2), encoding='utf-8')
    return resumen


def puerto_aleatorio() -> int:
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


class ServidorRclone:
    def __init__(self, remoto: str, carpeta_log: Path):
        self.remoto, self.carpeta_log = remoto, carpeta_log
        self.proceso = None
        self.archivo_log = None
        self.puerto = None

    def __enter__(self):
        self.puerto = puerto_aleatorio()
        self.archivo_log = (self.carpeta_log / 'rclone_http.log').open('w', encoding='utf-8')
        self.proceso = subprocess.Popen(
            ['rclone', 'serve', 'http', self.remoto, '--addr', f'127.0.0.1:{self.puerto}',
             '--read-only', '--disable-dir-list'],
            stdout=self.archivo_log, stderr=subprocess.STDOUT)
        # La página / puede devolver 403 con --disable-dir-list: servidor sigue operativo.
        for _ in range(40):
            if self.proceso.poll() is not None:
                raise RuntimeError('rclone serve http terminó prematuramente; revisar rclone_http.log')
            try:
                urllib.request.urlopen(f'http://127.0.0.1:{self.puerto}/', timeout=2).close()
                break
            except urllib.error.HTTPError as e:
                if e.code in (401, 403, 404):
                    break
            except (urllib.error.URLError, TimeoutError):
                time.sleep(.25)
        else:
            raise RuntimeError('No responde rclone HTTP en 127.0.0.1')
        return self

    def url(self, ruta: str) -> str:
        # HTTP Range permite ffmpeg leer cabeceras al final sin copia local del archivo.
        return f'http://127.0.0.1:{self.puerto}/{urllib.parse.quote(ruta, safe="/")}'

    def __exit__(self, *_):
        if self.proceso:
            self.proceso.terminate()
            try:
                self.proceso.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proceso.kill()
        if self.archivo_log:
            self.archivo_log.close()


def segmentos_ffmpeg(archivos: list[dict], servidor: ServidorRclone,
                      tmp: Path, logdir: Path, ancho: int, alto: int, crf: int) -> list[Path]:
    salidas = []
    detalle = []
    try:
        for i, f in enumerate(archivos, 1):
            origen_url = servidor.url(f['ruta'])
            LOG.info('Video %d/%d %s', i, len(archivos), f['ruta'])
            prob = ejecutar(['ffprobe', '-v', 'error', '-show_entries',
                             'stream=codec_type', '-of', 'json', origen_url], timeout=180)
            streams = json.loads(prob.stdout).get('streams', [])
            if not any(s['codec_type'] == 'video' for s in streams):
                raise RuntimeError(f'No hay pista de video: {f["ruta"]}')
            con_audio = any(s['codec_type'] == 'audio' for s in streams)
            dst = tmp / f'segmento_{i:05}.mp4'
            cmd = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin', '-y',
                   '-i', origen_url]
            if not con_audio:
                cmd += ['-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo']
            cmd += ['-map', '0:v:0', '-map', '0:a:0' if con_audio else '1:a:0',
                    '-vf', (f'fps=30,scale={ancho}:{alto}:force_original_aspect_ratio=decrease,'
                            f'pad={ancho}:{alto}:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p'),
                    '-c:v', 'libx264', '-preset', 'veryfast', '-crf', str(crf),
                    '-c:a', 'aac', '-ar', '48000', '-ac', '2', '-b:a', '128k',
                    '-af', 'apad', '-shortest', '-movflags', '+faststart', str(dst)]
            ejecutar(cmd, timeout=5400)
            if not dst.is_file() or dst.stat().st_size == 0:
                raise RuntimeError(f'Segmento vacío: {dst}')
            salidas.append(dst)
            detalle.append({'origen': f['ruta'], 'segmento': dst.name, 'bytes': dst.stat().st_size,
                            'estado': 'OK'})
    except Exception as e:
        detalle.append({'origen': f.get('ruta') if 'f' in locals() else '',
                        'segmento': '', 'bytes': 0, 'estado': str(e)})
        raise
    finally:
        registrar_csv(logdir / 'traza_segmentos.csv', detalle,
                     ['origen', 'segmento', 'bytes', 'estado'])
    return salidas


def preparar_mensual(mes: str, filas: list[dict], args, logdir: Path) -> Path | None:
    objetivo = [f for f in filas if f['mes'] == mes]
    if not objetivo:
        LOG.warning('%s: BLOQUEADO_SIN_VIDEOS_FECHADOS', mes)
        (logdir / 'estado.txt').write_text(f'{mes} BLOQUEADO_SIN_VIDEOS_FECHADOS\n', encoding='utf-8')
        return None
    total_bytes = sum(f['bytes'] for f in objetivo)
    if args.max_source_gb > 0 and total_bytes > args.max_source_gb * 1024**3:
        LOG.warning('%s: BLOQUEADO_LIMITE %.2f GiB > %.2f GiB', mes,
                    total_bytes / 1024**3, args.max_source_gb)
        (logdir / 'estado.txt').write_text(f'{mes} BLOQUEADO_LIMITE_GB\n', encoding='utf-8')
        return None
    etiqu = f'{MESES[int(mes[5:]) - 1]}-{mes[:4]}'
    destino = f'{args.remote.rstrip(":")}:/{args.dest.strip("/")}/{etiqu}.7z'.replace(':/', ':')
    # No reemplazar copias previas aunque su cobertura no esté confirmada.
    if subprocess.run(['rclone', 'lsjson', '--stat', destino], capture_output=True).returncode == 0:
        LOG.warning('%s: EXISTE_EN_DRIVE_NO_SOBRESCRITO: %s', mes, destino)
        (logdir / 'estado.txt').write_text(f'{mes} EXISTE_NO_SOBRESCRITO\n', encoding='utf-8')
        return None
    if args.dry_run:
        LOG.info('SIMULACIÓN: %s, %d MP4, %.2f GiB. No se descargan contenidos.',
                 mes, len(objetivo), total_bytes / 1024**3)
        (logdir / 'estado.txt').write_text(f'{mes} SIMULACION\n', encoding='utf-8')
        return None
    with tempfile.TemporaryDirectory(prefix=f'exportador_{mes}_') as dir_tmp:
        tmp = Path(dir_tmp)
        with ServidorRclone(args.remote, logdir) as servidor:
            seg = segmentos_ffmpeg(objetivo, servidor, tmp, logdir, args.ancho, args.alto, args.crf)
        lista = tmp / 'concat.txt'
        # Los nombres son generados por la herramienta; nunca se insertan rutas arbitrarias.
        lista.write_text(''.join(f"file '{x.name}'\n" for x in seg), encoding='ascii')
        final_mp4 = tmp / f'{etiqu}.mp4'
        ejecutar(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin', '-y',
                  '-f', 'concat', '-safe', '0', '-i', str(lista), '-c', 'copy',
                  '-movflags', '+faststart', str(final_mp4)], timeout=1200)
        ejecutar(['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
                  '-of', 'default=noprint_wrappers=1', str(final_mp4)], timeout=180)
        arc = tmp / f'{etiqu}.7z'
        ejecutar(['7z', 'a', '-t7z', '-mx=0', str(arc), str(final_mp4)], timeout=3600)
        ejecutar(['7z', 't', str(arc)], timeout=3600)
        h = hashlib.sha256()
        with arc.open('rb') as entrada:
            for bloque in iter(lambda: entrada.read(4 * 1024 * 1024), b''):
                h.update(bloque)
        digest = h.hexdigest()
        info = {'mes': mes, 'fuentes': objetivo, 'nombre': arc.name, 'bytes_7z': arc.stat().st_size,
                'sha256_7z': digest, 'fecha_utc': dt.datetime.now(dt.timezone.utc).isoformat()}
        (logdir / 'manifest_resultado.json').write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding='utf-8')
        # Se evita reescribir archivos existentes por defecto; condición de carrera improbable en un solo workflow.
        ejecutar(['rclone', 'copyto', str(arc), destino, '--ignore-existing', '--retries', '5'], timeout=5400)
        # Comprobar que el objeto remoto existe y tiene el mismo tamaño (sin bajar el 7z).
        resultado = ejecutar(['rclone', 'lsjson', '--stat', destino], timeout=120)
        meta = json.loads(resultado.stdout)
        if int(meta.get('Size', -1)) != arc.stat().st_size:
            raise RuntimeError('La copia remota no tiene el tamaño del 7z local')
        LOG.info('SUBIDO Y TAMANO REMOTO VALIDADO %s (%d bytes) - SHA256=%s', destino, arc.stat().st_size, digest)
        (logdir / 'estado.txt').write_text(f'{mes} SUBIDO_VERIFICADO_LOCALMENTE {digest}\n', encoding='utf-8')
    return Path(f'{etiqu}.7z')


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--remote', default='urp:', help='rclone remoto origen, sin ruta y con dos puntos')
    p.add_argument('--dest', default='Videos_Unidos_2020_2025_7z', help='Carpeta de salida en el remoto')
    p.add_argument('--mes', default='inventario', help='YYYY-MM o inventario')
    p.add_argument('--max-source-gb', type=float, default=6.0)
    p.add_argument('--ancho', type=int, default=720)
    p.add_argument('--alto', type=int, default=1280)
    p.add_argument('--crf', type=int, default=23)
    p.add_argument('--dry-run', action='store_true')
    p.add_argument('--fixture-json', help='Fixture JSON de metadatos para pruebas CI, sin acceso a Drive')
    p.add_argument('--min-videos', type=int, default=0, help='Umbral minimo de MP4 fechados para validar inventario')
    p.add_argument('--logs', default='logs', help='Directorio de logs, sin secretos')
    args = p.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+:', args.remote):
        p.error('--remote requiere formato nombre: (ejemplo urp:)')
    if not (args.mes == 'inventario' or re.fullmatch(r'20(?:2[0-5])-(?:0[1-9]|1[0-2])', args.mes)):
        p.error('--mes debe ser inventario o YYYY-MM entre 2020 y 2025')
    if args.ancho % 2 or args.alto % 2 or args.ancho <= 0 or args.alto <= 0:
        p.error('Dimensiones deben ser números positivos pares')
    logdir = Path(args.logs).resolve()
    logdir.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(level=logging.INFO,
                        format='%(asctime)s %(levelname)s %(message)s',
                        handlers=[logging.StreamHandler(sys.stdout),
                                  logging.FileHandler(logdir / 'proceso.log', encoding='utf-8')])
    LOG.info('Iniciando. Drive remoto=%s, mes=%s, simulacion=%s', args.remote, args.mes, args.dry_run)
    LOG.info('Alcance: MP4 con fecha YYYYMMDD reconocible en NOMBRE, años 2020-2025')
    try:
        if args.fixture_json:
            if not args.dry_run:
                raise ValueError('--fixture-json solo se permite con --dry-run')
            datos = json.loads(Path(args.fixture_json).read_text(encoding='utf-8'))
            LOG.info('MODO PRUEBA: inventario cargado desde fixture, sin acceder a Drive')
        else:
            datos = listar_remoto(args.remote)
        filas, ignorados = inventario(datos, args.dest)
        if len(filas) < args.min_videos:
            raise RuntimeError(f'Inventario incompleto: {len(filas)} < {args.min_videos} MP4 esperados')
        escribir_reportes(logdir, filas, ignorados)
        LOG.info('Resultado: %d con fecha, %d sin fecha.', len(filas), len(ignorados))
        if args.mes != 'inventario':
            preparar_mensual(args.mes, filas, args, logdir)
        else:
            (logdir / 'estado.txt').write_text('INVENTARIO_FINALIZADO\n', encoding='utf-8')
        return 0
    except Exception:
        LOG.exception('Fallo durante la ejecución')
        (logdir / 'estado.txt').write_text('ERROR_REVISAR_PROCESO_LOG\n', encoding='utf-8')
        return 1


if __name__ == '__main__':
    sys.exit(main())