#!/usr/bin/env python3
"""Migración URP -> Drive 2 por año. Copia, verifica TODO y solo entonces elimina."""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import date, datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

YEARS = range(2020, 2025)
VIDEO_EXT = {'.mp4', '.mov', '.m4v', '.mkv', '.avi', '.webm', '.3gp', '.mpeg', '.mpg', '.mts'}
DATE_RE = re.compile(r'(?<!\d)(202[0-4])[-_]?([01]\d)[-_]?([0-3]\d)(?!\d)')
YEAR_RE = re.compile(r'(?<!\d)(202[0-4])(?!\d)')
MD5_RE = re.compile(r'^[a-fA-F0-9]{32}$')


def year_of(path: str) -> int | None:
    """Priorizar fecha de grabación en nombre; como respaldo, carpeta de año."""
    name = path.rsplit('/', 1)[-1]
    found = set()
    for m in DATE_RE.finditer(name):
        try:
            date(int(m[1]), int(m[2]), int(m[3]))
        except ValueError:
            continue
        found.add(int(m[1]))
    if len(found) == 1:
        return next(iter(found))
    if len(found) > 1:
        return None
    found = {int(x) for x in YEAR_RE.findall(name)}
    if len(found) == 1:
        return next(iter(found))
    if len(found) > 1:
        return None
    folders = path.split('/')[:-1]
    folder_years = set()
    for folder in folders:
        m = re.match(r'^(202[0-4])(?:$|[-_\s])', folder)
        if m:
            folder_years.add(int(m[1]))
    return next(iter(folder_years)) if len(folder_years) == 1 else None


def is_video(f: dict) -> bool:
    path = str(f.get('Path', ''))
    return (str(f.get('MimeType', '')).startswith('video/')
            or Path(path).suffix.lower() in VIDEO_EXT)


def records(items: list[dict]) -> tuple[list[dict], list[dict]]:
    known, unknown = [], []
    seen = set()
    for f in items:
        if f.get('IsDir') or not is_video(f):
            continue
        path = f.get('Path', '')
        if not path or path.startswith('/') or '..' in path.split('/') or path in seen:
            raise ValueError(f'Ruta inválida o duplicada en Drive: {path!r}')
        seen.add(path)
        md5 = str(f.get('Hashes', {}).get('MD5') or '').lower()
        entry = {'path': path, 'size': int(f.get('Size', -1)),
                 'md5': md5, 'year': year_of(path)}
        (known if entry['year'] in YEARS else unknown).append(entry)
    return known, unknown


def select_year(items: list[dict], option: str, limit_bytes: int) -> tuple[int, list[dict], dict[int, int]]:
    totals = {y: sum(x['size'] for x in items if x['year'] == y) for y in YEARS}
    if option == 'auto':
        eligible = [y for y in YEARS if 0 < totals[y] < limit_bytes]
        if not eligible:
            raise ValueError('Ningún año completo identificable tiene videos y tamaño inferior al límite')
        year = max(eligible, key=lambda y: (totals[y], -y))
    else:
        year = int(option)
        if not 0 < totals[year] < limit_bytes:
            raise ValueError(f'{year}: tamaño {totals[year]} bytes; debe ser >0 y <{limit_bytes}')
    selected = sorted((x for x in items if x['year'] == year), key=lambda x: x['path'])
    for x in selected:
        if x['size'] < 0 or not MD5_RE.fullmatch(x['md5']):
            raise ValueError(f'Tamaño o MD5 desconocido, NO borrar: {x["path"]}')
    return year, selected, totals


def command(*args: str, allow_failure: bool = False) -> str:
    p = subprocess.run(['rclone', *args], capture_output=True, text=True)
    if p.returncode and not allow_failure:
        raise RuntimeError(f'rclone falló ({p.returncode}) en {args[:2]}: {p.stderr[-900:]}')
    return p.stdout if not p.returncode else ''


def lsjson(remote: str, *, missing_ok: bool = False) -> list[dict]:
    value = command('lsjson', remote, '--recursive', '--files-only', '--hash',
                    '--fast-list', allow_failure=missing_ok)
    return json.loads(value) if value else []


def equal(a: dict, b: dict) -> bool:
    return (a['size'] == int(b.get('Size', -1)) and
            a['md5'] == str(b.get('Hashes', {}).get('MD5') or '').lower() and
            bool(a['md5']))


def target_name(entry: dict, dest_files: dict, counts: Counter) -> str:
    name = entry['path'].rsplit('/', 1)[-1]
    if counts[name] == 1 and name in dest_files and equal(entry, dest_files[name]):
        return name  # Reaprovechar copias verificadas realizadas anteriormente.
    return 'ORIGEN/' + entry['path']


def write_json(path: Path, obj: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def run() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--anio', choices=['auto', '2020', '2021', '2022', '2023', '2024'], default='2021')
    p.add_argument('--limite-gb', type=float, default=10.0)
    p.add_argument('--origen', default='urp:')
    p.add_argument('--destino', default='drive2:Videos desde URP - 2026-10-12')
    p.add_argument('--ejecutar', action='store_true', help='Sin esta opción: solo inventario')
    p.add_argument('--eliminar-al-final', action='store_true', help='Eliminación definitiva, solo tras verificación completa')
    p.add_argument('--fixture-json', help='Prueba sintética sin conectarse a Drive')
    p.add_argument('--logs', default='logs_anual')
    a = p.parse_args()
    if a.limite_gb <= 0 or a.limite_gb > 10:
        p.error('--limite-gb debe estar entre 0 y 10 GB decimales')
    if a.eliminar_al_final and not a.ejecutar:
        p.error('--eliminar-al-final requiere --ejecutar')
    if a.origen.rstrip(':') == a.destino.split(':', 1)[0] or ':' not in a.destino:
        p.error('Origen y destino deben ser DOS remotos diferentes')
    if a.fixture_json and (a.ejecutar or a.eliminar_al_final):
        p.error('Las pruebas sintéticas nunca transfieren ni eliminan')
    if a.ejecutar and os.environ.get('GITHUB_REPOSITORY_PRIVATE', '').lower() != 'true':
        raise RuntimeError('BLOQUEADO: ejecución con datos privados exige repositorio GitHub PRIVADO')

    limit = int(a.limite_gb * 1_000_000_000)
    origin = a.origen.rstrip('/')
    items = json.loads(Path(a.fixture_json).read_text(encoding='utf-8')) if a.fixture_json else lsjson(origin)
    known, unknown = records(items)
    year, selected, totals = select_year(known, a.anio, limit)
    dest = a.destino.rstrip('/') + f'/Videos_URP_{year}_traslado_verificado'
    logs = Path(a.logs)
    report = {'year': year, 'limit_bytes_exclusive': limit, 'totals_by_year': totals,
              'selected_count': len(selected), 'selected_bytes': totals[year],
              'unknown_year_count': len(unknown), 'destination': dest,
              'status': 'INVENTARIO_COMPLETO_SIN_CAMBIOS'}
    write_json(logs / f'reporte_{year}.json', report)
    print(f'INVENTARIO año={year} archivos={len(selected)} bytes={totals[year]} desconocidos={len(unknown)}')
    if not a.ejecutar:
        print('SOLO_INVENTARIO. No se han copiado ni eliminado archivos.')
        return 0

    command('mkdir', dest)
    dest_files = {f['Path']: f for f in lsjson(dest)}
    counts = Counter(x['path'].rsplit('/', 1)[-1] for x in selected)
    mapping = {x['path']: target_name(x, dest_files, counts) for x in selected}
    if len(set(mapping.values())) != len(mapping):
        raise RuntimeError('Colisión de rutas destino. No se elimina ningún archivo.')
    copied = 0
    for x in selected:
        target = mapping[x['path']]
        old = dest_files.get(target)
        if old:
            if not equal(x, old):
                raise RuntimeError('Archivo destino distinto. No sobrescribir: ' + target)
            continue
        command('copyto', origin + '/' + x['path'], dest + '/' + target,
                '--disable', 'copy', '--retries', '5', '--low-level-retries', '10')
        copied += 1
        print('COPIADO:', x['path'])

    # Barrera transaccional: comparar inventario COMPLETO en origen y destino.
    changed_known, _ = records(lsjson(origin))
    current = [x for x in changed_known if x['year'] == year]
    original_key = {(x['path'], x['size'], x['md5']) for x in selected}
    current_key = {(x['path'], x['size'], x['md5']) for x in current}
    if current_key != original_key:
        raise RuntimeError('CAMBIOS_EN_ORIGEN: archivos añadidos, quitados o modificados; eliminación prohibida')
    verified_dest = {f['Path']: f for f in lsjson(dest)}
    unmatched = [x['path'] for x in selected if not equal(x, verified_dest.get(mapping[x['path']], {}))]
    if unmatched:
        raise RuntimeError('COPIA_INCOMPLETA: tamaño o MD5 no coincide; NO borrar: ' + str(unmatched[:6]))

    stamp = os.environ.get('GITHUB_RUN_ID', datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S'))
    manifest_name = f'MIGRATION_MANIFEST_{year}_{stamp}.json'
    manifest = {'year': year, 'checked_at_utc': datetime.now(timezone.utc).isoformat(),
                'status': 'VERIFICADO', 'selected_count': len(selected),
                'total_bytes': totals[year], 'source_remote': origin,
                'destination_remote': dest,
                'files': [{**x, 'destination': mapping[x['path']]} for x in selected]}
    local_manifest = logs / manifest_name
    write_json(local_manifest, manifest)
    command('copyto', str(local_manifest), dest + '/' + manifest_name)
    remote_manifest = {f['Path']: f for f in lsjson(dest)}.get(manifest_name, {})
    local_md5 = hashlib.md5(local_manifest.read_bytes()).hexdigest()
    if (int(remote_manifest.get('Size', -1)) != local_manifest.stat().st_size or
            str(remote_manifest.get('Hashes', {}).get('MD5', '')).lower() != local_md5):
        raise RuntimeError('MANIFIESTO_NO_VERIFICADO: eliminación prohibida')

    report.update({'status': 'COPIA_VERIFICADA', 'reused_or_existing': len(selected)-copied,
                   'new_copies': copied, 'manifest': manifest_name, 'files_verified': len(selected)})
    write_json(logs / f'reporte_{year}.json', report)
    print(f'COPIA_VERIFICADA archivos={len(selected)} nuevos={copied} manifest={manifest_name}')
    if not a.eliminar_al_final:
        print('ORIGINALES_CONSERVADOS (--eliminar-al-final no habilitado)')
        return 0

    # Solo DESPUÉS de que TODO el lote y el manifiesto estén comprobados.
    for index, x in enumerate(selected, 1):
        command('deletefile', origin + '/' + x['path'], '--drive-use-trash=false')
        print(f'ELIMINADO_VERIFICADO {index}/{len(selected)}: {x["path"]}')
    remaining, _ = records(lsjson(origin))
    leftovers = [x['path'] for x in remaining if x['path'] in mapping]
    if leftovers:
        raise RuntimeError(f'Eliminación parcial: permanecen {len(leftovers)} originales')
    report.update({'status': 'ELIMINACION_FINAL_VERIFICADA', 'originals_deleted': len(selected)})
    write_json(logs / f'reporte_{year}.json', report)
    print('ELIMINACION_FINAL_VERIFICADA')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(run())
    except (RuntimeError, ValueError, OSError, json.JSONDecodeError) as ex:
        print('TRANSFERENCIA_DETENIDA:', str(ex), file=sys.stderr)
        sys.exit(1)
