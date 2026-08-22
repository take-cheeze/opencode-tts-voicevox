#!/usr/bin/env bash
# claude-code/setup-tunnel.sh [--serve|--funnel] [--port N] [--off]
#
# Two ways to put claude-tts-speakd behind a stable https://<host>.<tailnet>.
# ts.net name without opening a router port or owning a domain. Run this on
# the box that actually runs claude-tts-speakd (see claude-code/README.md).
#
# --serve                  Tailnet-only, and the DEFAULT. Any device signed
#                          into YOUR tailnet -- another laptop, an iPad, a
#                          phone -- can POST /speak or /synth and make these
#                          speakers talk. Nothing is reachable from the
#                          public internet, so CLAUDE_TTS_TOKEN stays
#                          optional here.
# --funnel                 Public internet. For Claude Code Web sessions,
#                          which run in Anthropic's cloud rather than on a
#                          tailnet device. Reachable by anyone who knows the
#                          URL, so CLAUDE_TTS_TOKEN becomes REQUIRED --
#                          generated if you don't have one exported, printed,
#                          and never saved by this script.
#
# --off tears both serve and funnel back down; it does not touch
# CLAUDE_TTS_TOKEN or stop claude-tts-speakd.
#
# Both modes proxy to the loopback port claude-tts-speakd already listens on;
# neither changes its CLAUDE_TTS_BIND.
set -euo pipefail

PORT="${CLAUDE_TTS_PORT:-17999}"
ACTION=up
MODE=serve

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift ;;
    --serve) MODE=serve ;;
    --funnel) MODE=funnel ;;
    --off) ACTION=off ;;
    -h|--help) echo "usage: $0 [--serve|--funnel] [--port N] [--off]" >&2; exit 2 ;;
    *) echo "usage: $0 [--serve|--funnel] [--port N] [--off]" >&2; exit 2 ;;
  esac
  shift
done

find_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    command -v tailscale
    return
  fi
  # The Mac App Store build has no CLI on PATH by default.
  if [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
    echo /Applications/Tailscale.app/Contents/MacOS/Tailscale
    return
  fi
  return 1
}

TS="$(find_tailscale)" || {
  echo "setup-tunnel: no tailscale CLI found." >&2
  echo "  macOS (Mac App Store build already installed): the CLI lives at" >&2
  echo "    /Applications/Tailscale.app/Contents/MacOS/Tailscale" >&2
  echo "  macOS (Homebrew): brew install --cask tailscale" >&2
  echo "  Linux: curl -fsSL https://tailscale.com/install.sh | sh" >&2
  exit 1
}

if [ "$ACTION" = off ]; then
  # "funnel reset" / "serve reset" clear the whole funnel/serve config, not
  # just this port; that's fine since setup-tunnel.sh is the only thing
  # setting either up here. Reset both so a plain '--off' always cleans up,
  # whichever mode brought it online; each is a no-op when unset.
  "$TS" funnel reset || true
  "$TS" serve reset || true
  echo "setup-tunnel: serve/funnel disabled. claude-tts-speakd is still" \
       "running (untouched) and CLAUDE_TTS_TOKEN is still whatever you had" \
       "set -- this only closes the network path to it."
  exit 0
fi

if ! "$TS" status >/dev/null 2>&1; then
  cat >&2 <<EOF
setup-tunnel: tailscale is not running/logged in on this machine.
  Run '$TS up' yourself first (it opens a browser to authenticate), then
  re-run this script.
EOF
  exit 1
fi

if [ "$MODE" = funnel ] && [ -z "${CLAUDE_TTS_TOKEN:-}" ]; then
  CLAUDE_TTS_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
  cat >&2 <<EOF
setup-tunnel: no CLAUDE_TTS_TOKEN in your environment -- generated one, since
Funnel makes claude-tts-speakd reachable from the whole internet and it must
not run open. This token is NOT saved anywhere by this script:

  CLAUDE_TTS_TOKEN=$CLAUDE_TTS_TOKEN

You need it in two places:
  1. Wherever claude-tts-speakd runs, as an environment variable (its
     launchd plist / systemd unit -- see claude-code/README.md), then
     reload it. On macOS, 'launchctl kickstart -k' restarts the process
     but does NOT pick up a changed EnvironmentVariables block -- use:
       launchctl bootout gui/\$(id -u)/com.opencode-tts.speakd
       launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/com.opencode-tts.speakd.plist
     On Linux there's no shipped systemd unit for claude-tts-speakd yet
     (only voiceger has one) -- however you're running it, restart the
     process with CLAUDE_TTS_TOKEN in its environment.
  2. The Claude Code Web environment (claude.ai/code -> environment
     selector -> your environment -> Environment variables), so the hook
     can authenticate. See "Next steps" below for the exact lines.
EOF
fi

if [ "$MODE" = serve ]; then
  echo "setup-tunnel: enabling tailnet-only serve for 127.0.0.1:$PORT ..."
  if ! "$TS" serve --bg "$PORT"; then
    echo "setup-tunnel: 'tailscale serve' failed. If it mentions HTTPS," >&2
    echo "  enable it once in the admin console:" >&2
    echo "  https://login.tailscale.com/admin/dns -> HTTPS -> Enable" >&2
    exit 1
  fi
  URL="$("$TS" serve status 2>/dev/null | grep -oE 'https://[^ ]+' | head -1)"
else
  echo "setup-tunnel: enabling funnel for 127.0.0.1:$PORT ..."
  "$TS" funnel --bg "$PORT"

  URL="$("$TS" funnel status 2>/dev/null | grep -oE 'https://[^ ]+' | head -1)"
fi
if [ -z "$URL" ]; then
  echo "setup-tunnel: $MODE enabled, but couldn't parse the URL -- run" \
       "'$TS $MODE status' yourself." >&2
  exit 1
fi
HOST="${URL#https://}"
HOST="${HOST%%/*}"

if [ "$MODE" = serve ]; then
  cat <<EOF

setup-tunnel: done. Tailnet-only URL: $URL

Reachable from any device signed into this tailnet; the public internet
sees nothing, so no token is needed (set one at both ends anyway if you
share the tailnet with people who shouldn't trigger your speakers).

From another tailnet machine:

  # plain curl -- works anywhere, installs nothing:
  curl -s -X POST $URL/speak \\
    -H 'Content-Type: application/json' -d '{"text":"ずんだもんだよ"}'

  # claude-tts-speak hooks on a remote host (no SSH tunnel config needed):
  export CLAUDE_TTS_FORWARD=$URL

  # opencode-tts-dispatch there (opencode plugin stays unmodified):
  export TTS_FORWARD=$URL

'$TS serve status' shows what's exposed; '$0 --off --serve' takes it down.
EOF
else
  cat <<EOF

setup-tunnel: done. Public URL: $URL

Next steps, in the Claude Code Web environment dialog
(claude.ai/code -> environment selector -> Add/edit environment):

  Network access: Custom, with this in Allowed domains:
    $HOST

  Environment variables (.env format):
    CLAUDE_TTS_FORWARD=$URL
    CLAUDE_TTS_TOKEN=$CLAUDE_TTS_TOKEN

Then register the project-level hook (claude-code/setup-hooks.sh --project,
committed to the repo) if you haven't already -- Claude Code Web only reads
project/org hooks, never ~/.claude/settings.json.

Anyone who can reach this URL and knows the token can make your speakers
talk; anyone who can reach it WITHOUT the token gets a 403. Run
'$TS funnel status' any time to check what's exposed, or
'$0 --off --funnel' to take it back down.
EOF
fi
