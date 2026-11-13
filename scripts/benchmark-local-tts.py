import base64
import json
from pathlib import Path
import subprocess
import sys
import time

root = Path(__file__).resolve().parent.parent
engine = Path.home() / 'Documents/Projects/playground/local-tts'
resource = root / 'macos/Resources/TTS'
artifacts = root / 'artifacts'
artifacts.mkdir(exist_ok=True)
log = (artifacts / 'f5-worker-diagnostics.log').open('w')
worker = subprocess.Popen([str(engine / '.venv/bin/python'), '-u', str(resource / 'f5_worker.py'),
                           '--engine-root', str(engine), '--reference', str(resource / 'reference.wav'),
                           '--reference-text', str(resource / 'reference.txt')],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
records = []
try:
    ready = json.loads(worker.stdout.readline())
    print(json.dumps(ready, ensure_ascii=False), flush=True)
    if ready.get('type') != 'ready':
        raise RuntimeError('Local model failed to load')
    for index, text in enumerate(['你好呀，我在这里。今天想听一个什么样的故事呢？', '小兔子把雨伞轻轻挪过来，小刺猬终于不用淋雨啦。']):
        started = time.monotonic()
        worker.stdin.write(json.dumps({'id': str(index), 'text': text}, ensure_ascii=False) + '\n')
        worker.stdin.flush()
        result = json.loads(worker.stdout.readline())
        if result.get('type') != 'audio':
            raise RuntimeError(result.get('error', 'No audio returned'))
        output = artifacts / f'local-f5-{index + 1}.wav'
        output.write_bytes(base64.b64decode(result.pop('wav')))
        result.update({'sample': output.name, 'text': text, 'elapsedSeconds': round(time.monotonic() - started, 3)})
        records.append(result)
        print(json.dumps(result, ensure_ascii=False), flush=True)
    (artifacts / 'local-tts-benchmark.json').write_text(json.dumps({'ready': ready, 'samples': records, 'success': True}, ensure_ascii=False, indent=2))
finally:
    if worker.poll() is None:
        worker.stdin.write('{"type":"shutdown"}\n'); worker.stdin.flush()
        try: worker.wait(timeout=10)
        except subprocess.TimeoutExpired: worker.terminate()
    log.close()
