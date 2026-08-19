# Claude Code → Zundamon

Make [Claude Code](https://claude.com/claude-code) speak its replies through the
same local stack opencode uses: `claude-tts-speak` is a **Stop hook** that reads
the last assistant message out of the session transcript and hands it to
`opencode-tts-dispatch` (CJK → VOICEVOX, everything else → voiceger).

```
Claude Code finishes a turn
        │  Stop hook, hook payload on stdin
        ▼
  claude-tts-speak ── transcript_path ──► last assistant text
        │                                        │
        │                             strip markdown, first 2 sentences
        ▼                                        ▼
  opencode-tts-dispatch ──► VOICEVOX / voiceger ──► afplay
```

## Setup

`install.sh` puts the script in `~/.local/bin`. Registering the hook is a
separate, opt-in step — add it to `~/.claude/settings.json` (all projects) or
`.claude/settings.json` (this project only):

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [
          { "type": "command",
            "command": "\"$HOME/.local/bin/claude-tts-speak\"",
            "async": true,
            "timeout": 180 }
      ] }
    ]
  }
}
```

`async: true` matters: synthesis takes a few seconds and playback longer, and
without it every turn would sit there waiting for Zundamon to stop talking.

Review or disable it later with `/hooks`.

## Over SSH

When Claude runs on a remote host, the models and the speakers are back on
your machine. `claude-tts-speakd` closes that gap: the remote session sends
**text**, and synthesis happens at your end — so the remote host needs no
VOICEVOX assets, no voiceger, and no audio device. Just the one stdlib-only
`claude-tts-speak` script.

```
remote:  claude-tts-speak ──POST /speak──► 127.0.0.1:17999
                                              │  ssh -R
here:    claude-tts-speakd ◄──────────────────┘
              └─► claude-tts-speak --text … ─► dispatcher ─► speakers
```

**On this machine**, run the receiver (`install.sh` puts it in `~/.local/bin`;
`com.opencode-tts.speakd.plist` keeps it running):

```sh
claude-tts-speakd            # or load the launchd agent
```

**In `~/.ssh/config`**, tunnel the port back:

```
Host remote
  RemoteForward 17999 localhost:17999
  # Share one connection, or each new session tries to bind the same remote
  # port and all but the first fail with "remote port forwarding failed".
  ControlMaster auto
  ControlPath ~/.ssh/cm-%C
  ControlPersist 10m
```

**On the remote**, install just the hook script and register the Stop hook:

```sh
scp ~/.local/bin/claude-tts-speak remote:.local/bin/
```

No configuration needed beyond that — the hook probes `127.0.0.1:17999` and
forwards when something answers, so the same `settings.json` works on both
ends. Set `CLAUDE_TTS_FORWARD=off` to force local synthesis, or point
`CLAUDE_TTS_FORWARD` at an explicit URL to skip the probe.

### opencode-tts over the same tunnel

`opencode-tts` does not use this hook — it runs `opencode-tts-dispatch` for a
file and plays that file itself. The dispatcher forwards too, in one of two
shapes (`TTS_FORWARD_MODE`):

| mode | what crosses the link | who plays it |
|---|---|---|
| `speak` (default) | text only | the receiver, natively |
| `synth` | text out, audio back | the caller |

**`speak` is the default because `synth` sends the sound twice**: down as an
MP3, then back up as decoded PCM through whatever the caller plays it with —
roughly 20x larger than the MP3 that produced it. In `speak` mode the receiver
synthesizes *and* plays, and `--write-media` gets a 357-byte silent MP3 so the
plugin has a real file to play and stays happy.

That also drops two dependencies: no `PULSE_SERVER` forward is needed, and no
audio player is needed on the remote at all. If the plugin fails to find one it
throws *after* the receiver has already made the sound, so you still hear it.

Use `synth` when the caller must genuinely own playback — for instance a host
whose audio is already routed somewhere you want.

Dispatcher knobs mirror the hook's: `TTS_FORWARD`, `TTS_FORWARD_PORT`,
`TTS_TOKEN`, plus `TTS_FORWARD_MODE`.

### Shared remote hosts

The forwarded port is loopback-bound on the remote, but *every* local user
there can reach it — so on a multi-user box anyone could have your laptop
speak. Set the same `CLAUDE_TTS_TOKEN` at both ends; the receiver then answers
unauthenticated requests with 403. Bodies over `CLAUDE_TTS_MAXBYTES` (8 KiB)
are rejected outright.

## Tuning

| Variable | Default | |
|---|---|---|
| `CLAUDE_TTS_SENTENCES` | `2` | how many sentences to read |
| `CLAUDE_TTS_MAXCHARS` | `350` | hard cap before truncating |
| `CLAUDE_TTS_RATE` | `+25%` | passed through to the dispatcher |
| `CLAUDE_TTS_DISPATCH` | `~/.local/bin/opencode-tts-dispatch` | dispatcher path |
| `CLAUDE_TTS_PLAYER` | `afplay`, else `ffplay`/`mpg123`/`mpv` | audio player |
| `CLAUDE_TTS_DEBUG` | unset | `1` reports why nothing was spoken |
| `CLAUDE_TTS_FORWARD` | auto-probe | receiver URL, or `off` to force local |
| `CLAUDE_TTS_FORWARD_PORT` | `17999` | loopback port to probe |
| `CLAUDE_TTS_TOKEN` | unset | shared secret for the receiver |

## Notes

- **Silence is by design.** The hook exits 0 on every failure path so a TTS
  problem can never break a session. Run it by hand with `CLAUDE_TTS_DEBUG=1`
  to find out why it stayed quiet:

  ```sh
  echo '{"transcript_path":"'"$HOME"'/.claude/projects/<proj>/<session>.jsonl"}' \
    | CLAUDE_TTS_DEBUG=1 claude-tts-speak
  ```

- **Tool results are `user` rows.** Claude Code stores them as `type: "user"`
  with a `toolUseResult` key, so the transcript walk only treats a *genuine*
  user turn as the end of the turn — otherwise the first tool result would stop
  the search and nothing would ever be found.
- **Barge-in**: a new response kills playback still running from the previous
  one, so replies do not pile up on top of each other.
- **What gets spoken** is prose only: fenced code, tables, URLs, and inline code
  that looks like a path, flag, or command are dropped, because they are
  unlistenable read aloud.
