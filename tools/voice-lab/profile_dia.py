"""Splits Dia's time and memory between token generation and DAC audio decoding."""
import time
import mlx.core as mx
from mlx_audio.tts.utils import load_model
import mlx_audio.tts.models.dia.dia as dia_mod
from dia_quant import quantize_dia
from bench import PASSAGES

stats = {}
orig = dia_mod.codebook_to_audio
def timed(*a, **k):
    mx.eval(a[0]); stats["gen_peak"] = mx.get_peak_memory() / 1e9; stats["gen_t"] = time.time() - stats["t0"]
    mx.reset_peak_memory(); t = time.time()
    out = orig(*a, **k); mx.eval(out)
    stats["dac_t"] = time.time() - t; stats["dac_peak"] = mx.get_peak_memory() / 1e9
    return out
dia_mod.codebook_to_audio = timed

m = load_model("mlx-community/Dia-1.6B"); m.model.set_dtype(mx.bfloat16); quantize_dia(m.model, 4); mx.eval(m.parameters())
print(f"weights in memory: {mx.get_active_memory()/1e9:.2f} GB")
mx.random.seed(7); mx.reset_peak_memory(); stats["t0"] = time.time()
for r in m.generate(text=PASSAGES["story"]): pass
print({k: round(v, 2) for k, v in stats.items() if k != "t0"})
