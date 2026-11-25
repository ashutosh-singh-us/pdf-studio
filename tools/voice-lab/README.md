# Voice lab

Offline tests of open-source voice models for PDF Studio's planned read-aloud ("orator") mode.
They run on a Mac with MLX, Apple's on-device ML framework, which is also what an iPhone version would use.

```sh
/opt/homebrew/bin/python3.13 -m venv .venv
.venv/bin/pip install mlx-audio soundfile mlx-whisper     # all MIT; ffmpeg via brew for Whisper
.venv/bin/python bench.py mlx-community/Dia-1.6B dia-q4 4  # speed + memory, writes out/*.wav
.venv/bin/python profile_dia.py                            # generation vs audio-decoding split
.venv/bin/python intelligibility.py                        # Whisper word error rate per clip
```

## Dia 1.6B (Nari Labs, Apache-2.0), Apple M4 / 16 GB, 2026-11-22

| Precision | Speed (audio s per compute s) | Peak memory |
|---|---|---|
| float32 (as published by mlx-community) | 0.16x | 16.6 GB (swapping) |
| bf16 | 0.22x | 13.1 GB |
| 8-bit | 0.43x | 8.1 GB |
| 4-bit | 0.60x | 7.2 GB |

- `mlx.nn.quantize` skips Dia: its layers are `DenseGeneral`, not `nn.Linear`. `dia_quant.py` quantizes
  them (253 layers).
- At 4-bit: weights 1.24 GB; token generation peaks at 2.2 GB and takes 88% of the time. The 8 GB peak
  comes from decoding the whole clip with the DAC codec at once; decoding in short windows fixes that.
- Quality: 4-bit and 8-bit transcribe word-perfect with Whisper (the remaining "errors" are number
  formatting, like "$100" vs "one hundred dollars").
- Estimated on an iPhone 16 Pro (GPU about half an M4's, with thermal limits): about 0.25-0.3x real time,
  so chapters must be generated ahead of listening rather than live.

## Orpheus 3B (Canopy Labs, Apache-2.0 code; weights fine-tuned from Llama 3.2 3B, Llama 3.2 Community License)

`orpheus_bench.py` uses `mlx-community/orpheus-3b-0.1-ft-4bit` (already quantized). It renders one named voice per line
(narrator `leo`, characters `tara` and `dan`), so each character keeps the same voice on every run.

| Precision | Speed | Peak memory |
|---|---|---|
| 4-bit | 0.56-0.57x | 3.5 GB |

- Whisper transcript: word-perfect except "soot" heard as "sip" (numbers come back as "$100" and "10%").
- About the same speed as Dia at 4-bit, with half the memory and no separate decode spike (SNAC decodes as it goes).
