"""Torch-free Audio8-0.1b TTS pipeline on ONNX Runtime.

Graphs: slow_prefill / slow_decode / fast_step / codec_decode in $ARK01B_DIR
(default: ./artifacts next to this file), produced by export_slow.py and
export_fast_codec.py.
Modes:
  --register  one-time: encode reference wav -> ref_codes.npy (uses PyTorch)
  --verify    greedy token parity vs PyTorch generate(do_sample=False)
  (default)   sampled synthesis of EN+JA test sentences -> wav files
"""
import argparse
import json
import os
import resource
import subprocess
import time
from pathlib import Path

import numpy as np

SCRATCH = Path(os.environ.get(
    "ARK01B_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "artifacts")))
MODEL_ID = "Audio8/Audio8-TTS-Preview-0.1b"
REF_WAV = os.environ.get("VOICEGER_REF",
    os.path.expanduser("~/dev/voiceger_v2/reference/reference.wav"))
REF_TEXT_FILE = os.environ.get("VOICEGER_REF_TEXT",
    os.path.expanduser("~/dev/voiceger_v2/reference/ref_text.txt"))


def rss_mb():
    out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(os.getpid())])
    return int(out.strip()) / 1024


def peak_mb():
    v = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return v / (1024 * 1024) if os.uname().sysname == "Darwin" else v / 1024


def hf_snapshot_dir():
    base = Path(os.path.expanduser(
        "~/.cache/huggingface/hub/models--Audio8--Audio8-TTS-Preview-0.1b/snapshots"))
    return sorted(base.iterdir())[0]


class Pipeline:
    """numpy + tokenizers + onnxruntime only -- no PyTorch."""

    def __init__(self, codec_provider="cpu"):
        """codec_provider: "cpu" (default) or "webgpu".

        Measured on the M4 Mac mini: the AR graphs are ~2x FASTER on CPU
        (tiny sequential kernels, GPU dispatch overhead dominates), but the
        codec convnet is ~1.5x faster on WebGPU (5.8s -> 3.8s for ~11s of
        audio). "webgpu" needs the onnxruntime-webgpu wheel; falls back to
        CPU via the provider list if the EP is unavailable.
        """
        import onnxruntime as ort
        from tokenizers import Tokenizer

        snap = hf_snapshot_dir()
        self.cfg = json.loads((snap / "config.json").read_text())
        self.tok = Tokenizer.from_file(str(snap / "tokenizer.json"))
        self.nc = self.cfg["num_codebooks"]
        self.cb = self.cfg["codebook_size"]
        self.sem_begin = self.cfg["semantic_begin_id"]
        self.eos_token = self.cfg["eos_token_id"]
        self.ras_window = self.cfg.get("ras_window_size", 10)
        self.ras_top_p = self.cfg.get("ras_top_p", 0.9)
        self.ras_temp = self.cfg.get("ras_temperature", 1.0)
        self.sr = self.cfg.get("codec_sample_rate", 44100)
        self.n_layers = 24
        opts = ort.SessionOptions()
        opts.log_severity_level = 3
        provider = ["CPUExecutionProvider"]
        codec_prov = (["WebGpuExecutionProvider", "CPUExecutionProvider"]
                      if codec_provider == "webgpu" else provider)
        self.s_pre = ort.InferenceSession(str(SCRATCH / "slow_prefill.onnx"), opts, providers=provider)
        self.s_dec = ort.InferenceSession(str(SCRATCH / "slow_decode.onnx"), opts, providers=provider)
        self.s_fast = ort.InferenceSession(str(SCRATCH / "fast_step.onnx"), opts, providers=provider)
        self.s_codec = ort.InferenceSession(str(SCRATCH / "codec_decode.onnx"), opts, providers=codec_prov)
        kshape = self.s_fast.get_inputs()[4].shape  # [4,1,H,10,hd]
        self.fast_shape = tuple(kshape)

    # -- prompt ---------------------------------------------------------------
    def _enc(self, text):
        return self.tok.encode(text, add_special_tokens=False).ids

    def build_prompt(self, text, ref_text, ref_codes):
        target = " ".join(text.strip().split())
        ref_clean = " ".join(ref_text.strip().split())
        if "<|speaker:" not in ref_clean:
            ref_clean = f"<|speaker:0|>{ref_clean}"
        prefix = sum([self._enc(p) for p in (
            "<|im_start|>system\n",
            "convert the provided text to speech reference to the following:\n\nText:\n",
            ref_clean,
            "\n\nSpeech:\n")], [])
        suffix = sum([self._enc(p) for p in (
            "<|im_end|>\n",
            "<|im_start|>user\n",
            target,
            "<|im_end|>\n",
            "<|im_start|>assistant\n<|voice|>")], [])
        T = ref_codes.shape[1]
        row0 = np.concatenate([prefix, ref_codes[0] + self.sem_begin, suffix]).astype(np.int64)
        L = row0.size
        prompt = np.zeros((1, self.nc + 1, L), dtype=np.int64)
        prompt[0, 0] = row0
        prompt[0, 1:, len(prefix):len(prefix) + T] = ref_codes
        return prompt

    # -- sampling -------------------------------------------------------------
    @staticmethod
    def _topk_topp(scores, top_k, top_p, temperature):
        s = scores.astype(np.float64).copy()
        order = np.argsort(-s)
        probs = np.exp(s[order] - s[order].max())
        probs /= probs.sum()
        remove = (np.cumsum(probs) > top_p) | (np.arange(s.size) >= top_k)
        remove[0] = False
        s[order[remove]] = -np.inf
        return s / max(temperature, 1e-5)

    @staticmethod
    def _gumbel_pick(scores, rng):
        p = np.exp(scores - np.nanmax(scores[np.isfinite(scores)]))
        p[~np.isfinite(scores)] = 0.0
        p /= p.sum()
        noise = -np.log(np.clip(rng.random(p.size), 1e-12, 1.0))
        return int(np.argmax(p / noise))

    def sample_semantic(self, logits, previous, rng, top_k, top_p, temperature, greedy):
        s = logits.reshape(-1)
        regular = self._topk_topp(s, top_k, top_p, temperature)
        if greedy:
            return int(np.argmax(regular))
        normal = self._gumbel_pick(regular, rng)
        high = self._gumbel_pick(self._topk_topp(s, top_k, self.ras_top_p, self.ras_temp), rng)
        if previous is not None and normal in previous and normal < self.cb:
            return high
        return normal

    # -- generation -----------------------------------------------------------
    def generate(self, prompt, max_new_tokens=512, top_k=50, top_p=0.9,
                 temperature=0.7, seed=None, greedy=False, log=None):
        rng = np.random.default_rng(seed)
        P = prompt.shape[-1]
        conv = np.zeros((self.n_layers, 1, 896, 4), dtype=np.float32)
        ssm = np.zeros((self.n_layers, 1, 24, 32, 64), dtype=np.float32)
        r = self.s_pre.run(None, {"input_ids": prompt,
                                  "attention_mask": np.ones((1, P), dtype=np.int64),
                                  "conv": conv, "ssm": ssm})
        logits, hidden, conv, ssm, k, v = r
        frames, previous = [], None
        eos_idx = self.cb
        for step in range(max_new_tokens):
            semantic = self.sample_semantic(logits, previous, rng,
                                            top_k, top_p, temperature, greedy)
            if semantic == eos_idx:
                break
            codebooks = self._fast_codebooks(hidden, semantic, rng,
                                             top_k, top_p, temperature, greedy)
            frames.append(codebooks)
            if previous is None:
                previous = np.zeros(self.ras_window, dtype=np.int64)
            else:
                previous = np.roll(previous, -1)
            previous[-1] = semantic
            col = np.zeros((1, self.nc + 1, 1), dtype=np.int64)
            col[0, 0, 0] = semantic + self.sem_begin
            col[0, 1:, 0] = codebooks
            r = self.s_dec.run(None, {
                "input_ids": col,
                "cache_position": np.array([P + step], dtype=np.int64),
                "attention_mask": np.ones((1, P + step + 1), dtype=np.int64),
                "conv": conv, "ssm": ssm, "k": k, "v": v})
            logits, hidden, conv, ssm, k, v = r
            if log and (step + 1) % 50 == 0:
                log(f"  step {step+1}: rss={rss_mb():.0f}MB")
        if not frames:
            return np.zeros((self.nc, 0), dtype=np.int64)
        return np.stack(frames, axis=1)

    def _fast_codebooks(self, hidden, semantic, rng, top_k, top_p, temperature, greedy):
        kf = np.zeros(self.fast_shape, dtype=np.float32)
        vf = np.zeros(self.fast_shape, dtype=np.float32)
        _, kf, vf = self.s_fast.run(None, {
            "slow_hidden": hidden, "token_id": np.zeros(1, dtype=np.int64),
            "use_hidden": np.array([True]), "position": np.array([0], dtype=np.int64),
            "k": kf, "v": vf})
        current = int(np.clip(semantic, 0, self.cb - 1))
        out = [current]
        zero_h = np.zeros_like(hidden)
        for pos in range(1, self.nc):
            logits, kf, vf = self.s_fast.run(None, {
                "slow_hidden": zero_h, "token_id": np.array([current], dtype=np.int64),
                "use_hidden": np.array([False]), "position": np.array([pos], dtype=np.int64),
                "k": kf, "v": vf})
            s = self._topk_topp(logits.reshape(-1), top_k, top_p, temperature)
            current = int(np.argmax(s)) if greedy else self._gumbel_pick(s, rng)
            out.append(current)
        return np.array(out, dtype=np.int64)

    def decode_wav(self, codes):
        wav = self.s_codec.run(None, {"codes": codes[None]})[0]
        return wav[0, 0]

    def decode_wav_chunked(self, codes, chunk=48, context=128):
        """Windowed codec decode: bounded peak memory, causal-identical output.

        The codec stack is causal (causal convs + windowed causal attention),
        so decoding [start-context : start+chunk] and keeping only the last
        chunk*hop samples reproduces the full-sequence result given enough
        left context -- the same design Audio8's own runtime streams with.
        """
        T = codes.shape[1]
        hop = 2048  # samples per code frame (frame_length)
        fade = 256  # crossfade at chunk seams to guard against boundary clicks
        out = None
        for start in range(0, T, chunk):
            win_start = max(0, start - context)
            window = codes[:, win_start:start + chunk]
            wav = self.s_codec.run(None, {"codes": window[None]})[0][0, 0]
            piece = wav[(start - win_start) * hop:]
            if out is None:
                out = piece
            else:
                ramp = np.linspace(0.0, 1.0, fade, dtype=np.float32)
                head = wav[(start - win_start) * hop - fade:(start - win_start) * hop]
                out[-fade:] = out[-fade:] * (1 - ramp) + head * ramp
                out = np.concatenate([out, piece])
        return out


def do_register():
    import soundfile as sf
    import torch
    from transformers import AutoModel
    model = AutoModel.from_pretrained(MODEL_ID, trust_remote_code=True,
                                      dtype=torch.float32).eval()
    audio, sr = sf.read(REF_WAV, dtype="float32", always_2d=True)
    audio = audio.mean(axis=1)
    if sr != 44100:
        from torchaudio.functional import resample
        audio = resample(torch.from_numpy(audio), sr, 44100).numpy()
    wav = torch.from_numpy(audio)[None, None]
    codes, lengths = model.encode_audio(wav)
    T = int(lengths[0])
    np.save(SCRATCH / "ref_codes.npy", codes[0, :, :T].numpy().astype(np.int64))
    print(f"registered: ref_codes.npy shape {(codes.shape[1], T)}", flush=True)


def do_verify():
    import torch
    from transformers import AutoModel, AutoProcessor
    ref_codes = np.load(SCRATCH / "ref_codes.npy")
    ref_text = Path(REF_TEXT_FILE).read_text().strip()
    text = "Hello there, this is a parity test."
    pipe = Pipeline()
    prompt = pipe.build_prompt(text, ref_text, ref_codes)

    processor = AutoProcessor.from_pretrained(MODEL_ID, trust_remote_code=True)
    model = AutoModel.from_pretrained(MODEL_ID, trust_remote_code=True,
                                      dtype=torch.float32).eval()
    model.slow.config._attn_implementation = "eager"
    inputs = processor(text=[text], reference_codes=[torch.from_numpy(ref_codes)],
                       reference_text=[ref_text], return_tensors="pt")
    ref_prompt, _mask = model._prepare_prompt(
        prefix_input_ids=inputs["prefix_input_ids"],
        prefix_attention_mask=inputs["prefix_attention_mask"],
        suffix_input_ids=inputs["suffix_input_ids"],
        suffix_attention_mask=inputs["suffix_attention_mask"],
        reference_codes=inputs["reference_codes"],
        reference_code_lengths=inputs["reference_code_lengths"])
    same_prompt = ref_prompt.numpy().shape == prompt.shape and bool(
        (ref_prompt.numpy() == prompt).all())
    print(f"prompt parity: shapes {ref_prompt.shape} vs {prompt.shape}, equal={same_prompt}",
          flush=True)
    assert same_prompt, "prompt build mismatch"

    with torch.inference_mode():
        torch_codes = model.generate(
            prefix_input_ids=inputs["prefix_input_ids"],
            prefix_attention_mask=inputs["prefix_attention_mask"],
            suffix_input_ids=inputs["suffix_input_ids"],
            suffix_attention_mask=inputs["suffix_attention_mask"],
            reference_codes=inputs["reference_codes"],
            reference_code_lengths=inputs["reference_code_lengths"],
            max_new_tokens=40, do_sample=False)
    ours = pipe.generate(prompt, max_new_tokens=40, greedy=True)
    t = torch_codes[0].numpy()
    n = min(t.shape[1], ours.shape[1])
    equal = bool((t[:, :n] == ours[:, :n]).all()) and t.shape[1] == ours.shape[1]
    print(f"greedy codes: torch {t.shape} vs ours {ours.shape}; "
          f"first-{n}-frames equal={bool((t[:, :n] == ours[:, :n]).all())}", flush=True)
    print("PARITY OK" if equal else "PARITY MISMATCH", flush=True)


def do_synthesize():
    import soundfile as sf
    print(f"[start] rss={rss_mb():.0f}MB", flush=True)
    t0 = time.time()
    pipe = Pipeline()
    print(f"[sessions loaded {time.time()-t0:.1f}s] rss={rss_mb():.0f}MB", flush=True)
    ref_codes = np.load(SCRATCH / "ref_codes.npy")
    ref_text = Path(REF_TEXT_FILE).read_text().strip()
    cases = [
        ("en", "Hello there! This is the fully ONNX version of Audio8, "
               "running without PyTorch, cloned to sound like Zundamon."),
        ("ja", "こんにちは、ずんだもんなのだ。これはONNXだけで動くAudio8のテストなのだ。"),
    ]
    for name, text in cases:
        t0 = time.time()
        prompt = pipe.build_prompt(text, ref_text, ref_codes)
        codes = pipe.generate(prompt, max_new_tokens=512, seed=1234,
                              log=lambda m: print(m, flush=True))
        t_gen = time.time() - t0
        t0 = time.time()
        wav = pipe.decode_wav(codes)
        t_dec = time.time() - t0
        out = SCRATCH / f"audio8_full_onnx_{name}.wav"
        sf.write(str(out), wav, pipe.sr)
        print(f"[{name}] frames={codes.shape[1]} gen={t_gen:.1f}s codec={t_dec:.1f}s "
              f"audio={wav.size/pipe.sr:.1f}s peak={peak_mb():.0f}MB rss={rss_mb():.0f}MB "
              f"-> {out.name}", flush=True)
    print(f"[final] peak={peak_mb():.0f}MB", flush=True)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--register", action="store_true")
    ap.add_argument("--verify", action="store_true")
    args = ap.parse_args()
    if args.register:
        do_register()
    elif args.verify:
        do_verify()
    else:
        do_synthesize()
