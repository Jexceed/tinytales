#!/usr/bin/env python3
"""Sign local TinyTales builds with one persistent, certificate-pinned identity.
No certificates are added to system trust or keychains. No secrets enter the app.
"""
import hashlib
import io
import json
import os
import plistlib
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

SUPPORT = Path.home() / 'Library/Application Support/com.jexceed.tinytales'
TOOL_URL = 'https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign/0.29.0/apple-codesign-0.29.0-aarch64-apple-darwin.tar.gz'
ARCHIVE_SHA256 = 'd1a532150adaf90048260d76359261aa716abafc45c53c5dc18845029184334a'
BINARY_SHA256 = '6c4623db45f1d89af439a2ce42fd65798ef56aaaa3e4ced48879be05f750aacb'
APP_ID = 'com.jexceed.tinytales'

def run(args, **kwargs):
    result = subprocess.run(args, capture_output=True, **kwargs)
    if result.returncode:
        # Never dump crypto-tool output: PEM material is handled only in memory.
        raise RuntimeError(f'{Path(args[0]).name} failed with exit code {result.returncode}; existing signing identity preserved')
    return result

def tool_path():
    tools = SUPPORT / 'build-tools'; tools.mkdir(mode=0o700, parents=True, exist_ok=True)
    tool = tools / 'rcodesign'
    if not tool.exists():
        data = urllib.request.urlopen(TOOL_URL, timeout=45).read()
        if hashlib.sha256(data).hexdigest() != ARCHIVE_SHA256: raise RuntimeError('Signing tool archive checksum mismatch')
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
            member = next(m for m in archive.getmembers() if m.isfile() and Path(m.name).name == 'rcodesign')
            binary = archive.extractfile(member).read()
        if hashlib.sha256(binary).hexdigest() != BINARY_SHA256: raise RuntimeError('Signing tool checksum mismatch')
        tool.write_bytes(binary); tool.chmod(0o700)
    if hashlib.sha256(tool.read_bytes()).hexdigest() != BINARY_SHA256: raise RuntimeError('Signing tool checksum mismatch')
    return tool

def identity(openssl):
    state = SUPPORT / 'build-signing'; state.mkdir(mode=0o700, parents=True, exist_ok=True)
    state.chmod(0o700)
    if state.is_symlink(): raise RuntimeError('Signing state must be a real local directory')
    p12, password, cert, manifest = [state / name for name in ['identity.p12', 'passphrase.txt', 'certificate.pem', 'identity.json']]
    if not p12.exists():
        if any(p.exists() for p in [password, cert, manifest]): raise RuntimeError('Incomplete signing state; refusing to create a different identity')
        descriptor = os.open(password, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(descriptor, 'w') as out: out.write(secrets.token_urlsafe(40))
        with tempfile.TemporaryDirectory(dir=state) as tmp:
            tmp = Path(tmp); private = tmp / 'private.pem'; config = tmp / 'certificate.cnf'
            config.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=signing\n[dn]\nCN=TinyTales Local Development\n[signing]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyCertSign\nextendedKeyUsage=codeSigning\nsubjectKeyIdentifier=hash\n')
            run([openssl, 'req', '-x509', '-newkey', 'rsa:3072', '-sha256', '-days', '3650', '-nodes', '-config', str(config), '-keyout', str(private), '-out', str(cert)])
            private.chmod(0o600)
            run([openssl, 'pkcs12', '-export', '-inkey', str(private), '-in', str(cert), '-out', str(p12), '-name', 'TinyTales Local Development', '-passout', 'file:' + str(password)])
        p12.chmod(0o600)
    for path in [p12, password]:
        if path.is_symlink() or path.stat().st_uid != os.geteuid(): raise RuntimeError('Unexpected signing identity ownership or symlink')
        path.chmod(0o600)
    der = run([openssl, 'x509', '-in', str(cert), '-outform', 'DER']).stdout
    fingerprint = hashlib.sha1(der).hexdigest()
    requirement = f'identifier "{APP_ID}" and certificate leaf = H"{fingerprint}"'
    if manifest.exists():
        expected = json.loads(manifest.read_text())
        if expected['certificateSHA1'] != fingerprint: raise RuntimeError('Signing certificate changed; refusing to reset the application identity')
    else:
        manifest.write_text(json.dumps({'name': 'TinyTales Local Development', 'certificateSHA1': fingerprint, 'certificateSHA256': hashlib.sha256(der).hexdigest(), 'designatedRequirement': requirement, 'appleIssued': False}, indent=2) + '\n')
    requirements = state / 'designated-requirement.bin'
    run(['/usr/bin/csreq', '-r', '=' + requirement, '-b', str(requirements)])
    return p12, password, requirements, fingerprint

def main():
    app = Path(sys.argv[1]).resolve()
    if not (app / 'Contents/Info.plist').is_file(): raise RuntimeError('An application bundle is required')
    if plistlib.loads((app / 'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier') != APP_ID:
        raise RuntimeError('This signing identity is only for TinyTales')
    openssl = '/opt/homebrew/bin/openssl' if Path('/opt/homebrew/bin/openssl').exists() else '/usr/bin/openssl'
    tool = tool_path(); p12, password, requirements, fingerprint = identity(openssl)
    # rcodesign 0.29 cannot read modern PBES2 P12 files directly. OpenSSL decrypts
    # into memory and the private key is sent through stdin, never argv or a file.
    material = run([openssl, 'pkcs12', '-in', str(p12), '-passin', 'file:' + str(password), '-nodes']).stdout
    run([str(tool), 'sign', '--config-file', '/dev/null', '--pem-file', '/dev/stdin', '--code-requirements-file', str(requirements), '--timestamp-url', 'none', str(app)], input=material, timeout=45)
    del material
    displayed = run(['/usr/bin/codesign', '-d', '-r-', str(app)], text=True)
    if fingerprint not in displayed.stdout or 'certificate leaf' not in displayed.stdout: raise RuntimeError('The resulting signature does not pin the persistent certificate')
    print('Signed with the persistent TinyTales local identity.')

if __name__ == '__main__':
    main()
