"""Post-export weight-only INT8 quantization: MatMulNBits (bits=8,
accuracy_level=4), verified against the pre-quantization output before being
kept -- reverts to the original file on any mismatch, same safety contract
as simplify_onnx.py.

Why weight-only INT8, not dynamic INT8 (onnxruntime.quantization.
quantize_dynamic) or weight-only INT4: matches the *technique* Audio8's own
official 0.6B ONNX-INT4 build uses (MatMulNBits weight-only quantization,
fp16 activations) but at 8 not 4 bits. INT4 (both RTN and HQQ, tried
2026-08-20) broke greedy-decode correctness outright -- logit diffs of
15-30+ compounding across autoregressive steps. Dynamic INT8 (which also
quantizes activations, not just weights) broke it almost as badly. Weight-
only INT8 did not: fast_step.onnx got an exact 10/10-step token match and
is actually 3x *faster* (accuracy_level=4 picks a different, faster CPU
kernel path); slow_prefill.onnx's argmax matched fp32 exactly on the real
prompt; slow_decode.onnx matched 4/5 greedy steps on real prefill-derived
cache, and the one miss was confirmed inconsequential (KL divergence 0.027
nats, Monte Carlo sampling under temperature=0.7 -- the model's real
generation mode, not greedy argmax) since it was already a near-tied
decision under fp32 (6.16% vs 5.78%).

ATOL (3.0) sits just above every logit diff actually observed across all
three graphs' verification runs that night (worst: 2.3, at the one
slow_decode divergence). This is a single-feed sanity check, same shape as
simplify_onnx.py's, not a full distributional guarantee -- the KL/sampling
analysis above is what actually justifies trusting a diff in this range.

codec_decode.onnx is deliberately NOT a candidate here: every INT8/INT4
attempt on it either crashed (ConvInteger has no CPU kernel in this ONNX
Runtime build) or produced audibly bad output (10.5% RMS error). It stays
fp32 (or fp16 via a separate, not-yet-done conversion), matching Audio8's
own choice for their codec.
"""
import os
import shutil

import numpy as np
import onnx
import onnxruntime as ort
from onnxruntime.quantization.matmul_nbits_quantizer import (
    DefaultWeightOnlyQuantConfig,
    MatMulNBitsQuantizer,
)

ATOL = 3.0  # see module docstring


def quantize_int8_and_verify(path, feed, atol=ATOL):
    """Weight-only INT8-quantize the ONNX graph at `path` in place. `feed`
    is an onnxruntime input dict used to verify the quantized graph's
    output stays within `atol` of the pre-quantization one; on any
    mismatch or quantizer failure, the original file is left untouched.
    """
    data_path = path + ".data"
    backup, backup_data = path + ".prequant", data_path + ".prequant"

    orig_sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
    orig_out = orig_sess.run(None, feed)
    del orig_sess

    model = onnx.load(path, load_external_data=True)
    try:
        cfg = DefaultWeightOnlyQuantConfig(block_size=128, is_symmetric=False,
                                           bits=8, accuracy_level=4)
        quantizer = MatMulNBitsQuantizer(model, algo_config=cfg)
        quantizer.process()
        quantized = quantizer.model.model
    except Exception as exc:
        print(f"quantize_int8: {path}: quantization raised {exc!r}, "
              f"keeping original", flush=True)
        return

    shutil.copy2(path, backup)
    shutil.copy2(data_path, backup_data)
    # onnx's external-data writer appends to `location` rather than
    # truncating it -- must remove the pre-existing file first (see
    # simplify_onnx.py, same gotcha, found and fixed 2026-08-20).
    os.remove(data_path)
    onnx.save(quantized, path, save_as_external_data=True,
              location=os.path.basename(data_path))

    diffs = None
    try:
        q_sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
        q_out = q_sess.run(None, feed)
        del q_sess
        diffs = [float(np.abs(a - b).max()) for a, b in zip(orig_out, q_out)]
    except Exception as exc:
        reason = f"quantized graph raised {exc!r}"

    if diffs is not None:
        reason = f"output diverged (max diff {max(diffs):.3f} > {atol:.1f})"
    if diffs is None or max(diffs) > atol:
        shutil.move(backup, path)
        shutil.move(backup_data, data_path)
        print(f"quantize_int8: {path}: {reason} after quantization, "
              f"reverted", flush=True)
        return

    before = os.path.getsize(backup) + os.path.getsize(backup_data)
    after = os.path.getsize(path) + os.path.getsize(data_path)
    os.remove(backup)
    os.remove(backup_data)
    print(f"quantize_int8: {path}: quantized ({before/1e6:.1f}MB -> "
          f"{after/1e6:.1f}MB), max output diff {max(diffs):.3f} (kept)",
          flush=True)
