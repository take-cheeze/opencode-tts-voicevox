#!/usr/bin/env bash
# claude-code/setup-hooks.sh [--user] [--project] [--all] [--force]
#
# Registers the Stop + Notification + UserPromptSubmit hooks that make
# Claude Code speak through claude-tts-speak, merging them into whichever
# settings.json scope(s) you ask for. Idempotent: an existing entry that
# already invokes claude-tts-speak is left alone, unless --force replaces
# it (e.g. after this script's own command changes).
#
# UserPromptSubmit (speaks what YOU typed, in CLAUDE_TTS_USER_VOICE) is
# registered unconditionally too, same as the others -- it is a no-op
# unless CLAUDE_TTS_USER_VOICE is set, and unlike Stop/Notification it
# cannot run async (Claude Code ignores "async" for this event and waits
# for the command to exit before your turn starts), so claude-tts-speak
# detaches its own background work and this hook returns immediately
# either way. See claude-code/README.md.
#
#   --user     ~/.claude/settings.json   this machine, every project. Not
#              read by Claude Code Web -- cloud sessions never see it.
#   --project  ./.claude/settings.json   this repo only. Commit it: it is
#              the ONLY scope Claude Code Web reads (project-level hooks,
#              or org-managed settings -- see claude-code/README.md).
#   --all      both of the above (default if neither is given)
#
# The --project hook is self-contained for a bare cloud VM: it runs the
# repo-committed claude-tts-speak with $CLAUDE_PROJECT_DIR rather than
# assuming ~/.local/bin/claude-tts-speak is installed, since a fresh
# Claude Code Web session has none of your local dotfiles. It only makes
# sound if CLAUDE_TTS_FORWARD (and usually CLAUDE_TTS_TOKEN) are set for
# that session -- see claude-code/setup-tunnel.sh.
set -euo pipefail

usage() { echo "usage: $0 [--user] [--project] [--all] [--force]" >&2; exit 2; }

want_user=0
want_project=0
force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --user) want_user=1 ;;
    --project) want_project=1 ;;
    --all) want_user=1; want_project=1 ;;
    --force) force=1 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
  shift
done
if [ "$want_user" -eq 0 ] && [ "$want_project" -eq 0 ]; then
  want_user=1
  want_project=1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

merge() {
  local target="$1" stop_cmd="$2" notify_cmd="$3" prompt_cmd="$4" label="$5"
  python3 - "$target" "$stop_cmd" "$notify_cmd" "$prompt_cmd" "$force" <<'PY'
import json
import os
import sys

target, stop_cmd, notify_cmd, prompt_cmd, force = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == "1")

try:
    with open(target, encoding="utf-8") as fh:
        raw = fh.read().strip()
    settings = json.loads(raw) if raw else {}
except FileNotFoundError:
    settings = {}
except ValueError as exc:
    sys.exit("setup-hooks: %s is not valid JSON, not touching it: %s" % (target, exc))

hooks = settings.setdefault("hooks", {})


def has_ours(event):
    for block in hooks.get(event, []):
        for h in block.get("hooks", []):
            if "claude-tts-speak" in h.get("command", ""):
                return True
    return False


def upsert(event, command, timeout, async_=True):
    entries = hooks.setdefault(event, [])
    if has_ours(event):
        if not force:
            print("setup-hooks: %s already has a claude-tts-speak %s hook, "
                  "leaving it (--force to replace)" % (target, event))
            return False
        entries[:] = [
            b for b in entries
            if not any("claude-tts-speak" in h.get("command", "")
                       for h in b.get("hooks", []))
        ]
    hook = {"type": "command", "command": command, "timeout": timeout}
    if async_:
        hook["async"] = True  # ignored by Claude Code for UserPromptSubmit
    entries.append({"hooks": [hook]})
    return True

changed = False
changed |= upsert("Stop", stop_cmd, 180)
changed |= upsert("Notification", notify_cmd, 60)
changed |= upsert("UserPromptSubmit", prompt_cmd, 10, async_=False)

if changed:
    os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
    with open(target, "w", encoding="utf-8") as fh:
        json.dump(settings, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    print("setup-hooks: wrote %s" % target)
PY
}

if [ "$want_user" -eq 1 ]; then
  merge "$HOME/.claude/settings.json" \
    '[ -x "$HOME/.local/bin/claude-tts-speak" ] && "$HOME/.local/bin/claude-tts-speak" || true' \
    '[ -x "$HOME/.local/bin/claude-tts-speak" ] && "$HOME/.local/bin/claude-tts-speak" --notify || true' \
    '[ -x "$HOME/.local/bin/claude-tts-speak" ] && "$HOME/.local/bin/claude-tts-speak" --user-prompt || true' \
    "user"
fi

if [ "$want_project" -eq 1 ]; then
  merge "$repo_root/.claude/settings.json" \
    'python3 "$CLAUDE_PROJECT_DIR/claude-code/claude-tts-speak"' \
    'python3 "$CLAUDE_PROJECT_DIR/claude-code/claude-tts-speak" --notify' \
    'python3 "$CLAUDE_PROJECT_DIR/claude-code/claude-tts-speak" --user-prompt' \
    "project"
  echo "setup-hooks: commit .claude/settings.json for Claude Code Web to see it" \
       " (see claude-code/setup-tunnel.sh for the forwarding half)"
fi
