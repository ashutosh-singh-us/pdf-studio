import sys
"""Transcribes the benchmark WAVs with Whisper and reports word error rate against the script."""
import re, sys
from pathlib import Path
import mlx_whisper
from bench import PASSAGES

def words(t):
    t = re.sub(r"\[S\d\]|\([^)]*\)", " ", t.lower())
    return re.findall(r"[a-z']+", t)

def wer(ref, hyp):
    d = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        prev, d[0] = d[0], i
        for j, h in enumerate(hyp, 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (r != h))
    return d[len(hyp)] / max(1, len(ref))

for wav in sorted(Path("out").glob(sys.argv[1] if len(sys.argv) > 1 else "dia-*.wav")):
    passage = wav.stem.rsplit("-", 1)[1]
    text = mlx_whisper.transcribe(str(wav), path_or_hf_repo="mlx-community/whisper-large-v3-turbo", language="en")["text"]
    print(f"WER {wav.stem:18s} {wer(words(PASSAGES[passage]), words(text)):5.1%}  | {text.strip()[:110]}")
