"""Install the pinned Mandarin voice in Application Support, once per Mac."""
import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path.home() / "Library/Application Support/com.jexceed.tinytales/qwen-tts"
MODEL = "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"
REVISION = "41d3337e8b7f2843a75841595fc14e4b9a7a4b96"
EXPECTED = {"layoutVersion": 1, "model": MODEL, "revision": REVISION, "mlxAudio": "0.6.5"}
manifest = ROOT / "runtime.json"
python = ROOT / ".venv/bin/python"
required = [ROOT / "model/model.safetensors", ROOT / "model/speech_tokenizer/model.safetensors"]
if manifest.exists() and json.loads(manifest.read_text()) == EXPECTED and python.exists() and all(p.exists() for p in required):
    print("Mandarin teacher voice already installed.")
else:
    uv = shutil.which("uv")
    if not uv:
        raise SystemExit("Install uv before preparing the local Mandarin voice.")
    ROOT.mkdir(parents=True, exist_ok=True)
    if not python.exists():
        subprocess.run([uv, "venv", "--python", "3.12", str(ROOT / ".venv")], check=True)
    subprocess.run([uv, "pip", "install", "--python", str(python), "mlx-audio==0.6.5", "socksio==1.0.0"], check=True)
    script = """
import os, sys
os.environ['HF_HUB_DISABLE_IMPLICIT_TOKEN']='1'
from huggingface_hub import snapshot_download
snapshot_download(sys.argv[1],revision=sys.argv[2],local_dir=sys.argv[3],max_workers=4)
"""
    subprocess.run([str(python), "-c", script, MODEL, REVISION, str(ROOT / "model")], check=True)
    manifest.write_text(json.dumps(EXPECTED, indent=2))
    print("Installed Mandarin teacher voice in Application Support.")
