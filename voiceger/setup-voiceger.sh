#!/usr/bin/env bash
# Set up the voiceger (GPT-SoVITS) Zundamon TTS stack, fully local.
#
#   setup-voiceger.sh [--clone-src]
#
# Assumes the voiceger_v2 source tree.  By default it looks for one of:
#   $VOICEGER_SRC        (set this to override)
#   ~/dev/voiceger_v2
#   <repo>/voiceger-src
# If none exist and --clone-src is passed, it clones https://github.com/
# zunzun999/voiceger_v2 into <repo>/voiceger-src.
#
# Steps:
#   1. Create a Python 3.10 venv ($VOICEGER_VENV, default ~/dev/voiceger-venv)
#   2. Install torch 2.1.2 (cu121 index) + requirements.txt
#   3. Install pyopenjtalk in a CLEAN env (Nix CFLAGS break the build)
#   4. Create a jieba_fast forwarder shim (jieba_fast wheel build is broken)
#   5. Download the Zundamon fine-tune + GPT-SoVITS pretrained models
#   6. Copy the NLTK English tagger data into ~/nltk_data
#
# Idempotent: re-running over an existing setup skips what is already present.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VOICEGER_SRC="${VOICEGER_SRC:-$HOME/dev/voiceger_v2}"
VOICEGER_VENV="${VOICEGER_VENV:-$HOME/dev/voiceger-venv}"
PYVER="3.10"

echo "==> voiceger setup"
echo "    src  : $VOICEGER_SRC"
echo "    venv : $VOICEGER_VENV"

if [[ ! -d "$VOICEGER_SRC" ]]; then
  echo "voiceger source not found at $VOICEGER_SRC" >&2
  echo "  (re-run with --clone-src, or set VOICEGER_SRC to your checkout)" >&2
  exit 1
fi

command -v uv >/dev/null || { echo "need uv (python installer) in PATH" >&2; exit 1; }

# --- venv -------------------------------------------------------------------
if [[ ! -x "$VOICEGER_VENV/bin/python" ]]; then
  echo "==> creating python $PYVER venv"
  uv python install "$PYVER" >/dev/null
  uv venv --python "$PYVER" "$VOICEGER_VENV"
fi

install_pinned() {
  # install with a clean env only where the Nix PYTHONPATH would pollute the
  # wheel build tag (source-built wheels pick up cp313 from Nix CFLAGS).
  uv pip install --python "$VOICEGER_VENV/bin/python" -q "$@"
}

echo "==> installing torch (cu121 index)"
install_pinned --index-url https://download.pytorch.org/whl/cu121 \
  "torch==2.1.2+cu121" "torchvision==0.16.2+cu121" "torchaudio==2.1.2+cu121" || true
install_pinned -r "$REPO/voiceger/requirements.txt" 2>/dev/null || \
  install_pinned numpy==1.26.4 librosa==0.9.2 soundfile==0.14.0 scipy==1.15.3 \
    transformers==4.51.3 fastapi uvicorn pydantic nltk wordsegment unidecode \
    inflect g2p-en jamo g2pk2 pypinyin cn2an py3langid einops matplotlib \
    numba llvmlite coverage setuptools pandas ffmpeg-python

# --- pyopenjtalk (source build needs a clean env) ---------------------------
if ! "$VOICEGER_VENV/bin/python" -c "import pyopenjtalk" 2>/dev/null; then
  echo "==> installing pyopenjtalk (clean env build)"
  env -i PATH="$HOME/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin" HOME="$HOME" \
    uv pip install --python "$VOICEGER_VENV/bin/python" pyopenjtalk || \
    echo "WARN: pyopenjtalk build failed — Japanese/Korean TTS will be limited" >&2
fi

# --- jieba_fast forwarder shim ---------------------------------------------
SITE="$("$VOICEGER_VENV/bin/python" -c "import site;print(site.getsitepackages()[0])")"
mkdir -p "$SITE/jieba_fast"
cat > "$SITE/jieba_fast/__init__.py" <<'PY'
import jieba as _jieba
lcut = _jieba.lcut
cut = _jieba.cut
PY
cat > "$SITE/jieba_fast/posseg.py" <<'PY'
from jieba.posseg import lcut, cut  # noqa: F401
PY
echo "==> jieba_fast shim at $SITE/jieba_fast"
uv pip install --python "$VOICEGER_VENV/bin/python" -q jieba >/dev/null 2>&1 || true
# LangSegment ships as a local package inside the voiceger source tree.
[ -d "$VOICEGER_SRC/LangSegment-0.3.5" ] && \
  install_pinned "$VOICEGER_SRC/LangSegment-0.3.5" 2>/dev/null || true
install_pinned py3langid 2>/dev/null || true

# --- NLTK English tagger ----------------------------------------------------
NLTK="$HOME/nltk_data"
if [ -d "$VOICEGER_SRC/nltk_data" ]; then
  mkdir -p "$NLTK"
  cp -rn "$VOICEGER_SRC/nltk_data/." "$NLTK/" 2>/dev/null || true
  echo "==> nltk_data -> $NLTK"
fi

# --- models -----------------------------------------------------------------
GS="$VOICEGER_SRC/GPT-SoVITS"
PM="$GS/GPT_SoVITS/pretrained_models"
fetch() { # url dest
  if [[ -s "$2" ]]; then echo "    skip (present): $2"; return; fi
  mkdir -p "$(dirname "$2")"
  echo "    download: $1"
  curl -fL --retry 3 --retry-delay 2 -o "$2" "$1"
}

echo "==> GPT-SoVITS pretrained (if missing)"
fetch "https://huggingface.co/lj1995/GPT-SoVITS/resolve/main/chinese-hubert-base/pytorch_model.bin" \
  "$PM/chinese-hubert-base/pytorch_model.bin" || true
fetch "https://huggingface.co/lj1995/GPT-SoVITS/resolve/main/chinese-hubert-base/config.json" \
  "$PM/chinese-hubert-base/config.json" || true
fetch "https://huggingface.co/lj1995/GPT-SoVITS/resolve/main/chinese-hubert-base/preprocessor_config.json" \
  "$PM/chinese-hubert-base/preprocessor_config.json" || true
fetch "https://huggingface.co/lj1995/GPT-SoVITS/resolve/main/chinese-roberta-wwm-ext-large/pytorch_model.bin" \
  "$PM/chinese-roberta-wwm-ext-large/pytorch_model.bin" || true
fetch "https://huggingface.co/lj1995/GPT-SoVITS/resolve/main/chinese-roberta-wwm-ext-large/config.json" \
  "$PM/chinese-roberta-wwm-ext-large/config.json" || true
fetch "https://huggingface.co/lj1995/GPT-SoVITS/resolve/main/chinese-roberta-wwm-ext-large/tokenizer.json" \
  "$PM/chinese-roberta-wwm-ext-large/tokenizer.json" || true

echo "==> Zundamon fine-tuned weights (if missing)"
fetch "https://huggingface.co/zunzunpj/zundamon_GPT-SoVITS/resolve/main/GPT_weights_v2/zudamon_style_1-e15.ckpt" \
  "$GS/GPT_weights_v2/zudamon_style_1-e15.ckpt" || true
fetch "https://huggingface.co/zunzunpj/zundamon_GPT-SoVITS/resolve/main/SoVITS_weights_v2/zudamon_style_1_e8_s96.pth" \
  "$GS/SoVITS_weights_v2/zudamon_style_1_e8_s96.pth" || true

echo
echo "voiceger setup complete."
echo "  venv   : $VOICEGER_VENV"
echo "  server : python tts_server.py   (see run-voiceger-server.sh)"
echo "Verify  : PYTHONPATH= $VOICEGER_VENV/bin/python -c 'import torch,transformers;print(torch.__version__)'"
