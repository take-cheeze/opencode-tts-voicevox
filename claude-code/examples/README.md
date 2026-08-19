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
`permission.ask`. Three things in it are deliberate and easy to get wrong:

- **`output.status` is never written.** Writing it *answers* the prompt instead
  of announcing it.
- **`Bun.spawn`, not the plugin's `$`.** That `$` is Bun Shell, which has no
  `command` builtin — the trap that makes `opencode-tts` report "No audio player
  found" on Linux while ffplay sits on PATH.
- **`chat.message` is awaited by opencode**, unlike Claude Code's shell-command
  hooks. It fires on your own submitted prompt -- the closest opencode has to
  Claude Code's `UserPromptSubmit` -- and opencode blocks the pipeline on its
  returned promise, so it must only ever spawn-and-`unref()`, never await the
  process itself, or every prompt would wait on synthesis + playback.

Set `OPENCODE_TTS_USER_VOICE` (e.g. `metan`) to have it read your own prompts
back too, in that voice, translated to Japanese first through the same
self-hosted endpoint the summarizer uses (`CLAUDE_TTS_SUMMARY_URL` /
`CLAUDE_TTS_SUMMARY_MODEL`, set on whichever machine actually synthesizes --
see Summarizer below). Unset, `chat.message` is a no-op.

`OPENCODE_TTS_TRANSLATE_REPLIES=1` does the same for the assistant's own
reply on `session.idle` -- off by default, since unlike your own prompt
(which you chose to have translated) the reply's language is opencode's
call to make, not this plugin's. On, it goes out through the VOICEVOX voice
instead of voiceger's single English one, same as `--translate` on the
Claude Code Stop hook.

A model small enough to be cheap can still be an unreliable translator: a
1.5B model was observed answering in English instead of Japanese on a real
reply -- success-shaped (non-empty), just not a translation. claude-tts-speak
now checks the output actually contains Japanese before accepting it, so
that fails to silence rather than to the wrong voice, but getting an actual
translation took bumping to a bigger model (3B was reliable here).

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
CLAUDE_TTS_SUMMARY_MODEL=qwen2.5:1.5b

# offload to a beefier box, keeping the local one as fallback. Entries are
# tried in order and may carry their own model after a "#":
# CLAUDE_TTS_SUMMARY_URL=http://gpubox:11434/v1#qwen2.5:7b,http://127.0.0.1:11434/v1

# 2. opt-in only, this is a real API call
# CLAUDE_TTS_SUMMARY_CLAUDE=1

# 3. neither: extractive truncation, needs nothing
```

Any OpenAI-compatible endpoint works — `ollama`, `llama-server`,
`mlx_lm.server`.

Endpoints are probed with a one-second TCP connect before use, so a box that is
down costs a second rather than a generation timeout — worth having if the
remote is a machine that reboots on its own. If every endpoint fails it falls
through to extractive truncation rather than hanging.

Offloading only pays if the remote runs a *faster* model than the local one.
Measured here, pointing at a remote reasoning model made a summary take 27s
against 8.6s locally: the GPU was never the bottleneck, the reasoning tokens
were.

On model size, measured on an M4 over four technical samples: `0.5b` fabricates
(it invented a shell command that does not exist) and is not usable here;
`1.5b` is accurate enough at 1.1 GB resident; `3b` is the most faithful at
2.1 GB but ignored the two-sentence instruction more often. Summarizing is a
second or two either way — synthesis dominates the wall clock — so the real
tradeoff is memory, not speed. All sizes garble causality occasionally: treat
the audio as a nudge, not a record. If you point it at a *reasoning* model, leave `max_tokens`
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
