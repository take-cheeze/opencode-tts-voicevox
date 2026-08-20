# Audio8-TTS-Preview-0.1b → ONNX (experimental)

A from-scratch ONNX export of the `audio8` engine's model, plus a
PyTorch-free runtime driver. Verified token-exact against the original
PyTorch model, but not wired into `tts_server.py` as an engine yet —
treat it as tooling, not a deployment path.

## Why this exists

The stock `transformers` Falcon-H1 backbone cannot be exported as one
graph: `FalconH1Mixer.torch_forward`'s `use_precomputed_states` branch
(prefill vs incremental decode) is data-dependent Python control flow that
`torch.export` correctly refuses to bake in, and the hybrid Mamba+attention
cache lives in Python objects the tracer captures as constants. The fix
mirrors Audio8's own 0.6B ONNX design: **two specialized graphs** (prefill
and decode) with the branch constant-folded per graph, and the cache passed
as **explicit stacked tensors**.

## Files

| Script | Produces |
|---|---|
| `export_slow.py` | `slow_prefill.onnx`, `slow_decode.onnx` (Falcon-H1 slow AR; ~510 MB each, fp32) |
| `export_fast_codec.py` | `fast_step.onnx` (fast AR, static 10-slot KV cache), `codec_decode.onnx` (dynamic frame count) |
| `ort_driver.py` | torch-free synthesis: prompt template, RAS/top-k/top-p sampling, chunked codec decode |

Artifacts land in `$ARK01B_DIR` (default: `artifacts/` next to the
scripts; gitignored — ~1.7 GB total). Run the two export scripts in the
voiceger venv (needs torch + transformers + onnx), then:

```sh
python ort_driver.py --register   # one-time: reference wav -> ref_codes.npy (uses torch)
python ort_driver.py --verify     # greedy token parity vs PyTorch generate()
python ort_driver.py              # sampled EN+JA synthesis -> wav (torch-free)
```

`--register` reads `VOICEGER_REF` / `VOICEGER_REF_TEXT` (same defaults as
`tts_server.py`).

## Verified (M4 Mac mini, 2026-08)

- Patched-eager vs unpatched-eager: **exactly 0.0 diff** (logits + all
  cache states, both graphs); prompt builder **byte-exact** vs the HF
  processor; 40 frames of greedy generation **token-exact** across all 10
  codebooks vs `model.generate()`.
- Memory: all 4 sessions ~1.7 GB loaded; AR loop ~2 GB RSS **flat**
  (vs the PyTorch engine's 3.5–5.1 GB growing peak); full codec decode is
  the peak driver (2.9–3.8 GB) — `decode_wav_chunked` bounds it by window
  size instead of utterance length (the codec's windowed-causal
  transformers make bounded-context decode approximate: rms diff ~4e-3;
  seams are crossfaded).
- Speed: ~9.6 s generation for 10.7 s of audio, ~12 ms/decode step;
  codec ~6 s (CPU) / ~3.8 s (WebGPU via the `onnxruntime-webgpu` wheel,
  `Pipeline(codec_provider="webgpu")`). AR graphs are ~2× *faster on CPU*
  than WebGPU or PyTorch-MPS; CoreML EP fails to load these graphs at all.

## Gotchas baked into the code

- The checkpoint's `config.json` overrides the modeling defaults:
  `vocab_size=69633`, `semantic_begin_id=65537`, `eos_token_id=228` — do
  not trust `configuration_arktts.py`'s signature values.
- The processor tokenizes each chat-template part **separately** and
  concatenates; replicating it any other way breaks prompt parity.
- Export needs `_attn_implementation = "eager"` — irrelevant to the final
  graphs' correctness, but the exporter path is what was verified.
- Remaining known optimizations, not done: INT4/INT8 quantization, weight
  dedup between the two slow graphs, fp16 codec.

## Post-export: onnxsim

Each export script runs `onnxsim` on its outputs after parity verification
passes (`simplify_onnx.py`), reverting to the unsimplified graph if the
simplified one doesn't reproduce the same output on a representative input.
Measured on `codec_decode.onnx` (2026-08-20): cuts session load time ~34%
(fewer nodes to parse, 1,339 → 1,132), no measurable effect on inference
speed or memory -- weights are ~99% of file size and constant-folding
passes don't touch them. Worth keeping for that load-time win; don't expect
it to move steady-state synthesis speed or RAM.
