#!/usr/bin/env bash
# claude-code/setup-tunnel.sh [--port N] [--off]
#
# Exposes claude-tts-speakd to the public internet via Tailscale Funnel, so
# a Claude Code Web session -- which runs in Anthropic's cloud, not on your
# machine -- can reach it and make THIS machine's speakers talk. Run this on
# the box that actually runs claude-tts-speakd (see claude-code/README.md).
#
# Unlike the existing SSH RemoteForward setup (for a remote CLI session),
# there is no SSH session here to tunnel over -- Claude Code Web needs a
# public URL. Funnel gives you a stable https://<host>.<tailnet>.ts.net
# without opening a port on your router or owning a domain.
#
# This makes claude-tts-speakd internet-reachable, so it refuses to run
# without CLAUDE_TTS_TOKEN. Generates one if you don't already have it
# exported, and always prints it -- copy it to wherever claude-tts-speakd
# runs (its launchd/systemd unit) AND to the Claude Code Web environment's
# variables, alongside CLAUDE_TTS_FORWARD.
#
# --off tears the funnel down again; it does not touch CLAUDE_TTS_TOKEN or
# stop claude-tts-speakd.
set -euo pipefail

PORT="${CLAUDE_TTS_PORT:-17999}"
ACTION=up

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift ;;
    --off) ACTION=off ;;
    -h|--help) echo "usage: $0 [--port N] [--off]" >&2; exit 2 ;;
    *) echo "usage: $0 [--port N] [--off]" >&2; exit 2 ;;
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
  # "funnel reset" clears the whole funnel config, not just this port; that's
  # fine since setup-tunnel.sh only ever sets up one.
  "$TS" funnel reset
  echo "setup-tunnel: funnel disabled. claude-tts-speakd is still running" \
       "(untouched) and CLAUDE_TTS_TOKEN is still whatever you had set --" \
       "this only closes the public path to it."
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

if [ -z "${CLAUDE_TTS_TOKEN:-}" ]; then
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

echo "setup-tunnel: enabling funnel for 127.0.0.1:$PORT ..."
"$TS" funnel --bg "$PORT"

URL="$("$TS" funnel status 2>/dev/null | grep -oE 'https://[^ ]+' | head -1)"
if [ -z "$URL" ]; then
  echo "setup-tunnel: funnel enabled, but couldn't parse the URL -- run" \
       "'$TS funnel status' yourself." >&2
  exit 1
fi
HOST="${URL#https://}"
HOST="${HOST%%/*}"

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
'$0 --off' to take it back down.
EOF
