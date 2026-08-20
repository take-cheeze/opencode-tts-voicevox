"""Post-export onnxsim pass: simplifies a .onnx graph in place, but only
keeps the result if it reproduces the pre-simplification graph's output
within tolerance on a representative input. Verified 2026-08-20 on
codec_decode.onnx: cuts session load time (~34%, fewer nodes to parse) for
free, does not change inference speed or memory (weights, >99% of file
size, are untouched by constant-folding/dead-node passes -- the win here is
strictly load time). Best-effort against quantized graphs: onnxsim's
dedup passes can't hash non-float32 tensors, so it just no-ops there rather
than failing (confirmed on the official 0.6B ONNX-INT4 build: -0.04%,
i.e. no measurable effect).
"""
import os
import shutil

import numpy as np
import onnx
import onnxruntime as ort
import onnxsim


def simplify_and_verify(path, feed, atol=1e-4):
    """Simplify the ONNX graph at `path` in place. `feed` is an
    onnxruntime input dict used to verify the simplified graph reproduces
    the pre-simplification graph's output; on any mismatch or onnxsim
    failure, the original file is left untouched and this just logs why.
    """
    data_path = path + ".data"
    backup, backup_data = path + ".presimplify", data_path + ".presimplify"

    orig_sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
    orig_out = orig_sess.run(None, feed)
    del orig_sess

    model = onnx.load(path, load_external_data=True)
    try:
        simplified, ok = onnxsim.simplify(model)
    except Exception as exc:
        print(f"onnxsim: {path}: simplify() raised {exc!r}, keeping original", flush=True)
        return
    if not ok:
        print(f"onnxsim: {path}: internal check failed, keeping original", flush=True)
        return

    shutil.copy2(path, backup)
    shutil.copy2(data_path, backup_data)
    # onnx's external-data writer opens `location` in append mode rather
    # than truncating it -- leaving the pre-existing (now-backed-up) file in
    # place doubles it, old content plus new. Must remove it first.
    os.remove(data_path)
    # `location` must be the real final filename -- save() embeds it in the
    # graph, so renaming the file afterward would leave a stale reference.
    onnx.save(simplified, path, save_as_external_data=True,
              location=os.path.basename(data_path))

    diffs = None
    try:
        sim_sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
        sim_out = sim_sess.run(None, feed)
        del sim_sess
        diffs = [float(np.abs(a - b).max()) for a, b in zip(orig_out, sim_out)]
    except Exception as exc:
        reason = f"simplified graph raised {exc!r}"

    if diffs is not None:
        reason = f"output diverged (max diff {max(diffs):.2e} > {atol:.0e})"
    if diffs is None or max(diffs) > atol:
        shutil.move(backup, path)
        shutil.move(backup_data, data_path)
        print(f"onnxsim: {path}: {reason} after simplification, reverted", flush=True)
        return

    before = os.path.getsize(backup) + os.path.getsize(backup_data)
    after = os.path.getsize(path) + os.path.getsize(data_path)
    os.remove(backup)
    os.remove(backup_data)
    print(f"onnxsim: {path}: simplified ({before/1e6:.1f}MB -> {after/1e6:.1f}MB), "
          f"max output diff {max(diffs):.2e} (kept)", flush=True)
