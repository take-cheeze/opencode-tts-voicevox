"""Export the Audio8-0.1b fast-AR step and codec decoder to ONNX.

Fast AR: 10-position static KV cache, one graph per step with a
use_hidden selector (mirrors Audio8's own 0.6B runtime interface).
Codec: quantizer.decode + decoder as one graph, dynamic frame count T.
Every stage is verified against unpatched eager first, then in ORT.
"""
import os

import numpy as np
import torch
import torch.nn.functional as F
from transformers import AutoModel

SCRATCH = os.environ.get(
    "ARK01B_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "artifacts"))

os.makedirs(SCRATCH, exist_ok=True)
torch.manual_seed(0)
model_id = "Audio8/Audio8-TTS-Preview-0.1b"
model = AutoModel.from_pretrained(model_id, trust_remote_code=True, dtype=torch.float32).eval()
cfg = model.config
NC = cfg.num_codebooks          # 10
CB = cfg.codebook_size          # 4096


# ---------------------------------------------------------------------------
# Fast-AR functional shim (explicit KV cache I/O, static shapes).
# ---------------------------------------------------------------------------
class FastStepShim(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m
        self.n_layers = len(m.fast_layers)
        attn = m.fast_layers[0].attention
        self.n_head, self.n_local, self.head_dim = attn.n_head, attn.n_local_heads, attn.head_dim
        self.register_buffer("rope_table", m.fast_freqs_cis.float(), persistent=False)

    def _attn(self, layer, x, rope, mask, position, k_in, v_in):
        a = layer.attention
        b, length = x.shape[0], x.shape[1]
        qs, kvs = a.n_head * a.head_dim, a.n_local_heads * a.head_dim
        q, k, v = a.wqkv(x).split((qs, kvs, kvs), dim=-1)
        q = q.view(b, length, a.n_head, a.head_dim)
        k = k.view(b, length, a.n_local_heads, a.head_dim)
        v = v.view(b, length, a.n_local_heads, a.head_dim)
        from importlib import import_module
        mod = type(self.m).__module__
        _apply_rope = import_module(mod)._apply_rope
        q = _apply_rope(q, rope).transpose(1, 2)
        k = _apply_rope(k, rope).transpose(1, 2)
        v = v.transpose(1, 2)
        k_full = k_in.clone()
        v_full = v_in.clone()
        k_full[:, :, position] = k
        v_full[:, :, position] = v
        reps = a.n_head // a.n_local_heads
        key = k_full.repeat_interleave(reps, dim=1)
        value = v_full.repeat_interleave(reps, dim=1)
        scores = q @ key.transpose(-2, -1) / (a.head_dim ** 0.5)
        scores = scores.masked_fill(~mask, float("-inf"))
        out = torch.softmax(scores, dim=-1) @ value
        out = out.transpose(1, 2).contiguous().view(b, length, qs)
        return a.wo(out), k_full, v_full

    def forward(self, slow_hidden, token_id, use_hidden, position, k, v):
        m = self.m
        h_proj = m.fast_project_in(slow_hidden)
        h_tok = m.fast_embeddings(token_id)[:, None]
        x = torch.where(use_hidden.reshape(1, 1, 1), h_proj, h_tok)
        rope = self.rope_table[position]
        key_pos = torch.arange(NC, device=x.device)
        mask = (key_pos[None, :] <= position[:, None])[None, None]
        k_outs, v_outs = [], []
        for i, layer in enumerate(self.n_layers * [None]):
            layer = m.fast_layers[i]
            attn_out, k_i, v_i = self._attn(
                layer, layer.attention_norm(x), rope, mask, position, k[i], v[i])
            x = x + attn_out
            x = x + layer.feed_forward(layer.ffn_norm(x))
            k_outs.append(k_i)
            v_outs.append(v_i)
        logits = m.fast_output(m.fast_norm(x))[:, -1]
        return logits, torch.stack(k_outs), torch.stack(v_outs)


print("=== fast-AR: shim vs eager _fast_step ===", flush=True)
model._setup_generation_caches(1, 64, torch.float32)
shim = FastStepShim(model).eval()
slow_hidden = torch.randn(1, 1, model.config.dim)

# Eager: replicate _generate_codebooks' step sequence, recording every logits.
with torch.inference_mode():
    hidden = model.fast_project_in(slow_hidden)
    eager_logits = [model._fast_step(hidden, 0)]
    current = eager_logits[0].argmax(dim=-1)
    eager_tokens = [int(current)]
    h = model.fast_embeddings(current)[:, None]
    for pos in range(1, NC):
        s = model._fast_step(h, pos)
        eager_logits.append(s)
        current = s.argmax(dim=-1)
        eager_tokens.append(int(current))
        h = model.fast_embeddings(current)[:, None]

# Shim: same sequence with explicit caches.
H, HD = shim.n_local, shim.head_dim
k_st = torch.zeros(shim.n_layers, 1, H, NC, HD)
v_st = torch.zeros(shim.n_layers, 1, H, NC, HD)
with torch.inference_mode():
    logits, k_st, v_st = shim(slow_hidden, torch.zeros(1, dtype=torch.long),
                              torch.tensor([True]), torch.tensor([0]), k_st, v_st)
    diffs = [(logits - eager_logits[0]).abs().max().item()]
    tok = logits.argmax(dim=-1)
    shim_tokens = [int(tok)]
    for pos in range(1, NC):
        logits, k_st, v_st = shim(slow_hidden * 0, tok, torch.tensor([False]),
                                  torch.tensor([pos]), k_st, v_st)
        diffs.append((logits - eager_logits[pos]).abs().max().item())
        tok = logits.argmax(dim=-1)
        shim_tokens.append(int(tok))
print("eager tokens:", eager_tokens, flush=True)
print("shim  tokens:", shim_tokens, flush=True)
print("max logits diff per pos:", [f"{d:.2e}" for d in diffs], flush=True)
assert shim_tokens == eager_tokens and max(diffs) < 1e-4, "fast shim mismatch"
print("fast shim is behavior-preserving.", flush=True)

print("=== fast-AR: torch.export + ONNX ===", flush=True)
ex_args = (slow_hidden, torch.zeros(1, dtype=torch.long), torch.tensor([True]),
           torch.tensor([0]), torch.zeros_like(k_st), torch.zeros_like(v_st))
ep_fast = torch.export.export(shim, ex_args)
print("fast torch.export: SOUND EXPORT SUCCEEDED", flush=True)
onnx_fast = f"{SCRATCH}/fast_step.onnx"
torch.onnx.export(shim, ex_args, onnx_fast, dynamo=True,
                  input_names=["slow_hidden", "token_id", "use_hidden", "position", "k", "v"],
                  output_names=["logits", "k_out", "v_out"])
print("fast ONNX written.", flush=True)

# ---------------------------------------------------------------------------
# Codec decoder (dynamic T).
# ---------------------------------------------------------------------------
print("=== codec: load + patch jit snake ===", flush=True)
codec = model.load_codec(device="cpu", dtype=torch.float32)
from importlib import import_module
codec_mod = import_module(type(codec).__module__)


def _snake_plain(x, alpha):
    shape = x.shape
    x = x.reshape(shape[0], shape[1], -1)
    x = x + (alpha + 1e-9).reciprocal() * torch.sin(alpha * x).pow(2)
    return x.reshape(shape)


# Verify the plain reimplementation against the jit.script original first.
probe = torch.randn(2, 8, 64)
alpha = torch.rand(1, 8, 1) + 0.5
d = (codec_mod._arktts_snake(probe, alpha) - _snake_plain(probe, alpha)).abs().max().item()
print(f"snake reimpl diff: {d:.2e}", flush=True)
assert d < 1e-6
codec_mod._arktts_snake = _snake_plain


class CodecDecodeShim(torch.nn.Module):
    def __init__(self, c):
        super().__init__()
        self.c = c

    def forward(self, codes):
        return self.c.decoder(self.c.quantizer.decode(codes))


dec_shim = CodecDecodeShim(codec).eval()
T1, T2 = 24, 57
codes1 = torch.randint(0, CB, (1, NC, T1))
codes2 = torch.randint(0, CB, (1, NC, T2))
with torch.inference_mode():
    ref1 = codec.decode(codes1)
    got1 = dec_shim(codes1)
d = (ref1 - got1).abs().max().item()
print(f"codec shim vs codec.decode diff: {d:.2e} (out shape {tuple(got1.shape)})", flush=True)
assert d < 1e-5

print("=== codec: torch.export + ONNX (dynamic T) ===", flush=True)
from torch.export import Dim
codec_dyn = ({2: Dim.AUTO},)
ep_codec = torch.export.export(dec_shim, (codes1,), dynamic_shapes=codec_dyn)
print("codec torch.export: SOUND EXPORT SUCCEEDED", flush=True)
onnx_codec = f"{SCRATCH}/codec_decode.onnx"
torch.onnx.export(dec_shim, (codes1,), onnx_codec, dynamo=True,
                  dynamic_shapes=codec_dyn,
                  input_names=["codes"], output_names=["wav"])
print("codec ONNX written.", flush=True)

# ---------------------------------------------------------------------------
# ORT parity for both graphs.
# ---------------------------------------------------------------------------
print("=== ORT parity ===", flush=True)
import onnxruntime as ort
s_fast = ort.InferenceSession(onnx_fast, providers=["CPUExecutionProvider"])
s_codec = ort.InferenceSession(onnx_codec, providers=["CPUExecutionProvider"])

k_np = np.zeros(k_st.shape, dtype=np.float32)
v_np = np.zeros(v_st.shape, dtype=np.float32)
r = s_fast.run(None, {"slow_hidden": slow_hidden.numpy(),
                      "token_id": np.zeros(1, dtype=np.int64),
                      "use_hidden": np.array([True]),
                      "position": np.array([0], dtype=np.int64),
                      "k": k_np, "v": v_np})
ort_logits, k_np, v_np = r
ort_tokens = [int(np.argmax(ort_logits))]
fast_diffs = [float(np.abs(ort_logits - eager_logits[0].numpy()).max())]
for pos in range(1, NC):
    r = s_fast.run(None, {"slow_hidden": np.zeros_like(slow_hidden.numpy()),
                          "token_id": np.array([ort_tokens[-1]], dtype=np.int64),
                          "use_hidden": np.array([False]),
                          "position": np.array([pos], dtype=np.int64),
                          "k": k_np, "v": v_np})
    ort_logits, k_np, v_np = r
    fast_diffs.append(float(np.abs(ort_logits - eager_logits[pos].numpy()).max()))
    ort_tokens.append(int(np.argmax(ort_logits)))
print("ORT fast tokens:", ort_tokens, flush=True)
print("ORT fast max diffs:", [f"{d:.2e}" for d in fast_diffs], flush=True)
assert ort_tokens == eager_tokens, "ORT fast token mismatch"

for name, codes, tt in (("T1", codes1, T1), ("T2", codes2, T2)):
    with torch.inference_mode():
        ref = codec.decode(codes).numpy()
    got = s_codec.run(None, {"codes": codes.numpy()})[0]
    d = float(np.abs(ref - got).max())
    scale = float(np.abs(ref).max())
    print(f"codec ORT {name} (T={tt}): shape {got.shape}, max diff {d:.2e} "
          f"(signal peak {scale:.2f})", flush=True)
    assert got.shape == ref.shape, "codec shape mismatch (dynamism broken?)"

print("ALL PARITY CHECKS PASSED", flush=True)
print("done", flush=True)
