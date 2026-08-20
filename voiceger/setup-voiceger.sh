#!/usr/bin/env bash
# Set up the voiceger Zundamon TTS stack, fully local.
#
#   setup-voiceger.sh [--clone-src] [--with-raon] [--with-audio8-onnx]
#
# Needs a voiceger_v2-shaped tree (~few MiB) purely for its reference/
# directory: the wav clip + transcript both engines clone the Zundamon voice
# from. Looked up as $VOICEGER_SRC, default ~/dev/voiceger_v2. With
# --clone-src it is cloned from https://github.com/zunzun999/voiceger_v2 if
# missing.
#
# Steps:
#   1. Create a Python venv ($VOICEGER_VENV, default ~/dev/voiceger-venv)
#   2. Install torch + requirements.txt (cu121 index on Linux, stock PyPI
#      wheels on macOS -- there is no CUDA build for Darwin)
#   3. --with-raon only: clone krafton-ai/Raon-OpenTTS and `pip install -e` it
#   4. --with-audio8-onnx only: clone Audio8-AI/Audio8_TTS, install its
#      onnx_runtime deps into this same venv, and download
#      Audio8-TTS-Preview-0.6B-ONNX-INT4 (~1GB)
#
# The default engine (Audio8-TTS-Preview-0.1b) downloads its own weights
# through transformers' normal Hugging Face cache the first time the server
# starts -- there is nothing to pre-fetch here.
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
RAON_SRC="${RAON_SRC:-$HOME/dev/Raon-OpenTTS}"
RAON_GIT="${RAON_GIT:-https://github.com/krafton-ai/Raon-OpenTTS}"
VOICEGER_ONNX_SRC="${VOICEGER_ONNX_SRC:-$HOME/dev/Audio8_TTS}"
VOICEGER_ONNX_GIT="${VOICEGER_ONNX_GIT:-https://github.com/Audio8-AI/Audio8_TTS}"
VOICEGER_ONNX_MODEL="${VOICEGER_ONNX_MODEL:-Audio8/Audio8-TTS-Preview-0.6B-ONNX-INT4}"
PYVER="3.10"

clone_src=0
with_raon=0
with_audio8_onnx=0
for arg in "$@"; do
  case "$arg" in
    --clone-src) clone_src=1 ;;
    --with-raon) with_raon=1 ;;
    --with-audio8-onnx) with_audio8_onnx=1 ;;
    *) echo "unknown argument: $arg (usage: setup-voiceger.sh [--clone-src] [--with-raon] [--with-audio8-onnx])" >&2; exit 2 ;;
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
if [[ ! -d "$VOICEGER_SRC/reference" ]]; then
  echo "voiceger: $VOICEGER_SRC does not look like a voiceger_v2 tree (missing reference/)" >&2
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
  uv pip install --python "$VOICEGER_VENV/bin/python" -q "$@"
}

if [[ "$OS" = macos ]]; then
  # No CUDA on Darwin: the stock wheels are CPU + Metal (MPS).
  echo "==> installing torch (macOS wheels)"
  install_pinned torch torchaudio || true
else
  echo "==> installing torch (cu121 index)"
  install_pinned --index-url https://download.pytorch.org/whl/cu121 torch torchaudio || true
fi
# No fallback list here on purpose: a partial install produces a venv that
# looks fine and then dies with an opaque ModuleNotFoundError deep inside the
# model's remote code. Fail loudly instead, with the resolver's explanation.
if ! install_pinned -r "$REPO/requirements.txt"; then
  echo "ERROR: could not install $REPO/requirements.txt (see resolver output above)." >&2
  exit 1
fi

# --- optional: Raon-OpenTTS (VOICEGER_ENGINE=raon) --------------------------
if [[ "$with_raon" -eq 1 ]]; then
  echo "WARNING: Raon-OpenTTS-1B is English-only, its checkpoint is ~16.7GB," >&2
  echo "         and it has not been verified to run acceptably on CPU here." >&2
  echo "         Only enable VOICEGER_ENGINE=raon on a box with a working GPU." >&2
  if [[ ! -d "$RAON_SRC" ]]; then
    echo "==> cloning $RAON_GIT -> $RAON_SRC"
    mkdir -p "$(dirname "$RAON_SRC")"
    git clone --depth 1 "$RAON_GIT" "$RAON_SRC"
  fi
  echo "==> installing Raon-OpenTTS into the venv"
  install_pinned -e "$RAON_SRC" || {
    echo "WARN: Raon-OpenTTS install failed -- VOICEGER_ENGINE=raon will not work" >&2
    echo "      (Japanese/CJK and the default audio8 English path are unaffected)" >&2
  }
fi

# --- optional: Audio8-TTS-Preview-0.6B-ONNX-INT4 (VOICEGER_ENGINE=audio8-onnx) --
if [[ "$with_audio8_onnx" -eq 1 ]]; then
  if [[ ! -d "$VOICEGER_ONNX_SRC" ]]; then
    echo "==> cloning $VOICEGER_ONNX_GIT -> $VOICEGER_ONNX_SRC"
    mkdir -p "$(dirname "$VOICEGER_ONNX_SRC")"
    git clone --depth 1 "$VOICEGER_ONNX_GIT" "$VOICEGER_ONNX_SRC"
  fi
  echo "==> installing Audio8 ONNX runtime deps into the venv"
  # arktts_runtime only needs onnxruntime/scipy/tokenizers beyond what
  # requirements.txt already installed (numpy, soundfile) -- it runs fine
  # under this venv's Python even though the standalone onnx_runtime project
  # asks for 3.11+, so no second venv is needed.
  install_pinned onnxruntime scipy tokenizers "huggingface_hub[cli]" || {
    echo "WARN: Audio8 ONNX runtime deps failed to install -- VOICEGER_ENGINE=audio8-onnx will not work" >&2
  }
  MODEL_DIR="$VOICEGER_ONNX_SRC/onnx_runtime/model"
  if [[ ! -f "$MODEL_DIR/runtime_manifest.json" ]]; then
    echo "==> downloading $VOICEGER_ONNX_MODEL (~1GB)"
    "$VOICEGER_VENV/bin/hf" download "$VOICEGER_ONNX_MODEL" --local-dir "$MODEL_DIR" || {
      echo "WARN: Audio8 ONNX model download failed -- VOICEGER_ENGINE=audio8-onnx will not work" >&2
    }
  fi
fi

echo
echo "voiceger setup complete."
echo "  venv   : $VOICEGER_VENV"
echo "  server : python tts_server.py   (see run-voiceger-server.sh)"
echo "Verify  : PYTHONPATH= $VOICEGER_VENV/bin/python -c 'import torch,transformers;print(torch.__version__)'"
[[ "$with_raon" -eq 1 ]] && echo "  raon   : VOICEGER_ENGINE=raon (opt-in, see warning above)"
[[ "$with_audio8_onnx" -eq 1 ]] && echo "  audio8-onnx : VOICEGER_ENGINE=audio8-onnx (opt-in, ~1GB runtime footprint)"
