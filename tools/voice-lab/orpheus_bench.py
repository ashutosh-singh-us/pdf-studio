"""Orpheus 3B (Canopy Labs) on this Mac with MLX: speed, memory and audio.

Usage:  .venv/bin/python orpheus_bench.py [model] [label]
Orpheus speaks one named voice per call, so a story is rendered line by line with a fixed
voice per character (narrator, then each speaker) and joined. Voices stay the same every
time, unlike Dia's random speakers. Emotion tags: <laugh> <chuckle> <sigh> <gasp> <groan> ...
"""
import sys
import time
from pathlib import Path

import mlx.core as mx
import numpy as np
import soundfile as sf
from mlx_audio.tts.utils import load_model

# (voice, line). Voices: tara leah jess leo dan mia zac zoe.
SCRIPTS = {
    "story": [
        ("leo", "The blacksmith wiped the soot from his face and stared at the glowing blade."),
        ("tara", "You actually did it. A legendary item, from a man who failed at everything! <laugh>"),
        ("dan", "Don't celebrate yet. If anyone finds out, they'll come for it. Every guild in the kingdom will."),
        ("tara", "<sigh> Then we make sure nobody finds out."),
    ],
    "lesson": [
        ("leo", "Let's talk about compound interest. The idea is simple: you earn interest on your interest. "
                "Put in one hundred dollars at ten percent, and after a year you have one hundred and ten. "
                "The next year, the ten percent applies to all one hundred and ten. "
                "That small difference, repeated for decades, is the whole secret."),
    ],
}


def main() -> None:
    model_id = sys.argv[1] if len(sys.argv) > 1 else "mlx-community/orpheus-3b-0.1-ft-4bit"
    label = sys.argv[2] if len(sys.argv) > 2 else "orpheus-q4"
    out = Path(__file__).parent / "out"
    out.mkdir(exist_ok=True)
    t0 = time.time()
    model = load_model(model_id)
    load_s = time.time() - t0
    sr = 24000
    gap = np.zeros(int(0.35 * sr), dtype=np.float32)
    for name, lines in SCRIPTS.items():
        mx.random.seed(7)
        mx.reset_peak_memory()
        mx.clear_cache()
        t0 = time.time()
        parts = []
        for voice, text in lines:
            for r in model.generate(text=text, voice=voice, verbose=False):
                parts.append(np.array(r.audio, dtype=np.float32))
                sr = r.sample_rate
            parts.append(gap)
        compute = time.time() - t0
        audio = np.concatenate(parts)
        seconds = len(audio) / sr
        sf.write(out / f"{label}-{name}.wav", audio, sr)
        print(f"RESULT {label:10s} {name:7s} audio={seconds:5.1f}s compute={compute:6.1f}s "
              f"speed={seconds / compute:4.2f}x-real-time peak_mem={mx.get_peak_memory() / 1e9:4.1f}GB load={load_s:4.1f}s",
              flush=True)


if __name__ == "__main__":
    main()
