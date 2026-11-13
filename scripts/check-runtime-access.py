#!/usr/bin/env python3
"""Verify packaged local speech while protected user folders are denied.
The app writes its diagnostic report to a private temporary directory, never Documents.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
support = Path.home() / 'Library/Application Support/com.jexceed.tinytales'
app = Path('/Applications/小小故事屋.app')
blocked = [Path.home()/name for name in ['Documents','Desktop','Downloads']]
legacy_python = Path.home()/'.cache/codex-runtimes/codex-primary-runtime/dependencies/python'
blocked += [legacy_python, legacy_python.resolve()]
filters = ' '.join('(subpath ' + json.dumps(str(p)) + ')' for p in blocked)
profile = '(version 1) (allow default) (deny file-read* file-write* ' + filters + ')'
environment = {k:v for k,v in os.environ.items() if k in ['HOME','LANG','LC_ALL','LC_CTYPE','TMPDIR','USER','LOGNAME']}
environment['PATH'] = '/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'
# Confirm the profile actively rejects a known existing project file.
probe = 'from pathlib import Path\ntry:\n open('+repr(str(root/'README.md'))+')\nexcept PermissionError:\n print("denial-confirmed")\nelse:\n raise SystemExit(1)'
control = subprocess.run(['/usr/bin/sandbox-exec','-p',profile,str(support/'local-tts/.venv/bin/python'),'-I','-c',probe],env=environment,cwd=support,capture_output=True,text=True,check=True)
assert control.stdout.strip() == 'denial-confirmed'
with tempfile.TemporaryDirectory(prefix='tinytales-access-', dir='/tmp') as temporary:
    report = Path(temporary)/'tts.json'
    command = ['/usr/bin/sandbox-exec','-p',profile,str(app/'Contents/MacOS/TinyTales'),'--verify-local-tts',str(report)]
    process = subprocess.run(command,env=environment,cwd=support,capture_output=True,text=True,timeout=100)
    if not report.exists():
        raise RuntimeError('Packaged speech check did not produce a report; exit code '+str(process.returncode))
    result = json.loads(report.read_text())
    result.update(protectedFolderDenialConfirmed=True, originalPythonRuntimeDenied=True, packagedApplication=True, exitCode=process.returncode)
    (root/'artifacts/v055-packaged-runtime-access.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(result,ensure_ascii=False))
    if process.returncode or not result.get('success'): raise SystemExit(1)
