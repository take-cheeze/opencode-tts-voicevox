#!/usr/bin/env bash
# Wire opencode-tts to a fully local Zundamon TTS stack:
#
#   Japanese / CJK   ->  VOICEVOX CORE C shim      (fast, offline, GPU-free)
#   English, other   ->  voiceger / GPT-SoVITS     (natural multilingual)
#
# The opencode-tts plugin only knows about an `edge_tts` command; we give it
# `opencode-tts-dispatch`, a lookalike CLI that routes by language.
#
# Usage:
#   install.sh [--skip-voiceger]
#
#   --skip-voiceger   do not set up the (larger) voiceger GPT-SoVITS stack;
#                     Japanese/CJK still works via the voicevox shim.
#
# Restart opencode afterwards to pick up the plugin config change.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin"

echo "==> opencode-tts voicevox+voiceger install ($REPO)"

# --- 1. voicevox C shim (required) -----------------------------------------
if [[ ! -d "$REPO/voicevox/assets" && ! -f "$REPO/voicevox/assets/core/lib/libvoicevox_core.so" ]]; then
  if [[ -f "$HOME/dev/rpg-maker-clone/assets/voicevox/core/lib/libvoicevox_core.so" ]]; then
    VOICEDIR="$HOME/dev/rpg-maker-clone/assets/voicevox"
  else
    echo "==> fetching VOICEVOX assets into $REPO/voicevox/assets"
    VOICEDIR="$REPO/voicevox/assets"
    bash "$REPO/voicevox/fetch-voicevox.sh" "$VOICEDIR"
  fi
else
  VOICEDIR="$REPO/voicevox/assets"
fi
VOICEDIR="${VOICEVOX_DIR:-$VOICEDIR}"

echo "==> building voicevox shim into $BIN"
make -C "$REPO/voicevox" VOICEVOX_DIR="$VOICEDIR" PREFIX="$PREFIX" install

# --- 2. dispatch CLI --------------------------------------------------------
echo "==> installing opencode-tts-dispatch into $BIN"
install -m 0755 "$REPO/opencode-tts-dispatch" "$BIN/opencode-tts-dispatch"

# --- 3. voiceger server (optional) ------------------------------------------
if [[ "${1:-}" != "--skip-voiceger" ]]; then
  if [[ -x "$REPO/voiceger/setup-voiceger.sh" ]]; then
    bash "$REPO/voiceger/setup-voiceger.sh" || {
      echo "WARN: voiceger setup incomplete; English TTS will fall back until" >&2
      echo "      setup-voiceger.sh finishes.  Japanese/CJK TTS is unaffected." >&2
    }
    echo "==> enabling voiceger systemd user unit"
    cp "$REPO/voiceger/opencode-tts-voiceger.service" \
       "$HOME/.config/systemd/user/opencode-tts-voiceger.service"
    systemctl --user daemon-reload
    systemctl --user enable  --now opencode-tts-voiceger.service
  else
    echo "WARN: voiceger setup script missing; English will speak via edge-tts if available." >&2
  fi
fi

# --- 4. plugin config --------------------------------------------------------
CFG_DIR="$HOME/.config/opencode/plugins"
CFG="$CFG_DIR/opencode-tts.jsonc"
mkdir -p "$CFG_DIR"
cat > "$CFG" <<JSON
{
  "enabled": true,
  "mode": "summary",
  "backend": "edge_tts",
  "edge_tts": {
    "command": ["$BIN/opencode-tts-dispatch"],
    "voice": "ja-JP-ZundamonNeural",
    "rate": "+25%",
    "volume": "+0%"
  }
}
JSON
echo "==> wrote $CFG"

# register the plugin in opencode.json (project or global)
for f in ./opencode.json "$HOME/.config/opencode/opencode.json"; do
  [[ -f "$f" ]] || continue
  if ! grep -q '"opencode-tts"' "$f"; then
    node -e '
      const fs=require("fs");const p=process.argv[1];
      try{const j=JSON.parse(fs.readFileSync(p,"utf8").replace(/\/\//gm,""))
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
echo "  voiceger:   systemctl --user status opencode-tts-voiceger"
