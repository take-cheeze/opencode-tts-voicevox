#!/usr/bin/env bash
# Set up the voiceger (GPT-SoVITS) Zundamon TTS stack, fully local.
#
#   setup-voiceger.sh [--clone-src]
#
# Needs the voiceger_v2 source tree (~37 MiB): it vendors GPT-SoVITS,
# LangSegment, the NLTK data and the reference audio the voice is cloned from.
# Looked up as $VOICEGER_SRC, default ~/dev/voiceger_v2.  With --clone-src it
# is cloned from https://github.com/zunzun999/voiceger_v2 if missing.
#
# Steps:
#   1. Create a Python 3.10 venv ($VOICEGER_VENV, default ~/dev/voiceger-venv)
#   2. Install torch 2.1.2 + requirements.txt (cu121 index on Linux, stock
#      PyPI wheels on macOS — there is no CUDA build for Darwin)
#   3. Install pyopenjtalk in a CLEAN env (Nix CFLAGS break the build)
#   4. Create a jieba_fast forwarder shim (jieba_fast wheel build is broken)
#   5. Download the Zundamon fine-tune + GPT-SoVITS pretrained models
#   6. Copy the NLTK English tagger data into ~/nltk_data
#
# Idempotent: re-running over an existing setup skips what is already present.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$(uname -s)" in
  Darwin) OS=macos ;;
  Linux)  OS=linux ;;
  *) echo "unsupported OS: $(uname -s) (need Linux or macOS)" >&2; exit 1 ;;
esac
VOICEGER_SRC="${VOICEGER_SRC:-$HOME/dev/voiceger_v2}"
VOICEGER_VENV="${VOICEGER_VENV:-$HOME/dev/voiceger-venv}"
VOICEGER_GIT="${VOICEGER_GIT:-https://github.com/zunzun999/voiceger_v2}"
PYVER="3.10"

clone_src=0
for arg in "$@"; do
  case "$arg" in
    --clone-src) clone_src=1 ;;
    *) echo "unknown argument: $arg (usage: setup-voiceger.sh [--clone-src])" >&2; exit 2 ;;
  esac
done

echo "==> voiceger setup"
echo "    src  : $VOICEGER_SRC"
echo "    venv : $VOICEGER_VENV"

if [[ ! -d "$VOICEGER_SRC" ]]; then
  if [[ "$clone_src" -eq 1 ]]; then
    echo "==> cloning $VOICEGER_GIT -> $VOICEGER_SRC"
    mkdir -p "$(dirname "$VOICEGER_SRC")"
    git clone --depth 1 "$VOICEGER_GIT" "$VOICEGER_SRC"
  else
    echo "voiceger source not found at $VOICEGER_SRC" >&2
    echo "  (re-run with --clone-src, or set VOICEGER_SRC to your checkout)" >&2
    exit 1
  fi
fi
for required in GPT-SoVITS reference; do
  [[ -d "$VOICEGER_SRC/$required" ]] || {
    echo "voiceger: $VOICEGER_SRC does not look like a voiceger_v2 tree" >&2
    echo "  (missing $required/)" >&2
    exit 1
  }
done

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

if [[ "$OS" = macos ]]; then
  # No CUDA on Darwin: the stock wheels are CPU + Metal (MPS).
  echo "==> installing torch (macOS wheels)"
  install_pinned "torch==2.1.2" "torchvision==0.16.2" "torchaudio==2.1.2" || true
else
  echo "==> installing torch (cu121 index)"
  install_pinned --index-url https://download.pytorch.org/whl/cu121 \
    "torch==2.1.2+cu121" "torchvision==0.16.2+cu121" "torchaudio==2.1.2+cu121" || true
fi
# No fallback list here on purpose: a partial install produces a venv that
# looks fine and then dies with an opaque ModuleNotFoundError deep inside
# GPT-SoVITS.  Fail loudly instead, with the resolver's explanation.
if ! install_pinned -r "$REPO/requirements.txt"; then
  echo "ERROR: could not install $REPO/requirements.txt (see resolver output above)." >&2
  exit 1
fi

# --- pyopenjtalk (source build needs a clean env) ---------------------------
# It compiles C++, so the build must not see Nix's CFLAGS. Rebuild PATH from
# scratch; on macOS it also needs cmake and the Xcode command line tools.
CLEAN_PATH="/usr/local/bin:/usr/bin:/bin"
for extra in "$HOME/.nix-profile/bin" /opt/homebrew/bin; do
  [ -d "$extra" ] && CLEAN_PATH="$extra:$CLEAN_PATH"
done
if ! "$VOICEGER_VENV/bin/python" -c "import pyopenjtalk" 2>/dev/null; then
  echo "==> installing pyopenjtalk (clean env build)"
  if [[ "$OS" = macos ]]; then
    xcode-select -p >/dev/null 2>&1 || \
      echo "WARN: Xcode command line tools missing (xcode-select --install)" >&2
    command -v cmake >/dev/null || \
      echo "WARN: cmake not found; pyopenjtalk needs it (brew install cmake)" >&2
  fi
  env -i PATH="$CLEAN_PATH" HOME="$HOME" \
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
