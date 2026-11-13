"""Application-owned, offline Mandarin speech worker. Audio stays in memory."""
import argparse
import base64
import contextlib
import json
import os
import queue
import sys
import threading

parser = argparse.ArgumentParser()
parser.add_argument("--engine-root", required=True)
args = parser.parse_args()
output = sys.stdout


def emit(value):
    output.write(json.dumps(value, ensure_ascii=False) + "\n")
    output.flush()


requests = queue.Queue()
cancelled = set()
closing = threading.Event()


def read_input():
    for line in sys.stdin:
        try:
            request = json.loads(line)
            if request.get("type") == "shutdown":
                break
            if request.get("type") == "cancel":
                cancelled.add(request.get("id"))
            elif request.get("type") == "speak":
                requests.put(request)
        except (ValueError, TypeError):
            continue
    closing.set()
    requests.put(None)


threading.Thread(target=read_input, daemon=True).start()
try:
    with contextlib.redirect_stdout(sys.stderr):
        import mlx.core as mx
        import numpy as np
        from mlx_audio.tts.utils import load_model
        model = load_model(os.path.join(args.engine_root, "model"))
    emit({"type": "ready", "sample_rate": model.sample_rate})
    while not closing.is_set():
        request = requests.get()
        if request is None:
            break
        identity = request.get("id", "")
        if identity in cancelled:
            cancelled.discard(identity)
            continue
        try:
            text = request.get("text", "")
            speaker = request.get("speaker", "Serena")
            if not isinstance(text, str) or not 0 < len(text) <= 5000 or speaker not in ("Serena", "Vivian"):
                raise ValueError("invalid speech request")
            mx.random.seed(42)
            with contextlib.redirect_stdout(sys.stderr):
                generation = model.generate_custom_voice(
                    text=text, speaker=speaker, language="Chinese",
                    instruct=request.get("instructions", ""), temperature=0.7,
                    max_tokens=2048, stream=True, streaming_interval=0.64,
                )
                try:
                    for result in generation:
                        if closing.is_set() or identity in cancelled:
                            break
                        audio = np.asarray(result.audio, dtype=np.float32).reshape(-1)
                        pcm = (np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes()
                        emit({"type": "chunk", "id": identity, "pcm": base64.b64encode(pcm).decode("ascii")})
                finally:
                    generation.close()
                    model.speech_tokenizer.decoder.reset_streaming_state()
                    mx.clear_cache()
            if identity not in cancelled and not closing.is_set():
                emit({"type": "done", "id": identity})
        except Exception:
            emit({"type": "error", "id": identity})
        finally:
            cancelled.discard(identity)
except Exception:
    emit({"type": "fatal"})
