"""Voiceger (GPT-SoVITS) Zundamon TTS HTTP server.

Loads the Zundamon fine-tune once, then serves:
    POST /tts   {"text": "...", "text_language": "English|Japanese|Korean|..."}
                -> {"message": "ok", "file_path": "/abs/path.wav"}
    GET  /ping  -> {"ok": true, ...}

Paths are resolved from the environment (or auto-discovered):
    VOICEGER_SRC   voiceger_v2 repo root (contains GPT-SoVITS/, reference/)
                   (default: $HOME/dev/voiceger_v2)
The launcher run-voiceger-server.sh sets VOICEGER_SRC + a clean env.
"""
import os
import sys

HOME = os.path.expanduser("~")
VOICEGER_SRC = os.environ.get("VOICEGER_SRC", os.path.join(HOME, "dev", "voiceger_v2"))
GS = os.path.join(VOICEGER_SRC, "GPT-SoVITS")

for p in (GS, os.path.join(GS, "GPT_SoVITS")):
    if os.path.isdir(p) and p not in sys.path:
        sys.path.insert(0, p)

GPT = os.path.join(GS, "GPT_weights_v2/zudamon_style_1-e15.ckpt")
SOVITS = os.path.join(GS, "SoVITS_weights_v2/zudamon_style_1_e8_s96.pth")
BERT = os.environ.get("VOICEGER_BERT",
    os.path.join(GS, "GPT_SoVITS/pretrained_models/chinese-roberta-wwm-ext-large"))
CNHUBERT = os.environ.get("VOICEGER_CNHUBERT",
    os.path.join(GS, "GPT_SoVITS/pretrained_models/chinese-hubert-base"))
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

# Check the artefacts themselves, not just their parent directory -- a missing
# weight file used to surface much later as an opaque failure mid-inference.
for label, path, kind in [("GPT-SoVITS dir", GS, "dir"),
                          ("GPT weights", GPT, "file"),
                          ("SoVITS weights", SOVITS, "file"),
                          ("BERT", BERT, "dir"),
                          ("CNHuBERT", CNHUBERT, "dir"),
                          ("reference wav", REF, "file"),
                          ("reference text", REF_TEXT, "file")]:
    ok = os.path.isdir(path) if kind == "dir" else os.path.isfile(path)
    if not ok:
        raise SystemExit(f"voiceger: missing {label}: {path}\n"
                         f"  (set VOICEGER_SRC correctly / run setup-voiceger.sh)")

device = os.environ.get("VOICEGER_DEVICE", "cpu")  # cpu | cuda | mps (Apple GPU)
is_half = os.environ.get("VOICEGER_IS_HALF", "false").lower() == "true"

os.environ.setdefault("version", "v2")
os.environ["device"] = device
os.environ["is_half"] = str(is_half)
os.environ["bert_path"] = BERT
os.environ["cnhubert_base_path"] = CNHUBERT
os.environ["language"] = "Auto"
os.chdir(GS)  # TTS writes GPT_SoVITS/configs/ and uses relative fallbacks

import numpy as np          # noqa: E402
import soundfile as sf      # noqa: E402
import tempfile             # noqa: E402
from fastapi import FastAPI, HTTPException   # noqa: E402
from pydantic import BaseModel                 # noqa: E402
from TTS_infer_pack.TTS import TTS             # noqa: E402

print(f"Loading Zundamon TTS models (device={device}) ...", flush=True)
cfg = {
    "device": device, "is_half": is_half, "version": "v2",
    "t2s_weights_path": GPT, "vits_weights_path": SOVITS,
    "bert_base_path": BERT, "cnhuhbert_base_path": CNHUBERT,
}
tts = TTS(configs={"custom": cfg, "default": cfg})
with open(REF_TEXT, encoding="utf-8") as fh:
    REF_TEXT_STR = fh.read().strip()
print("TTS ready.", flush=True)

_LANG_TAG = {
    "English": "en", "Japanese": "all_ja", "Korean": "all_ko",
    "Cantonese": "all_yue", "Chinese": "all_zh",
    "Japanese-English Mixed": "ja", "Chinese-English Mixed": "zh",
    "Korean-English Mixed": "ko", "Cantonese-English Mixed": "yue",
    "Multilingual Mixed": "auto",
}

app = FastAPI(title="voiceger-tts", version="0.2.0")


class TtsRequest(BaseModel):
    text: str
    text_language: str = "English"
    top_k: int = 5
    top_p: float = 1.0
    temperature: float = 1.0


@app.get("/ping")
def ping():
    return {"ok": True, "voice": "zundamon", "device": device}


@app.post("/tts")
def tts_endpoint(req: TtsRequest):
    tag = _LANG_TAG.get(req.text_language, "en")
    if tag not in tts.configs.languages:
        raise HTTPException(400, f"unsupported text_language: {req.text_language}")
    fd, path = tempfile.mkstemp(suffix=".wav", prefix="voiceger-tts-")
    os.close(fd)
    sr = 32000
    try:
        for sr, wav in tts.run(inputs={
            "text": req.text, "text_lang": tag,
            "ref_audio_path": REF, "prompt_text": REF_TEXT_STR, "prompt_lang": "ja",
            "top_k": req.top_k, "top_p": req.top_p, "temperature": req.temperature,
            "speed_factor": 1.0, "return_fragment": False,
        }):
            audio = wav.astype(np.int16) if wav.dtype in (np.float32, np.float16) else wav
            sf.write(path, audio, sr, format="WAV", subtype="PCM_16")
        if os.path.getsize(path) == 0:
            raise HTTPException(500, "TTS produced no audio")
        return {"message": "ok", "file_path": path, "sampling_rate": int(sr)}
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(500, f"tts failed: {exc!r}")


if __name__ == "__main__":
    port = int(os.environ.get("VOICEGER_PORT", sys.argv[sys.argv.index("--port") + 1]
                              if "--port" in sys.argv else "18123"))
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
