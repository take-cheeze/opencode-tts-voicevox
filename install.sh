#!/usr/bin/env bash
# Wire opencode-tts to a fully local Zundamon TTS stack:
#
#   Japanese / CJK   ->  VOICEVOX CORE C shim      (fast, offline, GPU-free)
#   English, other   ->  voiceger / Audio8-TTS     (natural multilingual)
#
# The opencode-tts plugin only knows about an `edge_tts` command; we give it
# `opencode-tts-dispatch`, a lookalike CLI that routes by language.
#
# Supported: Linux (systemd user services) and macOS (launchd user agents).
#
# Usage:
#   install.sh [--skip-voiceger] [--translate-always]
#
#   --skip-voiceger   do not set up the (larger) voiceger TTS stack;
#                     Japanese/CJK still works via the voicevox shim.
#   --translate-always  same effect as --skip-voiceger, for when this box's
#                     hooks always translate to Japanese first (e.g. the
#                     Claude Code Stop hook runs `claude-tts-speak --translate`
#                     unconditionally, or the opencode plugin has
#                     OPENCODE_TTS_TRANSLATE_REPLIES=1) -- text handed to
#                     opencode-tts-dispatch is then always CJK, so voiceger's
#                     English/multilingual path would never be exercised.
#   --clone-src       clone the voiceger_v2 source tree if it is missing
#                     (forwarded to setup-voiceger.sh).
#   --with-raon       also install the optional, experimental
#                     KRAFTON/Raon-OpenTTS-1B engine (English-only, ~16.7GB
#                     checkpoint, GPU strongly recommended -- forwarded to
#                     setup-voiceger.sh; select it at runtime with
#                     VOICEGER_ENGINE=raon).
#   --with-audio8-onnx  also install the optional Audio8-TTS-Preview-0.6B-
#                     ONNX-INT4 engine (official quantized build, ~1GB
#                     runtime footprint vs ~1.4-5GB for the default audio8
#                     engine -- forwarded to setup-voiceger.sh; select it at
#                     runtime with VOICEGER_ENGINE=audio8-onnx).
#
# Restart opencode afterwards to pick up the plugin config change.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin"

SKIP_VOICEGER=0
SETUP_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --skip-voiceger|--translate-always) SKIP_VOICEGER=1 ;;
    --clone-src|--with-raon|--with-audio8-onnx) SETUP_ARGS+=("$arg") ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

case "$(uname -s)" in
  Linux)  OS=linux;  LIBEXT=so    ;;
  Darwin) OS=macos;  LIBEXT=dylib ;;
  *) echo "unsupported OS: $(uname -s) (need Linux or macOS)" >&2; exit 1 ;;
esac

echo "==> opencode-tts voicevox+voiceger install ($OS, $REPO)"

command -v ffmpeg >/dev/null || {
  echo "WARN: ffmpeg not found in PATH; the dispatcher needs it to emit MP3." >&2
  [ "$OS" = macos ] && echo "      install it with: brew install ffmpeg" >&2
}

# --- 1. voicevox C shim (required) -----------------------------------------
if [[ -n "${VOICEVOX_DIR:-}" ]]; then
  VOICEDIR="$VOICEVOX_DIR"
elif [[ -f "$REPO/voicevox/assets/core/lib/libvoicevox_core.$LIBEXT" ]]; then
  VOICEDIR="$REPO/voicevox/assets"
else
  echo "==> fetching VOICEVOX assets into $REPO/voicevox/assets"
  VOICEDIR="$REPO/voicevox/assets"
  bash "$REPO/voicevox/fetch-voicevox.sh" "$VOICEDIR"
fi

echo "==> building voicevox shim into $BIN"
make -C "$REPO/voicevox" VOICEVOX_DIR="$VOICEDIR" PREFIX="$PREFIX" install

# --- 2. dispatch CLI --------------------------------------------------------
echo "==> installing opencode-tts-dispatch into $BIN"
install -m 0755 "$REPO/opencode-tts-dispatch" "$BIN/opencode-tts-dispatch"

# Claude Code speaks through the same dispatcher, via a Stop hook. Installing
# the script is enough; registering the hook is a separate, opt-in step
# (see claude-code/README.md).
echo "==> installing claude-tts-speak into $BIN"
install -m 0755 "$REPO/claude-code/claude-tts-speak" "$BIN/claude-tts-speak"
# Receiver for sessions running over SSH on another machine. Installed
# everywhere, but only useful on the box with the speakers.
install -m 0755 "$REPO/claude-code/claude-tts-speakd" "$BIN/claude-tts-speakd"

# On macOS, also register claude-tts-speakd as a launchd agent so it is
# actually listening on 127.0.0.1:17999 -- otherwise remote hosts probe the
# port, find nothing, and quietly fall back to local (model-less) processing.
# Harmless on a box with no remote hosts forwarding to it: it just sits idle
# on loopback.
if [[ "$OS" = macos ]]; then
  echo "==> loading claude-tts-speakd launchd agent"
  agent_dir="$HOME/Library/LaunchAgents"
  plist="$agent_dir/com.opencode-tts.speakd.plist"
  mkdir -p "$agent_dir" "$HOME/Library/Logs"
  sed "s|@HOME@|$HOME|g" "$REPO/claude-code/com.opencode-tts.speakd.plist" > "$plist"
  launchctl bootout "gui/$(id -u)/com.opencode-tts.speakd" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
fi

# --- 3. voiceger server (optional) ------------------------------------------
install_service_linux() {
  local unit_dir="$HOME/.config/systemd/user"
  echo "==> enabling voiceger systemd user unit"
  mkdir -p "$unit_dir"
  # The shipped unit carries a placeholder ExecStart; point it at this checkout.
  sed "s|^ExecStart=.*|ExecStart=$REPO/voiceger/run-voiceger-server.sh|" \
    "$REPO/voiceger/opencode-tts-voiceger.service" \
    > "$unit_dir/opencode-tts-voiceger.service"
  systemctl --user daemon-reload
  systemctl --user enable --now opencode-tts-voiceger.service
}

install_service_macos() {
  local label="com.opencode-tts.voiceger"
  local agent_dir="$HOME/Library/LaunchAgents"
  local plist="$agent_dir/$label.plist"
  echo "==> loading voiceger launchd agent"
  mkdir -p "$agent_dir" "$HOME/Library/Logs"
  # launchd does no variable expansion; bake the absolute paths in.
  sed -e "s|@REPO@|$REPO|g" -e "s|@HOME@|$HOME|g" \
    "$REPO/voiceger/$label.plist" > "$plist"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
}

if [[ "$SKIP_VOICEGER" -eq 0 ]]; then
  if [[ -x "$REPO/voiceger/setup-voiceger.sh" ]]; then
    # Only register the service if setup actually succeeded — a unit pointing
    # at a half-built venv just crash-loops on Restart=on-failure / KeepAlive.
    if bash "$REPO/voiceger/setup-voiceger.sh" ${SETUP_ARGS+"${SETUP_ARGS[@]}"}; then
      if [[ "$OS" = macos ]]; then install_service_macos; else install_service_linux; fi
    else
      echo "WARN: voiceger setup incomplete; not registering the service." >&2
      echo "      Japanese/CJK TTS is unaffected. Re-run install.sh once the" >&2
      echo "      setup errors above are resolved to enable English TTS." >&2
    fi
  else
    echo "WARN: voiceger setup script missing; English will speak via edge-tts if available." >&2
  fi
fi

# --- 4. plugin config --------------------------------------------------------
CFG_DIR="$HOME/.config/opencode/plugins"
CFG="$CFG_DIR/opencode-tts.jsonc"
mkdir -p "$CFG_DIR"
# Re-running the installer should not silently undo a voice you picked
# (`opencode-tts-voicevox --list-voices` shows the choices).
VOICE="ja-JP-ZundamonNeural"
if [[ -f "$CFG" ]]; then
  prev="$(sed -n 's/.*"voice"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" | head -1)"
  # not `&&` -- this is the last line of the block, and under `set -e` an
  # empty $prev would end the install right here.
  if [[ -n "$prev" ]]; then VOICE="$prev"; fi
fi
cat > "$CFG" <<JSON
{
  "enabled": true,
  "mode": "summary",
  "backend": "edge_tts",
  "edge_tts": {
    "command": ["$BIN/opencode-tts-dispatch"],
    "voice": "$VOICE",
    "rate": "+25%",
    "volume": "+0%"
  }
}
JSON
echo "==> wrote $CFG (voice: $VOICE)"
echo "    other voices: $BIN/opencode-tts-voicevox --list-voices"

# register the plugin in opencode.json (project or global)
for f in ./opencode.json "$HOME/.config/opencode/opencode.json"; do
  [[ -f "$f" ]] || continue
  if ! grep -q '"opencode-tts"' "$f"; then
    # Strip //-comments so JSONC parses as JSON. Only when // starts a line
    # or follows whitespace -- a bare /\/\// matched inside "https://..." too
    # and corrupted every URL in the file (schema, provider baseURL) on any
    # box whose opencode.json had one.
    node -e '
      const fs=require("fs");const p=process.argv[1];
      try{const j=JSON.parse(fs.readFileSync(p,"utf8").replace(/(^|\s)\/\/.*$/gm,"$1"))
          j.plugin=Array.isArray(j.plugin)?j.plugin:[]
          if(!j.plugin.some(x=>x==="opencode-tts"))j.plugin.push("opencode-tts")
          fs.writeFileSync(p,JSON.stringify(j,null,2)+"\n")}catch(e){}' "$f" \
      && echo "    registered in $f"
  else
    echo "    already in $f"
  fi
done

echo
echo "Done. Restart opencode to pick up the new TTS backend."
echo "  voicevox:   $BIN/opencode-tts-voicevox"
echo "  dispatcher: $BIN/opencode-tts-dispatch"
if [[ "$OS" = macos ]]; then
  echo "  voiceger:   launchctl print gui/$(id -u)/com.opencode-tts.voiceger"
  echo "              log: ~/Library/Logs/opencode-tts-voiceger.log"
else
  echo "  voiceger:   systemctl --user status opencode-tts-voiceger"
fi
