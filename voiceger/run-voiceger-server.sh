#!/usr/bin/env bash
# Launch the voiceger (Zundamon GPT-SoVITS) TTS server with a clean environment.
#
# The machine's direnv/Nix environment exports a huge PYTHONPATH (Nix Python
# 3.13 site-packages).  If that leaks into our Python 3.10 venv, imports fail
# with version-mismatch errors (cffi, numpy, ...), so drop it.
#
# Env:
#   VOICEGER_VENV  python venv (default ~/dev/voiceger-venv)
#   VOICEGER_SRC   voiceger_v2 tree (default ~/dev/voiceger_v2)
#   VOICEGER_PORT  listen port (default 8123)
#   VOICEGER_DEVICE cpu|cuda|mps (default cpu; mps = Apple GPU)
set -eu

VENV="${VOICEGER_VENV:-$HOME/dev/voiceger-venv}"
VOICEGER_SRC="${VOICEGER_SRC:-$HOME/dev/voiceger_v2}"
GS="$VOICEGER_SRC/GPT-SoVITS"
port="${VOICEGER_PORT:-8123}"

# A minimal PATH, rebuilt rather than inherited (see the PYTHONPATH note above).
# launchd hands agents an even barer environment than a login shell, so name
# the Homebrew prefixes explicitly instead of assuming a shell profile ran.
PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
for extra in "$HOME/.nix-profile/bin" /opt/homebrew/bin /usr/local/opt/ffmpeg/bin; do
  [ -d "$extra" ] && PATH="$extra:$PATH"
done
export PATH
export VIRTUAL_ENV="$VENV"
export VOICEGER_SRC
export VOICEGER_DEVICE="${VOICEGER_DEVICE:-cpu}"
export VOICEGER_PORT="$port"
export G2PW_MODEL_DIR="$GS/GPT_SoVITS/text/G2PWModel"
export NLTK_DATA="${NLTK_DATA:-$HOME/nltk_data}"
unset PYTHONPATH PYTHONNOUSERSITE _PYTHON_HOST_PLATFORM _PYTHON_SYSCONFIGDATA_NAME PYTHON_CONFIGURE_OPTS

exec "$VENV/bin/python" "$(dirname "$0")/tts_server.py"
