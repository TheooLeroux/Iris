"""Contrôle d'une APK sans données personnelles et création du manifeste Android."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import zipfile


def inspect_apk(path):
    found_library = found_audit = False
    def inspect(archive):
        nonlocal found_library, found_audit
        for name in archive.namelist():
            if name.endswith('/'):
                continue
            data = archive.read(name)
            if name.endswith(('.zip', '.imy')):
                with zipfile.ZipFile(io.BytesIO(data)) as child:
                    inspect(child)
            if name.endswith(('.sqlite3', '.db')) or name.endswith('assets/library.json'):
                raise ValueError('Base personnelle ou bibliothèque Flutter interdite dans une APK publique.')
            if 'session-mangatime' in name:
                raise ValueError('Session personnelle interdite dans une APK publique.')
            if name.endswith('mangatime-20261119-134639-04c64935.json'):
                if json.loads(data) != []:
                    raise ValueError('La bibliothèque initiale doit être vide.')
                found_library = True
            if name.endswith('audit-complet/resultats-revus.json'):
                audit = json.loads(data)
                if any(audit['sources'].values()):
                    raise ValueError('Les correspondances personnelles doivent être absentes.')
                found_audit = True
            if name.endswith('vowrune-identification.json'):
                raise ValueError('Fiche personnelle initiale interdite dans une APK publique.')
    with zipfile.ZipFile(path) as archive:
        inspect(archive)
    if not (found_library and found_audit):
        raise ValueError('Données initiales publiques absentes ou format APK inconnu.')


def manifest(apk, version, build, repository, notes):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or build <= 0:
        raise ValueError('Version ou numéro de build invalide.')
    inspect_apk(apk)
    tag = f'v{version}+{build}'
    return {'version': version, 'build': build, 'size': apk.stat().st_size,
            'sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
            'apk_url': f'https://github.com/{repository}/releases/download/{tag}/Iris-{version}.apk',
            'notes': notes[:3000]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--pubspec', type=Path, default=Path('mobile/pubspec.yaml'))
    parser.add_argument('--repository', default='TheooLeroux/Iris')
    parser.add_argument('--notes', type=Path, default=Path('mobile/release-notes.txt'))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    match = re.search(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$', args.pubspec.read_text(encoding='utf-8'), re.M)
    if not match:
        raise ValueError('Version absente du pubspec.')
    data = manifest(args.apk, match[1], int(match[2]), args.repository, args.notes.read_text(encoding='utf-8'))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'version': data['version'], 'build': data['build'], 'sha256': data['sha256']}))


if __name__ == '__main__':
    main()
