#!/usr/bin/env bash
# register-tts-host.sh --register <alias> [flags]
#
# One-shot wrapper that makes a remote host forward its Claude Code speech back
# to THIS machine's claude-tts-speakd, matching the gem-12 / nucbox setup:
#
#   1. Local:   ensure claude-tts-speakd is running on 127.0.0.1:<port> and that
#               ~/.ssh/config tunnels the port back (RemoteForward), adding the
#               Host block if missing and never touching an existing block's
#               other options.
#   2. Remote:  install claude-tts-speak and register its Stop/Notification/
#               UserPromptSubmit hooks. The client auto-probes 127.0.0.1:<port>
#               (the RemoteForward lands it here) and forwards when something
#               answers, so the remote needs no further config -- the same
#               settings.json works on both ends (see claude-code/README.md).
#   3. --token: set a shared secret at BOTH ends, so a shared host cannot be
#               spoken to without it (see "Shared remote hosts" in the README).
#
# Idempotent everywhere: an alias you already registered is left as-is except
# for the RemoteForward line (added only if it is missing). A brand-new alias
# gets a fresh Host block with the full recipe (RemoteForward + keepalive +
# ControlMaster), as recommended in claude-code/README.md.
#
#   --register <alias>   ssh Host alias to set up (required).
#   --port <N>           loopback port to tunnel; defaults to $CLAUDE_TTS_PORT
#                        or 17999. The remote probes its own 127.0.0.1:<N>, so
#                        keep it at 17999 unless you also set that on the remote.
#   --token [=<VALUE>]   set a shared secret. Bare --token generates one;
#                        --token=<VALUE> uses it. Applied to the speakd plist
#                        (reloaded) and to the remote shell rc in one step.
#   --no-hook            install the binary but do not register the hooks.
#   --local-only         only set up this machine (speakd + ssh config).
#   --remote-only        only set up the remote (assume the ssh config already
#                        tunnels the port).
#   -h, --help           this text.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/com.opencode-tts.speakd.plist"
SPEAKD_LABEL="com.opencode-tts.speakd"

ALIAS=""
PORT="${CLAUDE_TTS_PORT:-17999}"
DO_LOCAL=1
DO_REMOTE=1
DO_HOOK=1
TOKEN_MODE=0
TOKEN=""

usage() {
  [ -n "${2:-}" ] && echo "register-tts-host: $2" >&2
  cat <<'EOF'
usage: register-tts-host.sh --register <alias> [flags]

  --register <alias>   ssh Host alias to set up (required; a Host block is
                       created if missing, updated if present).
  --port <N>           loopback port to tunnel (default $CLAUDE_TTS_PORT or 17999).
  --token [=<VALUE>]   set a shared secret at both ends (bare = generate one).
  --no-hook            install the binary but not the hooks.
  --local-only         only this machine (speakd + ssh config).
  --remote-only        only the remote (assume the ssh config already tunnels).
  -h, --help           this text.
EOF
  exit "${1:-2}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --register) [ $# -ge 2 ] || usage 2 "missing value for --register"; ALIAS="$2"; shift 2 ;;
    --register=*) ALIAS="${1#*=}"; shift ;;
    --port) [ $# -ge 2 ] || usage 2 "missing value for --port"; PORT="$2"; shift 2 ;;
    --token) TOKEN_MODE=1; shift ;;
    --token=*) TOKEN_MODE=1; TOKEN="${1#*=}"; shift ;;
    --no-hook) DO_HOOK=0; shift ;;
    --local-only) DO_REMOTE=0; shift ;;
    --remote-only) DO_LOCAL=0; shift ;;
    -h|--help) usage 0 ;;
    *) echo "register-tts-host: unknown argument: $1" >&2; usage 2 ;;
  esac
done

[ -n "$ALIAS" ] || usage 2 "missing --register <alias>"
case "$PORT" in
  ''|*[!0-9]*) echo "register-tts-host: --port must be a number" >&2; exit 2 ;;
esac

if [ "$TOKEN_MODE" -eq 1 ] && [ -z "$TOKEN" ]; then
  TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
fi

echo "register-tts-host: alias=$ALIAS  local_port=$PORT"
if [ "$TOKEN_MODE" -eq 1 ]; then
  echo "             token: shared secret set at BOTH ends ($(printf '%s' "$TOKEN" | wc -c | tr -d ' ') bytes)"
else
  echo "             token: none (open -- fine on a private tailnet or single-user host)"
fi

# --- local ------------------------------------------------------------------
if [ "$DO_LOCAL" -eq 1 ]; then
  if [ ! -f "$PLIST" ]; then
    echo "ERROR: $PLIST not found. Run ./install.sh first (it registers the agent)." >&2
    exit 1
  fi
  if ! launchctl print "gui/$(id -u)/$SPEAKD_LABEL" 2>/dev/null \
        | grep -qi "state = running"; then
    echo "local: launching claude-tts-speakd ..."
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
  fi
  if [ ! -x "$HOME/.local/bin/claude-tts-speakd" ]; then
    echo "WARN: $HOME/.local/bin/claude-tts-speakd not found; the agent will not start." >&2
  fi
  echo "local: claude-tts-speakd is loaded"

  if [ "$TOKEN_MODE" -eq 1 ]; then
    echo "local: setting CLAUDE_TTS_TOKEN on the speakd agent (preserving its comments) ..."
    python3 - "$PLIST" "$TOKEN" <<'PY'
import os, re, sys
path, token = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()

# Idempotent: an already-active token key is left alone.
if re.search(r'(?m)^\s*<key>CLAUDE_TTS_TOKEN</key>\s*<string>[^<]*</string>', text):
    print("local: token already set; leaving it"); sys.exit(0)

# Prefer the author's placeholder comment (install.sh ships it) so the edit is a
# 1:1 swap that keeps every other comment and key in place.
m = re.search(
    r'(?m)^(\s*)<!--\s*<key>CLAUDE_TTS_TOKEN</key>\s*<string>[^<]*</string>\s*-->', text)
if m:
    new = (text[:m.start()] + "%s<key>CLAUDE_TTS_TOKEN</key><string>%s</string>"
           % (m.group(1), token) + text[m.end():])
else:
    # Fallback: slot it right after the CLAUDE_TTS_PORT key inside EnvironmentVariables.
    pm = re.search(
        r'(?m)^(\s*)<key>CLAUDE_TTS_PORT</key>\s*<string>[^<]*</string>', text)
    if not pm:
        sys.exit("local: could not find a place to set the token in %s" % path)
    indent = pm.group(1)
    new = (text[:pm.end()]
           + "\n%s<key>CLAUDE_TTS_TOKEN</key><string>%s</string>" % (indent, token)
           + text[pm.end():])

tmp = path + ".tts-tmp"
open(tmp, "w", encoding="utf-8").write(new)
# Validate before swapping in, so a bad edit never leaves the plist unusable.
# Use plutil (launchd's own validator): this plist keeps "--" inside comments,
# which is technically illegal XML but plutil accepts and plistlib rejects.
import subprocess
if subprocess.run(["/usr/bin/plutil", "-lint", tmp]).returncode != 0:
    os.remove(tmp)
    sys.exit("local: plutil rejected the edited plist; not applying it")
os.replace(tmp, path)
print("local: token written")
PY
    echo "local: reloading claude-tts-speakd to pick up the token ..."
    launchctl bootout "gui/$(id -u)/$SPEAKD_LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
  fi
fi

# --- ssh config (idempotent) ------------------------------------------------
if [ "$DO_LOCAL" -eq 1 ]; then
  SSHCFG="$HOME/.ssh/config"
  if [ ! -f "$SSHCFG" ]; then
    echo "ERROR: $SSHCFG not found." >&2
    exit 1
  fi
  python3 - "$SSHCFG" "$ALIAS" "$PORT" <<'PY'
import os, re, sys, fnmatch

path, alias, port = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
had_final_nl = text.endswith("\n")
lines = text.split("\n")
if lines and lines[-1] == "":
    lines.pop()

preamble, blocks = [], []
cur = None
for ln in lines:
    if ln[:4].lower() == "host" and ln[4:].strip():
        cur = {"patterns": [p for part in ln[4:].strip().split(",") for p in part.split()],
               "body": []}
        blocks.append(cur)
    elif cur is None:
        preamble.append(ln)
    else:
        cur["body"].append(ln)

def matches(b):
    return any(alias == p or fnmatch.fnmatchcase(alias, p) for p in b["patterns"])

existing = [b for b in blocks if matches(b)]
changed = False
if existing:
    b = existing[0]
    has_port = False
    for ln in b["body"]:
        s = ln.strip()
        if s and not s.startswith("#"):
            parts = s.split()
            if parts[0].lower() == "remoteforward" and len(parts) >= 2 and parts[1] == port:
                has_port = True
                break
    if not has_port:
        b["body"] += [
            "  # Claude Code TTS: remote POSTs text here; claude-tts-speakd synthesizes it.",
            "  RemoteForward %s localhost:%s" % (port, port)]
        changed = True
else:
    blocks.append({
        "patterns": [alias],
        "body": [
            "  # Claude Code TTS: the remote session POSTs text here and claude-tts-speakd",
            "  # synthesizes it locally, so the remote needs no models. No SetEnv needed --",
            "  # claude-tts-speak probes this port and forwards when it answers.",
            "  RemoteForward %s localhost:%s" % (port, port),
            "  # Share one connection across sessions; otherwise each tries to bind the",
            "  # forwarded port and all but the first fail with 'remote port forwarding failed'.",
            "  ControlMaster auto",
            "  ControlPath ~/.ssh/cm-%C",
            "  ControlPersist 10m",
            "  # Reap a dead peer so its forwarded ports are not left bound to a gone",
            "  # session (after which forwarding silently stops).",
            "  ServerAliveInterval 30",
            "  ServerAliveCountMax 3",
        ],
    })
    changed = True

out = list(preamble)
for i, b in enumerate(blocks):
    if i > 0 and out and out[-1] != "":
        out.append("")
    out.append("Host " + ", ".join(b["patterns"]))
    out.extend(b["body"])

new = "\n".join(out) + ("\n" if had_final_nl else "")
if changed:
    tmp = path + ".tts-tmp"
    open(tmp, "w", encoding="utf-8").write(new)
    os.replace(tmp, path)
    where = "a new" if not existing else "the existing"
    print("sshconfig: added RemoteForward to %s block for %s" % (where, alias))
else:
    print("sshconfig: %s already tunnels :%s (unchanged)" % (alias, port))
PY
fi

# --- remote -----------------------------------------------------------------
if [ "$DO_REMOTE" -eq 1 ]; then
  if [ ! -x "$SELF_DIR/claude-tts-speak" ]; then
    echo "ERROR: $SELF_DIR/claude-tts-speak not found or not executable." >&2
    exit 1
  fi
  echo "remote: installing claude-tts-speak ..."
  if ! scp "$SELF_DIR/claude-tts-speak" "$ALIAS:~/.local/bin/claude-tts-speak" >/dev/null; then
    echo "ERROR: scp to '$ALIAS' failed. Is the host up and reachable (tailscale)?" >&2
    exit 1
  fi
  ssh "$ALIAS" 'chmod +x ~/.local/bin/claude-tts-speak'

  if [ "$DO_HOOK" -eq 1 ]; then
    echo "remote: registering Stop/Notification/UserPromptSubmit hooks ..."
    ssh "$ALIAS" 'bash /dev/stdin --user' < "$SELF_DIR/setup-hooks.sh"
  fi

  if [ "$TOKEN_MODE" -eq 1 ] || [ "$PORT" != "17999" ]; then
    echo "remote: exporting forwarding knobs into the shell rc ..."
    ssh "$ALIAS" 'bash -s --' "$TOKEN" "$PORT" <<'REMOTE'
set -e
token="$1"; port="$2"
for rc in .zshrc .bashrc .bash_profile; do
  path="$HOME/$rc"
  [ -f "$path" ] || continue
  grep -qF 'CLAUDE_TTS_TOKEN=' "$path" 2>/dev/null && continue
  {
    printf '\n# register-tts-host.sh: forwarding knobs for Claude Code TTS\n'
    [ -n "$token" ] && printf 'export CLAUDE_TTS_TOKEN=%s\n' "$token"
    [ "$port" != "17999" ] && printf 'export CLAUDE_TTS_FORWARD_PORT=%s\n' "$port"
  } >> "$path"
  echo "remote: wrote knobs into $path"
done
[ -f "$HOME/.zshrc" ] || [ -f "$HOME/.bashrc" ] || [ -f "$HOME/.bash_profile" ] || \
  echo "remote: no shell rc found; set CLAUDE_TTS_TOKEN / CLAUDE_TTS_FORWARD_PORT in your" >&2
REMOTE
  fi
fi

# --- verify -----------------------------------------------------------------
echo
echo "Done. To verify (runs on the remote, forwards back here):"
echo "  ssh $ALIAS '\"\$HOME/.local/bin/claude-tts-speak\" --text \"hello world\"'"
echo "Confirm the tunnel is in effect:"
echo "  ssh -G $ALIAS | grep remoteforward"

if [ "$TOKEN_MODE" -eq 1 ]; then
  echo
  echo "NOTE: the speakd now REQUIRES the token; remote sessions whose shell has not"
  echo "      sourced the rc yet will get a 403 until they reconnect. Re-run this command"
  echo "      if you later change your mind and want it open again (drop --token)."
fi
