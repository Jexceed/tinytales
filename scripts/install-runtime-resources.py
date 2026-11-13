#!/usr/bin/env python3
"""Copy optional local speech/pet assets into TinyTales-owned Application Support.
Only the installer reads the old development directories. The running app does not.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import uuid

APP_ID = 'com.jexceed.tinytales'

def clone(source, destination):
    subprocess.run(['/bin/cp', '-cR', str(source), str(destination)], check=True, capture_output=True)

def install_tts(source, support):
    target = support / 'local-tts'
    ready = target / 'runtime.json'
    if ready.is_file() and json.loads(ready.read_text()).get('layoutVersion') == 1:
        print('Managed local speech runtime already installed.')
        return
    if not (source / '.venv/bin/python').is_file():
        print('No local F5 source found; macOS speech remains available.')
        return
    required = ['checkpoints/F5TTS_v1_Base/model_1250000.safetensors', 'checkpoints/F5TTS_v1_Base/vocab.txt', 'checkpoints/vocos-mel-24khz/pytorch_model.bin', 'checkpoints/vocos-mel-24khz/config.yaml', 'local_runtime_patch.py']
    for name in required:
        if not (source / name).is_file():
            raise RuntimeError('The local F5 source is incomplete: ' + name)
    config = dict(line.split(' = ', 1) for line in (source / '.venv/pyvenv.cfg').read_text().splitlines() if ' = ' in line)
    python_root = Path(config['home']).parent
    if not (python_root / 'bin/python3').is_file() or not (python_root / 'lib').is_dir():
        raise RuntimeError('A relocatable local Python installation is required.')
    stage = support / ('.local-tts-install-' + uuid.uuid4().hex)
    stage.mkdir(mode=0o700)
    print('Installing a private copy of the speech environment and model weights…', flush=True)
    try:
        clone(source / '.venv', stage / '.venv')
        clone(source / 'checkpoints', stage / 'checkpoints')
        clone(python_root, stage / 'python')
        shutil.copy2(source / 'local_runtime_patch.py', stage / 'local_runtime_patch.py')
        # Use a local interpreter rather than the original Codex cache or project.
        for name in ['python', 'python3', 'python3.12']:
            executable = stage / '.venv/bin' / name
            if executable.is_symlink() or executable.exists(): executable.unlink()
            executable.symlink_to('../../python/bin/python3' if name == 'python3' else 'python3')
        replacements = [(str(source).encode(), str(target).encode()), (str(python_root).encode(), str(target / 'python').encode())]
        for folder, dirs, files in os.walk(stage):
            for cache in [d for d in dirs if d == '__pycache__']:
                shutil.rmtree(Path(folder) / cache)
                dirs.remove(cache)
            for name in files:
                path = Path(folder) / name
                if path.is_symlink() or path.stat().st_size > 1_000_000: continue
                in_bin = path.parent == stage / '.venv/bin'
                if not in_bin and path.suffix not in ['.py', '.pth', '.cfg', '.json']: continue
                data = path.read_bytes()
                if b'\0' in data: continue
                original = data
                for old, new in replacements: data = data.replace(old, new)
                if in_bin and original.startswith(b'#!') and b'/.venv/bin/python' in original.split(b'\n', 1)[0]:
                    launcher = '#!/bin/sh\n\'\'\'exec\' ' + shlex.quote(str(target / '.venv/bin/python')) + ' "$0" "$@"\n\' \'\'\'\n'
                    data = launcher.encode() + data.split(b'\n', 1)[1]
                if data != original: path.write_bytes(data)
        if target.exists():
            target.rename(support / ('.local-tts-previous-' + uuid.uuid4().hex))
        stage.rename(target)
        environment = {k: v for k, v in os.environ.items() if k in ['HOME', 'LANG', 'LC_ALL', 'TMPDIR']}
        environment.update(PATH='/opt/homebrew/bin:/usr/bin:/bin', HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', PYTHONNOUSERSITE='1')
        probe = 'import json,sys,torch,importlib.metadata;print(json.dumps({"python":sys.version.split()[0],"torch":torch.__version__,"f5tts":importlib.metadata.version("f5-tts"),"prefix":sys.prefix,"basePrefix":sys.base_prefix}))'
        result = subprocess.run([str(target / '.venv/bin/python'), '-I', '-c', probe], cwd=target, env=environment, capture_output=True, text=True, timeout=60)
        if result.returncode != 0: raise RuntimeError('Managed Python import check failed: ' + result.stderr[-1200:])
        metadata = json.loads(result.stdout.splitlines()[-1])
        if not metadata['prefix'].startswith(str(target)) or not metadata['basePrefix'].startswith(str(target)):
            raise RuntimeError('The interpreter still depends on its original location.')
        metadata.update(layoutVersion=1, modelsLocal=True)
        ready.write_text(json.dumps(metadata, indent=2) + '\n')
        print('Managed local speech runtime is ready.')
    finally:
        if stage.exists(): shutil.rmtree(stage)

def install_pets(source, support):
    target = support / 'pets'
    target.mkdir(mode=0o700, exist_ok=True)
    imported = 0
    if source.is_dir():
        for directory in source.iterdir():
            if directory.is_symlink() or not directory.is_dir(): continue
            manifest = directory / 'pet.json'
            if not manifest.is_file(): continue
            try:
                value = json.loads(manifest.read_text())
                image = (directory / value['spritesheetPath']).resolve()
                if not image.is_relative_to(directory.resolve()) or image.suffix.lower() not in ['.png', '.webp']: continue
                if not image.is_file(): continue
                destination = target / directory.name
                destination.mkdir(mode=0o700, exist_ok=True)
                filename = 'spritesheet' + image.suffix.lower()
                shutil.copy2(image, destination / filename)
                (destination / 'pet.json').write_text(json.dumps({'displayName': value['displayName'], 'spritesheetPath': filename}, ensure_ascii=False, indent=2) + '\n')
                imported += 1
            except (KeyError, ValueError, OSError): continue
    print(f'Managed companion assets: {imported} imported.')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--tts-source', type=Path, default=Path.home() / 'Documents/Projects/playground/local-tts')
    args = parser.parse_args()
    support = Path.home() / 'Library/Application Support' / APP_ID
    support.mkdir(mode=0o700, parents=True, exist_ok=True)
    if support.is_symlink(): raise RuntimeError('Application Support must be a real local directory.')
    install_tts(args.tts_source, support)
    install_pets(Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))) / 'pets', support)

if __name__ == '__main__':
    main()
