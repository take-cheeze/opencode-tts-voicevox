#!/usr/bin/env bash
# claude-code/register-web-env.sh
#
# There is no API or CLI to create/edit a Claude Code Web cloud environment
# (claude.ai/code's network access + environment variables dialog) -- it is
# web-UI-only, and that's true as of writing, not a gap in this script. This
# is the closest thing to automating it: works out the current values,
# copies the paste-ready block to your clipboard, and opens the page.
#
# Reads:
#   - the Funnel URL from `tailscale funnel status` (run
#     claude-code/setup-tunnel.sh first if that's empty)
#   - CLAUDE_TTS_TOKEN from your environment if set, else from the live
#     launchd plist on macOS (there's no Linux unit for claude-tts-speakd
#     yet, so pass it explicitly there: CLAUDE_TTS_TOKEN=... register-web-env.sh)
set -euo pipefail

find_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    command -v tailscale
    return
  fi
  if [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
    echo /Applications/Tailscale.app/Contents/MacOS/Tailscale
    return
  fi
  return 1
}

TS="$(find_tailscale)" || { echo "register-web-env: no tailscale CLI found" >&2; exit 1; }

URL="$("$TS" funnel status 2>/dev/null | grep -oE 'https://[^ ]+' | head -1)"
if [ -z "$URL" ]; then
  cat >&2 <<'EOF'
register-web-env: no funnel currently running. Run this first:
  claude-code/setup-tunnel.sh
EOF
  exit 1
fi
HOST="${URL#https://}"
HOST="${HOST%%/*}"

TOKEN="${CLAUDE_TTS_TOKEN:-}"
if [ -z "$TOKEN" ] && [ "$(uname -s)" = "Darwin" ] && [ -f "$HOME/Library/LaunchAgents/com.opencode-tts.speakd.plist" ]; then
  TOKEN="$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:CLAUDE_TTS_TOKEN" \
    "$HOME/Library/LaunchAgents/com.opencode-tts.speakd.plist" 2>/dev/null || true)"
fi
if [ -z "$TOKEN" ]; then
  cat >&2 <<'EOF'
register-web-env: no CLAUDE_TTS_TOKEN found (checked your environment, and
the launchd plist on macOS). Either export it, or set one and reload
claude-tts-speakd first -- see claude-code/setup-tunnel.sh's output from
when it generated one.
EOF
  exit 1
fi

BLOCK="CLAUDE_TTS_FORWARD=$URL
CLAUDE_TTS_TOKEN=$TOKEN"

copied=""
if command -v pbcopy >/dev/null 2>&1; then
  printf '%s' "$BLOCK" | pbcopy
  copied="pbcopy"
elif command -v wl-copy >/dev/null 2>&1; then
  printf '%s' "$BLOCK" | wl-copy
  copied="wl-copy"
elif command -v xclip >/dev/null 2>&1; then
  printf '%s' "$BLOCK" | xclip -selection clipboard
  copied="xclip"
fi

echo "register-web-env: Network access -> Custom -> Allowed domains: $HOST"
echo "register-web-env: Environment variables:"
echo "$BLOCK"
if [ -n "$copied" ]; then
  echo "register-web-env: the two-line block above is on your clipboard ($copied)."
else
  echo "register-web-env: no clipboard tool found (pbcopy/wl-copy/xclip) -- copy the block above by hand."
fi

if command -v open >/dev/null 2>&1; then
  open "https://claude.ai/code"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "https://claude.ai/code"
else
  echo "register-web-env: open https://claude.ai/code yourself -- no 'open'/'xdg-open' found."
fi

cat <<EOF

Then, in the environment dialog (cloud icon above the message box ->
Add/edit environment):
  1. Network access: Custom, add "$HOST" to Allowed domains
  2. Environment variables: paste the clipboard (or the two lines above)
  3. Save
EOF
