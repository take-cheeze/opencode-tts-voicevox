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
separate, opt-in step:

```sh
claude-code/setup-hooks.sh --user     # ~/.claude/settings.json, every project
claude-code/setup-hooks.sh --project  # ./.claude/settings.json, this repo --
                                       # commit it: it's the ONLY scope Claude
                                       # Code Web reads (see "Claude Code Web"
                                       # below)
claude-code/setup-hooks.sh --all      # both (default with no flags)
```

It's idempotent (safe to re-run) and merges into whatever else is already in
that `settings.json`, rather than overwriting it. Equivalently, by hand:

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

`setup-hooks.sh` also registers a `PermissionRequest` hook matched on
`ExitPlanMode`, so you get an audio alert the moment a plan is ready for
review, not just whatever the generic `Notification` hook happens to catch.
It runs the exact same `--notify` command, always exits without printing
anything to stdout, and so can never grant or deny the actual permission --
only alert. Worst case it's a redundant beep alongside `Notification`.

Review or disable any of these later with `/hooks`.

## Speak what you type

A second, optional hook (`--user-prompt`, on `UserPromptSubmit`) speaks your
own prompt back in a *different* voice than whatever answers it, so the two
are never confusable:

```sh
CLAUDE_TTS_USER_VOICE=metan claude-code/setup-hooks.sh --all
```

Unset `CLAUDE_TTS_USER_VOICE` (the default) and this hook is a fast no-op --
`setup-hooks.sh` registers it unconditionally, same as Stop/Notification.

VOICEVOX only understands Japanese, so a non-Japanese prompt is translated
first, with the same self-hosted endpoint `--summarize` already talks to
(`CLAUDE_TTS_SUMMARY_URL` / `CLAUDE_TTS_SUMMARY_MODEL`) -- no extra model to
run just for this. Already-Japanese prompts skip translation.

`UserPromptSubmit` cannot run async: Claude Code waits for the hook command
to exit before your turn starts, full stop (`"async"` is silently ignored for
this event). `claude-tts-speak --user-prompt` handles that itself -- it reads
your prompt, spawns a fully detached child to translate + synthesize + play,
and returns before that child has done anything, typically well under 150 ms.
It also prints nothing, deliberately: Claude Code folds a `UserPromptSubmit`
hook's stdout into the turn's context, which is not where a stray debug line
belongs.

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

**Quickstart:** `register-tts-host.sh` does all three steps below in one shot
— starts `claude-tts-speakd` here, adds/updates the `Host` block in
`~/.ssh/config`, and installs `claude-tts-speak` + hooks on the remote:

```sh
claude-code/register-tts-host.sh --register remote            # open, single-user
claude-code/register-tts-host.sh --register remote --token     # shared host: adds a token at both ends
```

It's idempotent — safe to re-run after changing `--port` or adding `--token`
later. See `--help` for `--local-only` / `--remote-only` / `--no-hook`.

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

Or skip scp entirely: while a tunnel from the remote is up, `claude-tts-speakd`
serves its own scripts, so the remote can pull them straight through it:

```sh
# on the remote, with an ssh session holding the RemoteForward open:
curl -fsSL http://127.0.0.1:17999/claude-tts-speak -o ~/.local/bin/claude-tts-speak \
  && chmod +x ~/.local/bin/claude-tts-speak

curl -fsSL http://127.0.0.1:17999/install.sh   # full installer, same deal
```

`/claude-tts-speak` is always servable (the daemon knows its own copy);
`/install.sh` additionally needs to know where a checkout lives — launch
`claude-tts-speakd` from one or point `CLAUDE_TTS_SERVE_DIR` at it. These GETs
never ask for `CLAUDE_TTS_TOKEN`: they hand out code, not secrets, and
bootstrapping is exactly when no shared secret exists yet.

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

## Over Tailscale (tailnet)

SSH tunnels only exist while a session is connected. For devices that come and
go on their own schedule — another laptop, an iPad, a phone — put
`claude-tts-speakd` behind **Tailscale Serve** instead:

```sh
claude-code/setup-tunnel.sh            # --serve is the default
```

That gives it a stable `https://<host>.<tailnet>.ts.net` URL reachable from
any device signed into *your* tailnet, with valid TLS and no router port
opened. The public internet sees nothing, so no token is required (set one at
both ends anyway if you share the tailnet with people who shouldn't be able to
trigger your speakers).

From any other tailnet machine:

```sh
# plain curl — installs nothing:
curl -X POST https://<host>.<tailnet>.ts.net/speak \
  -H 'Content-Type: application/json' -d '{"text":"ずんだもんだよ"}'

# claude-tts-speak hooks on a remote host, no SSH tunnel config needed:
export CLAUDE_TTS_FORWARD=https://<host>.<tailnet>.ts.net

# opencode-tts-dispatch there (the opencode plugin stays unmodified):
export TTS_FORWARD=https://<host>.<tailnet>.ts.net
```

`claude-tts-speakd` keeps listening on loopback — Serve is just a reverse
proxy in front of it, so `CLAUDE_TTS_BIND`, the port, and everything else stay
as they were. `claude-code/setup-tunnel.sh --off` tears it down again without
touching the daemon.

## Claude Code Web

[Claude Code on the web](https://claude.ai/code) runs your session in
Anthropic's cloud, not on your machine, so `~/.claude/settings.json` never
reaches it (only the repo's own `.claude/settings.json`, or org-managed
settings) and there are no speakers to synthesize to. Same fix as SSH, one
layer up: instead of tunneling over an SSH session that doesn't exist here,
expose `claude-tts-speakd` to the **public internet** via Tailscale Funnel —
Serve's tailnet-only sibling (see above) is not enough, because Anthropic's
cloud is no tailnet member.

```sh
claude-code/setup-hooks.sh --project   # commit .claude/settings.json
claude-code/setup-tunnel.sh --funnel   # brings up the Funnel, generates
                                       # CLAUDE_TTS_TOKEN if you don't have
                                       # one, prints what to paste where
claude-code/register-web-env.sh        # (optional) puts that on your
                                       # clipboard and opens claude.ai/code
```

Then, in the environment dialog (cloud icon above the message box on
claude.ai/code → Add/edit environment): set **Network access** to Custom with
the Funnel hostname allowed, and add `CLAUDE_TTS_FORWARD` / `CLAUDE_TTS_TOKEN`
as **Environment variables**. There is no API for this step — it is a web-UI
dialog only, which is what `register-web-env.sh` works around by getting the
exact values onto your clipboard instead of you retyping them.

`claude-code/setup-tunnel.sh --off` tears the Funnel (or Serve) down again
without touching `claude-tts-speakd` or your token.

## Notification banners (Discord, etc.)

`mac-notify-watch` speaks *any app's* notification banners aloud -- Discord
included -- by watching NotificationCenter's Accessibility tree for new
banner windows and reading the sender/title/body text straight out of it,
then handing that to `claude-tts-speak --text`. There is no public API for
"tell me when an app posts a notification", so this is the same technique
other notification-mirroring tools use.

```
Discord (or any app) posts a notification
        │  NotificationCenter draws a banner
        ▼
  mac-notify-watch ── AXObserver on NotificationCenter ──► sender/title/body text
        │
        ▼
  claude-tts-speak --translate --text "..." ──► dispatcher ──► VOICEVOX/voiceger ──► afplay
```

### Setup

```sh
./install.sh --with-notify-watch     # macOS only; combine with other flags freely
```

This builds the binary, writes `~/Library/LaunchAgents/com.opencode-tts.notify-watch.plist`,
and loads it -- but it does nothing until you grant it Accessibility access:
**System Settings > Privacy & Security > Accessibility**, add
`~/.local/bin/mac-notify-watch` (a "wants access" prompt should appear the
first time it runs; add it there, or find it in the file picker). It picks
this up automatically, no restart needed.

By default it speaks *every* banner from every app. Narrow that with
`NOTIFY_TTS_INCLUDE`/`NOTIFY_TTS_EXCLUDE` in the plist's `EnvironmentVariables`
block (comma-separated, matched against the banner's sender/app-name text,
case-insensitive) -- e.g. `NOTIFY_TTS_INCLUDE=discord` to only speak Discord.
Reload after editing:

```sh
launchctl bootout gui/$(id -u)/com.opencode-tts.notify-watch
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.opencode-tts.notify-watch.plist
```

| Variable | Default | |
|---|---|---|
| `NOTIFY_TTS_SPEAK` | `~/.local/bin/claude-tts-speak` | what actually speaks the text |
| `NOTIFY_TTS_VOICE` | `CLAUDE_TTS_VOICE`'s default (Zundamon) | VOICEVOX voice for notifications, e.g. `hau`, `metan:sexy` -- overrides `CLAUDE_TTS_VOICE` for this process only, so notifications can sound different from Claude Code replies |
| `NOTIFY_TTS_INCLUDE` | unset (all apps) | comma-separated substrings; only speak a banner whose sender/app name contains one |
| `NOTIFY_TTS_EXCLUDE` | unset | comma-separated substrings to always skip, checked first |
| `NOTIFY_TTS_MAXCHARS` | `200` | cap on how much of a notification gets spoken |
| `NOTIFY_TTS_DEDUP_SECS` | `30` | drop an identical banner seen again within this many seconds (some banners fire more than one AX event) |
| `NOTIFY_TTS_DEBUG` | unset | `1` to log what it sees/skips/speaks to `~/Library/Logs/mac-notify-watch.log` |

**Limits, by construction:**
- Only sees notifications that actually draw a banner/alert on screen -- Do
  Not Disturb, Scheduled Summary delivery, and per-app "silence" settings are
  as invisible to this as they are to you.
- If NotificationCenter itself restarts (a crash, essentially never in normal
  use), `mac-notify-watch` needs a restart too -- it attaches to a specific
  process id, not "whichever process currently owns the bundle id". `launchctl
  kickstart -k gui/$(id -u)/com.opencode-tts.notify-watch` if banners stop
  triggering speech and NotificationCenter is running fine.
- Verified on real hardware 2026-08-21. NotificationCenter's grouped
  history/list panel fires the same `kAXWindowCreatedNotification` as a
  fresh banner, with an AX tree that looks identical (`AXWindow` /
  `AXSystemDialog` either way) -- there is no clean role/subrole
  distinction to filter on. Two known-noisy shapes are filtered: the
  literal "No recent notifications" empty-state placeholder, and windows
  carrying more than one relative-time marker ("2m ago", "3分前", ...),
  which is what the grouped list looks like when multiple past
  notifications get swept up together. **Not fully solved**: a single
  earlier notification that never fired its own window-created event (per
  the app-grouping behavior above) can still get tacked onto the *next*
  unrelated notification's capture, since that shape only ever carries one
  time marker and the genuinely fresh content happens to lead. If banners
  ever come out obviously stitched together from two unrelated topics,
  that's this.
- An app's *first* notification in a session reliably fires a fresh AX
  event; rapid repeats from the *same* app afterward often don't fire one
  at all (NotificationCenter appears to update its existing group for that
  app in place instead) -- confirmed empirically with `terminal-notifier`
  and `osascript -e 'display notification'`, not documented behavior.
  Real, distinct apps notifying throughout the day are unaffected; this
  only bit synthetic same-source test loops.
- Rebuilding the binary changes its ad-hoc code-signature hash, which
  invalidates any existing Accessibility grant even though the file path
  and name are unchanged -- expect to remove and re-add it in System
  Settings > Privacy & Security > Accessibility after every rebuild.

## Tuning

| Variable | Default | |
|---|---|---|
| `CLAUDE_TTS_SENTENCES` | `2` | how many sentences to read |
| `CLAUDE_TTS_MAXCHARS` | `350` | hard cap before truncating |
| `CLAUDE_TTS_RATE` | `+25%` | passed through to the dispatcher |
| `CLAUDE_TTS_VOICE` | `ja-JP-ZundamonNeural` | which voice speaks Claude's replies |
| `CLAUDE_TTS_USER_VOICE` | unset | which voice speaks your prompts (`--user-prompt`); unset disables it |
| `CLAUDE_TTS_TRANSLATE_TO` | `Japanese` | `--translate` / `--user-prompt` target language |
| `CLAUDE_TTS_PROMPT_MAXCHARS` | `200` | cap on how much of a prompt gets spoken |
| `CLAUDE_TTS_TRUNCATED_SUFFIX` | `" See the full reply for the rest."` | appended when `speakable()` actually cuts something; empty to disable |
| `CLAUDE_TTS_KEYWORD_LIMIT` | `3` | keywords from the omitted text named in that suffix; `0` disables |
| `CLAUDE_TTS_MAC_NATIVE` | macOS: on | `0` to skip mac-translate/mac-summarize and go straight to the chain below |
| `CLAUDE_TTS_MAC_TRANSLATE` / `CLAUDE_TTS_MAC_SUMMARIZE` | `~/.local/bin/mac-translate` / `mac-summarize` | binary paths (built by `install.sh` on macOS with a Swift toolchain) |
| `CLAUDE_TTS_MAC_SOURCE_LANG` / `CLAUDE_TTS_MAC_TARGET_LANG` | `en` / `ja` | languages passed to mac-translate |
| `CLAUDE_TTS_MAC_TIMEOUT` | `20` | seconds before giving up on either mac- binary |
| `CLAUDE_TTS_SUMMARY_URL` | unset | self-hosted OpenAI-compatible endpoint(s) for `--summarize`/`--translate`; see `examples/README.md` |
| `CLAUDE_TTS_SUMMARY_MODEL` | unset | model for endpoints in `CLAUDE_TTS_SUMMARY_URL` that don't name their own |
| `CLAUDE_TTS_SUMMARY_CLAUDE` | unset | `1` to fall back to the `claude` CLI -- a real API call, opt-in |
| `CLAUDE_TTS_SUMMARY_OPENCODE` | unset | `1` to fall back to `opencode run` -- also a real API call, tried after `CLAUDE_TTS_SUMMARY_CLAUDE` |
| `CLAUDE_TTS_OPENCODE_BIN` | found on `PATH` | path to the `opencode` CLI |
| `CLAUDE_TTS_OPENCODE_MODEL` | unset | pin a model instead of picking the cheapest `CLAUDE_TTS_OPENCODE_PROVIDER` one at runtime |
| `CLAUDE_TTS_OPENCODE_PROVIDER` | `opencode-go` | provider to pick the cheapest model from |
| `CLAUDE_TTS_OPENCODE_PRICE_TTL` | `21600` (6h) | how long the price/known-bad cache is trusted |
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
  one, so replies do not pile up on top of each other -- this applies across
  `--user-prompt` and the Stop hook too, sharing one "currently speaking" slot,
  so an assistant reply that lands while your own prompt is still being read
  back correctly cuts it off rather than overlapping.
- **What gets spoken** is prose only: fenced code, tables, URLs, and inline code
  that looks like a path, flag, or command are dropped, because they are
  unlistenable read aloud.
