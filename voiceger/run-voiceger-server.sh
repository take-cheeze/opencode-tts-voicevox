#!/usr/bin/env bash
# Launch the voiceger Zundamon TTS server with a clean environment.
#
# The machine's direnv/Nix environment exports a huge PYTHONPATH (Nix Python
# site-packages for a different version).  If that leaks into this venv,
# imports fail with version-mismatch errors (cffi, numpy, ...), so drop it.
#
# Env:
#   VOICEGER_VENV  python venv (default ~/dev/voiceger-venv)
#   VOICEGER_SRC   tree providing reference/ (default ~/dev/voiceger_v2)
#   VOICEGER_PORT  listen port (default 18123)
#   VOICEGER_DEVICE cpu|cuda|mps (default cpu; mps = Apple GPU)
#   VOICEGER_ENGINE audio8 (default) | audio8-onnx | raon
set -eu

VENV="${VOICEGER_VENV:-$HOME/dev/voiceger-venv}"
VOICEGER_SRC="${VOICEGER_SRC:-$HOME/dev/voiceger_v2}"
port="${VOICEGER_PORT:-18123}"

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
export VOICEGER_ENGINE="${VOICEGER_ENGINE:-audio8}"
unset PYTHONPATH PYTHONNOUSERSITE _PYTHON_HOST_PLATFORM _PYTHON_SYSCONFIGDATA_NAME PYTHON_CONFIGURE_OPTS

exec "$VENV/bin/python" "$(dirname "$0")/tts_server.py"
