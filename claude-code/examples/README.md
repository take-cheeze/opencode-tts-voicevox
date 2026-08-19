# Configuration examples

Working configurations for both clients, on the machine with the speakers and
on a machine you reach over SSH.

Which files matter:

| file | what it is |
|---|---|
| `claude-settings.json` | Claude Code — `~/.claude/settings.json` |
| `opencode-plugin.js` | opencode — `~/.config/opencode/plugin/zundamon-tts.js` |
| `ssh-config` | `~/.ssh/config` — the tunnel that makes remote hosts work |
| `com.opencode-tts.speakd.plist` | launchd agent for the receiver (macOS) |

## The shape

One machine has the models, the speakers and `claude-tts-speakd`. Every other
machine has two Python scripts and a tunnel, and needs no model, no voice
assets, no ffmpeg and no audio device.

```
remote host                          machine with the speakers
  claude-tts-speak  ──POST /speak──►   summarize → synthesize → play
  opencode-tts-dispatch                        (ssh -R 17999)
```

## Claude Code

`~/.claude/settings.json` — identical on every machine, which is the point:
the `-x` guard makes it inert where the stack is not installed, so one file can
be shared through dotfiles.

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ {
          "type": "command",
          "command": "[ -x \"$HOME/.local/bin/claude-tts-speak\" ] && \"$HOME/.local/bin/claude-tts-speak\" || true",
          "async": true,
          "timeout": 180
      } ] }
    ],
    "Notification": [
      { "hooks": [ {
          "type": "command",
          "command": "[ -x \"$HOME/.local/bin/claude-tts-speak\" ] && \"$HOME/.local/bin/claude-tts-speak\" --notify || true",
          "async": true,
          "timeout": 60
      } ] }
    ]
  }
}
```

`Stop` speaks the reply when a turn ends. `Notification` speaks when Claude is
waiting on you — a question or a permission prompt — and `--notify` reads the
payload so you hear *what* it wants rather than a fixed phrase.

`async: true` matters on both: synthesis takes seconds and playback longer, and
without it every turn would wait for the audio to finish.

## opencode

opencode has a plugin API, so this is a plugin rather than a hook. Drop
`zundamon-tts.js` in `~/.config/opencode/plugin/` — local plugins autoload, and
nothing goes in `opencode.json`.

It speaks the reply on `session.idle` and announces permission prompts through
`permission.ask`. Two things in it are deliberate and easy to get wrong:

- **`output.status` is never written.** Writing it *answers* the prompt instead
  of announcing it.
- **`Bun.spawn`, not the plugin's `$`.** That `$` is Bun Shell, which has no
  `command` builtin — the trap that makes `opencode-tts` report "No audio player
  found" on Linux while ffplay sits on PATH.

## The tunnel

`~/.ssh/config`, on the machine with the speakers:

```
Host remote
  RemoteForward 17999 localhost:17999
  # This host may crash. Without a keepalive the client never notices and the
  # server keeps the port bound to a session whose client is gone; every later
  # connection then logs "remote port forwarding failed" and silently runs with
  # no tunnel.
  ServerAliveInterval 30
  ServerAliveCountMax 3
```

Add `ControlMaster auto` / `ControlPath ~/.ssh/cm-%C` / `ControlPersist 10m` if
you open several sessions at once — otherwise each one tries to bind the same
port and all but the first fail. Skip it on hosts that see bulk `rsync`/`scp`,
where funnelling everything through one connection costs throughput.

The forward belongs to the **host**, not the session: once any connection binds
17999, every process there can use it. The corollary is that closing every
session takes the tunnel down, and the hook then falls back to local synthesis
— silently, by design.

## Summarizer

Set on the receiver (the launchd plist is the natural place). Order is
deliberate — the default never reaches an API provider:

```sh
# 1. self-hosted, preferred: nothing leaves the machine
CLAUDE_TTS_SUMMARY_URL=http://127.0.0.1:11434/v1   # ollama
CLAUDE_TTS_SUMMARY_MODEL=qwen2.5:3b

# 2. opt-in only, this is a real API call
# CLAUDE_TTS_SUMMARY_CLAUDE=1

# 3. neither: extractive truncation, needs nothing
```

Any OpenAI-compatible endpoint works — `ollama`, `llama-server`,
`mlx_lm.server`. If you point it at a *reasoning* model, leave `max_tokens`
generous: the budget goes to `reasoning_content` first, and a tight cap returns
an empty `content` with `finish_reason: "stop"` — success-shaped and useless.

## Checking it

```sh
claude-tts-speak --text "テストなのだ。"          # should speak
CLAUDE_TTS_DEBUG=1 claude-tts-speak --text hi     # says which path it took
curl -s http://127.0.0.1:17999/ping               # receiver alive?
```

Every failure path exits 0 — a TTS problem must never break a session — so
`CLAUDE_TTS_DEBUG=1` is the only way to find out why it stayed quiet.
