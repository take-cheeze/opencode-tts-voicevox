"""Voiceger Zundamon TTS HTTP server.

Loads a zero-shot voice-cloning TTS model once, then serves:
    POST /tts   {"text": "...", "text_language": "English|Japanese|..."}
                -> {"message": "ok", "file_path": "/abs/path.wav", "sampling_rate": int}
    GET  /ping  -> {"ok": true, ...}

VOICEGER_ENGINE selects the model:
    audio8      (default)  Audio8/Audio8-TTS-Preview-0.1b -- multilingual, CPU-viable
    audio8-onnx             Audio8-TTS-Preview-0.6B-ONNX-INT4 -- larger model, smaller
                            runtime footprint (official quantized build); needs
                            setup-voiceger.sh --with-audio8-onnx
    raon                    KRAFTON/Raon-OpenTTS-1B -- English-only, heavy, GPU-recommended

Both engines clone the Zundamon voice from a reference clip, resolved from the
environment (or auto-discovered):
    VOICEGER_SRC   tree containing reference/ (default: $HOME/dev/voiceger_v2)
The launcher run-voiceger-server.sh sets VOICEGER_SRC + a clean env.
"""
import os
import sys
import tempfile

HOME = os.path.expanduser("~")
VOICEGER_SRC = os.environ.get("VOICEGER_SRC", os.path.join(HOME, "dev", "voiceger_v2"))
ENGINE = os.environ.get("VOICEGER_ENGINE", "audio8").lower()


def _default_ref():
    """Pick the voice-cloning reference clip out of the voiceger tree.

    Upstream ships one wav per emotion (01_ref_emoNormal026.wav, ...) rather
    than a single reference.wav, and ref_text.txt is the transcript of the
    normal-emotion take -- which sorts first.
    """
    ref_dir = os.path.join(VOICEGER_SRC, "reference")
    named = os.path.join(ref_dir, "reference.wav")
    if os.path.isfile(named):
        return named
    wavs = sorted(f for f in os.listdir(ref_dir) if f.endswith(".wav")) \
        if os.path.isdir(ref_dir) else []
    return os.path.join(ref_dir, wavs[0]) if wavs else named


REF = os.environ.get("VOICEGER_REF") or _default_ref()
REF_TEXT = os.environ.get("VOICEGER_REF_TEXT",
    os.path.join(VOICEGER_SRC, "reference/ref_text.txt"))

for label, path in [("reference wav", REF), ("reference text", REF_TEXT)]:
    if not os.path.isfile(path):
        raise SystemExit(f"voiceger: missing {label}: {path}\n"
                         f"  (set VOICEGER_SRC to a voiceger_v2 checkout, or "
                         f"VOICEGER_REF/VOICEGER_REF_TEXT directly)")

with open(REF_TEXT, encoding="utf-8") as fh:
    REF_TEXT_STR = fh.read().strip()

device = os.environ.get("VOICEGER_DEVICE", "cpu")  # cpu | cuda | mps (Apple GPU)

import numpy as np          # noqa: E402
import soundfile as sf      # noqa: E402
from fastapi import FastAPI, HTTPException   # noqa: E402
from pydantic import BaseModel                 # noqa: E402


class Engine:
    """Common interface both engines implement."""

    name = "unknown"
    sample_rate = 0

    def synthesize(self, text, lang):
        raise NotImplementedError


class Audio8Engine(Engine):
    name = "audio8"

    _LANG_TAG = {
        "English": "en", "Chinese": "zh", "Japanese": "ja", "Korean": "ko",
        "German": "de", "Spanish": "es", "French": "fr", "Italian": "it",
    }

    def __init__(self):
        import torch
        from transformers import AutoModel, AutoProcessor

        model_id = os.environ.get("VOICEGER_AUDIO8_MODEL", "Audio8/Audio8-TTS-Preview-0.1b")
        dtype = torch.float16 if device == "cuda" else torch.float32
        print(f"Loading {model_id} (device={device}) ...", flush=True)
        self._processor = AutoProcessor.from_pretrained(model_id, trust_remote_code=True)
        self._model = (AutoModel.from_pretrained(model_id, trust_remote_code=True, dtype=dtype)
                       .eval().to(device))
        self.sample_rate = self._model.config.codec_sample_rate
        print("Audio8 TTS ready.", flush=True)

    def synthesize(self, text, lang):
        inputs = self._processor(text=[text], reference_audio=[REF],
                                 reference_text=[REF_TEXT_STR], return_tensors="pt").to(device)
        output = self._model.generate(
            **inputs, max_new_tokens=1024, temperature=0.7, top_p=0.9,
            top_k=50, do_sample=True, return_dict_in_generate=True)
        waveforms, lengths = self._model.decode_audio(output.codes)
        wav = waveforms[0]
        if lengths is not None:
            wav = wav[..., : int(lengths[0])]
        return wav.detach().to("cpu").float().numpy().squeeze()


class Audio8OnnxEngine(Engine):
    """Audio8-TTS-Preview-0.6B-ONNX-INT4 via the official arktts_runtime.

    Larger model than the default `audio8` engine but a much smaller runtime
    footprint (~1GB vs ~1.4-5GB) since it's INT4-quantized ONNX, not PyTorch.
    Needs `setup-voiceger.sh --with-audio8-onnx` to clone
    github.com/Audio8-AI/Audio8_TTS and download the model.

    Unlike the other engines, this one registers a named "voice profile"
    once (from the same REF/REF_TEXT clip) instead of taking reference audio
    per request -- registration runs once at startup here so per-request
    latency matches the others.
    """

    name = "audio8-onnx"
    sample_rate = 44100

    def __init__(self):
        onnx_src = os.environ.get("VOICEGER_ONNX_SRC", os.path.join(HOME, "dev", "Audio8_TTS"))
        runtime_dir = os.path.join(onnx_src, "onnx_runtime")
        if runtime_dir not in sys.path:
            sys.path.insert(0, runtime_dir)
        model_dir = os.environ.get("VOICEGER_ONNX_MODEL_DIR", os.path.join(runtime_dir, "model"))
        voices_dir = os.environ.get("VOICEGER_ONNX_VOICES_DIR", os.path.join(runtime_dir, "voices"))
        threads = int(os.environ.get("VOICEGER_ONNX_THREADS", "5"))
        self._voice = os.environ.get("VOICEGER_ONNX_VOICE", "zundamon")

        from arktts_runtime.registration import VoiceRegistration
        from arktts_runtime.runtime import ArkTtsRuntime

        print(f"Loading Audio8 ONNX runtime from {model_dir} ...", flush=True)
        self._runtime = ArkTtsRuntime(model_dir, voices_dir, threads=threads)
        # Registers every start-up (overwrite=True) so this stays in sync with
        # whatever REF/REF_TEXT point at, the same way the other engines take
        # reference audio fresh on every request.
        from pathlib import Path

        registration = VoiceRegistration(
            Path(model_dir) / "registration",
            self._runtime.voices.root,
            str(self._runtime.manifest["model_fingerprint"]),
        )
        with open(REF, "rb") as fh:
            ref_bytes = fh.read()
        registration.register(ref_bytes, os.path.basename(REF), REF_TEXT_STR, self._voice, overwrite=True)
        self.sample_rate = int(self._runtime.manifest["sample_rate"])
        print("Audio8 ONNX runtime ready.", flush=True)

    def synthesize(self, text, lang):
        import random

        audio, _codes = self._runtime.synthesize(
            text=text, voice=self._voice, max_new_tokens=1024,
            temperature=0.7, top_p=0.9, top_k=50,
            seed=random.randint(0, 2**31 - 1),
        )
        return audio


class RaonEngine(Engine):
    """English-only F5-TTS-based model. Heavy (16.7GB checkpoint) and
    unverified for CPU throughput -- opt in with VOICEGER_ENGINE=raon on a
    box that ran `setup-voiceger.sh --with-raon`."""

    name = "raon"
    sample_rate = 16000

    def __init__(self):
        from f5_tts.infer.utils_infer import load_model, load_vocoder
        from f5_tts.model import DiT

        model_id = os.environ.get("VOICEGER_RAON_MODEL", "KRAFTON/Raon-OpenTTS-1B")
        vocoder_id = os.environ.get("VOICEGER_RAON_VOCODER", "speechbrain/tts-hifigan-libritts-16kHz")
        print(f"Loading {model_id} (device={device}) ...", flush=True)
        # F5-TTS "Base" hyperparameters -- Raon's model card does not publish
        # its DiT config, so this assumes the standard F5-TTS-Base shape and
        # will fail loudly (state_dict mismatch) on load if that's wrong.
        model_cfg = dict(dim=1024, depth=22, heads=16, ff_mult=2, text_dim=512, conv_layers=4)
        self._vocoder = load_vocoder(vocoder_name="vocos", is_local=False, local_path=vocoder_id)
        self._model = load_model(DiT, model_cfg, model_id, device=device)
        self._infer_process = __import__(
            "f5_tts.infer.utils_infer", fromlist=["infer_process"]).infer_process
        print("Raon TTS ready.", flush=True)

    def synthesize(self, text, lang):
        if lang != "English":
            raise HTTPException(400, f"raon engine is English-only, got: {lang}")
        wav, sr, _ = self._infer_process(REF, REF_TEXT_STR, text, self._model, self._vocoder)
        self.sample_rate = sr
        return np.asarray(wav)


_ENGINES = {"audio8": Audio8Engine, "audio8-onnx": Audio8OnnxEngine, "raon": RaonEngine}
if ENGINE not in _ENGINES:
    raise SystemExit(f"voiceger: unknown VOICEGER_ENGINE {ENGINE!r} (want: {', '.join(_ENGINES)})")
engine = _ENGINES[ENGINE]()

app = FastAPI(title="voiceger-tts", version="0.3.0")


class TtsRequest(BaseModel):
    text: str
    text_language: str = "English"


@app.get("/ping")
def ping():
    return {"ok": True, "voice": "zundamon", "engine": engine.name, "device": device}


@app.post("/tts")
def tts_endpoint(req: TtsRequest):
    fd, path = tempfile.mkstemp(suffix=".wav", prefix="voiceger-tts-")
    os.close(fd)
    try:
        audio = engine.synthesize(req.text, req.text_language)
        sf.write(path, audio, engine.sample_rate, format="WAV", subtype="PCM_16")
        if os.path.getsize(path) == 0:
            raise HTTPException(500, "TTS produced no audio")
        return {"message": "ok", "file_path": path, "sampling_rate": int(engine.sample_rate)}
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(500, f"tts failed: {exc!r}")


if __name__ == "__main__":
    port = int(os.environ.get("VOICEGER_PORT", sys.argv[sys.argv.index("--port") + 1]
                              if "--port" in sys.argv else "18123"))
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
