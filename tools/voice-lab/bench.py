"""Benchmarks a TTS model on this Mac with MLX: speed, memory and audio for a story and a lesson.

Usage:  .venv/bin/python bench.py <model-path-or-repo> [label] [bf16|8|4]
The last argument casts Dia's transformer to bf16, or quantizes it to 8/4 bits in memory
(the audio codec stays full precision).
Writes out/<label>-<passage>.wav and prints one summary line per passage.

Speed is reported as x-real-time (seconds of audio per second of compute):
above 1.0 keeps up with live playback. The iPhone 16 Pro's GPU is roughly half an M4's.
"""
import sys
import time
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
import numpy as np
import soundfile as sf
from mlx_audio.tts.utils import load_model

from dia_quant import quantize_dia

# Dia script format: [S1]/[S2] speakers, non-verbal cues in parentheses.
PASSAGES = {
    "story": (
        "[S1] The blacksmith wiped the soot from his face and stared at the glowing blade. "
        "[S2] You actually did it. A legendary item, from a man who failed at everything! (laughs) "
        "[S1] Don't celebrate yet. If anyone finds out, they'll come for it. Every guild in the kingdom will. "
        "[S2] (whispers) Then we make sure nobody finds out."
    ),
    "lesson": (
        "[S1] Let's talk about compound interest. The idea is simple: you earn interest on your interest. "
        "Put in one hundred dollars at ten percent, and after a year you have one hundred and ten. "
        "The next year, the ten percent applies to all one hundred and ten. "
        "That small difference, repeated for decades, is the whole secret."
    ),
}


def main() -> None:
    model_id = sys.argv[1]
    label = sys.argv[2] if len(sys.argv) > 2 else Path(model_id).name
    out = Path(__file__).parent / "out"
    out.mkdir(exist_ok=True)

    precision = sys.argv[3] if len(sys.argv) > 3 else None
    t0 = time.time()
    model = load_model(model_id)
    if precision:
        model.model.set_dtype(mx.bfloat16)
        if precision != "bf16":
            n = quantize_dia(model.model, bits=int(precision))
            print(f"quantized {n} layers to {precision}-bit", flush=True)
        mx.eval(model.model.parameters())
    load_s = time.time() - t0

    for name, text in PASSAGES.items():
        mx.random.seed(7)  # same voices across variants, for a fair listen
        mx.reset_peak_memory()
        mx.clear_cache()
        t0 = time.time()
        chunks, sr = [], 44100
        for r in model.generate(text=text, verbose=False):
            chunks.append(np.array(r.audio))
            sr = r.sample_rate
        compute = time.time() - t0
        audio = np.concatenate(chunks) if chunks else np.zeros(1)
        seconds = len(audio) / sr
        sf.write(out / f"{label}-{name}.wav", audio, sr)
        print(f"RESULT {label:10s} {name:7s} audio={seconds:5.1f}s compute={compute:6.1f}s "
              f"speed={seconds / compute:4.2f}x-real-time peak_mem={mx.get_peak_memory() / 1e9:4.1f}GB load={load_s:4.1f}s",
              flush=True)


if __name__ == "__main__":
    main()
