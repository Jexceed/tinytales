"""Compare fixed synthetic Mandarin samples on the installed Mac runtime."""
import json
import os
import time
import wave
from pathlib import Path

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["TOKENIZERS_PARALLELISM"] = "false"

import mlx.core as mx
import numpy as np
from mlx_audio.tts.utils import load_model

root = Path.home() / "Library/Application Support/com.jexceed.tinytales/qwen-tts"
destination = Path(__file__).resolve().parents[1] / "artifacts/teacher-voice"
destination.mkdir(parents=True, exist_ok=True)
text = "你好呀，我是莉莉。今天想听什么故事？你可以慢慢告诉我。小兔子抱着一颗红苹果，轻轻敲了敲门：奶奶，我来看你啦。"
instructions = "请用标准、流利的普通话，像亲切的年轻幼儿园女老师在和一个小朋友面对面说话。声音温暖柔和，自然有笑意，音量平稳，语速适中稍慢，按完整意群自然连读。讲到小兔子时有轻微的故事表情，句尾轻轻收住，不夹嗓、不拖长尾音。"

started = time.monotonic()
model = load_model(str(root / "model"))
loaded = time.monotonic() - started
print(json.dumps({"loadedSeconds": loaded, "sampleRate": model.sample_rate}), flush=True)
reports = []
for speaker in ["Serena", "Vivian"]:
    mx.random.seed(42)
    started = time.monotonic()
    chunks = []
    first = None
    arrivals = []
    for result in model.generate_custom_voice(
        text=text, speaker=speaker, language="Chinese", instruct=instructions,
        temperature=0.7, max_tokens=1000, stream=True, streaming_interval=0.64,
    ):
        mx.eval(result.audio)
        now = time.monotonic() - started
        if first is None:
            first = now
        data = np.asarray(result.audio, dtype=np.float32).reshape(-1)
        chunks.append(data)
        arrivals.append({"atSeconds": now, "samples": len(data)})
    elapsed = time.monotonic() - started
    audio = np.concatenate(chunks)
    path = destination / f"teacher-{speaker.lower()}.wav"
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(model.sample_rate)
        wav.writeframes((np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes())
    duration = len(audio) / model.sample_rate
    report = {"speaker": speaker, "file": str(path), "firstChunkSeconds": first,
              "audioSeconds": duration, "generationSeconds": elapsed,
              "generationOverAudio": elapsed / duration, "peakMemoryGB": mx.get_peak_memory() / 1e9,
              "chunks": arrivals}
    reports.append(report)
    print(json.dumps({k: v for k, v in report.items() if k != "chunks"}), flush=True)
(destination / "local-comparison.json").write_text(json.dumps({
    "model": "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
    "revision": "41d3337e8b7f2843a75841595fc14e4b9a7a4b96", "mlxAudio": "0.6.5",
    "syntheticOnly": True, "physicalMicrophoneOpened": False, "text": text,
    "instructions": instructions, "loadSeconds": loaded, "samples": reports,
}, ensure_ascii=False, indent=2))
