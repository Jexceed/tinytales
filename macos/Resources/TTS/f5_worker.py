#!/usr/bin/env python3
"""Process-local F5 inference. JSON lines in/out; text/audio never written to files.

Uses the application's managed local environment and weights. The voice reference
is an existing synthetic voice asset, not a recording of a family member.
"""
import argparse
import base64
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import time


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--engine-root', required=True)
    parser.add_argument('--reference', required=True)
    parser.add_argument('--reference-text', required=True)
    args = parser.parse_args()
    root = Path(args.engine_root).resolve()
    os.chdir(root)
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['TRANSFORMERS_OFFLINE'] = '1'
    os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
    os.environ['GRADIO_ANALYTICS_ENABLED'] = 'False'
    sys.path.insert(0, str(root))
    started = time.monotonic()
    try:
        with contextlib.redirect_stdout(sys.stderr):
            from local_runtime_patch import apply_all
            apply_all()
            import torch
            import soundfile as sf
            from f5_tts.api import F5TTS
            torch.set_num_threads(4)
            model = F5TTS(
                device='mps' if torch.backends.mps.is_available() else 'cpu',
                ckpt_file=str(root / 'checkpoints/F5TTS_v1_Base/model_1250000.safetensors'),
                vocab_file=str(root / 'checkpoints/F5TTS_v1_Base/vocab.txt'),
                vocoder_local_path=str(root / 'checkpoints/vocos-mel-24khz'),
            )
        reference_text = Path(args.reference_text).read_text().strip()
        emit({'type': 'ready', 'backend': 'F5-TTS', 'device': model.device, 'loadSeconds': round(time.monotonic() - started, 3)})
        for raw in sys.stdin:
            request_id = None
            try:
                request = json.loads(raw)
                request_id = request.get('id')
                if request.get('type') == 'shutdown':
                    break
                text = request.get('text', '').strip()
                if not isinstance(request_id, str) or not text or len(text) > 180:
                    raise ValueError('invalid_request')
                start = time.monotonic()
                with contextlib.redirect_stdout(sys.stderr):
                    wav, sample_rate, _ = model.infer(
                        ref_file=args.reference,
                        ref_text=reference_text,
                        gen_text=text,
                        nfe_step=16,
                        speed=0.96,
                        seed=42,
                        progress=None,
                        show_info=lambda *a, **k: None,
                    )
                audio = io.BytesIO()
                sf.write(audio, wav, sample_rate, format='WAV', subtype='PCM_16')
                emit({'type': 'audio', 'id': request_id, 'sampleRate': sample_rate,
                      'seconds': round(len(wav) / sample_rate, 3),
                      'generationSeconds': round(time.monotonic() - start, 3),
                      'wav': base64.b64encode(audio.getvalue()).decode('ascii')})
            except Exception as error:
                # Never echo input text, raw library payloads or audio into diagnostics.
                emit({'type': 'error', 'id': request_id, 'error': type(error).__name__})
    except Exception as error:
        emit({'type': 'fatal', 'error': type(error).__name__})
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
