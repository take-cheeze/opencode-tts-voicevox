# opencode-tts-voicevox — Zundamon TTS for [opencode](https://opencode.ai)

A fully **local** [opencode-tts](https://www.npmjs.com/package/opencode-tts)
backend that makes **Zundamon** — or 四国めたん, 春日部つむぎ, 雨晴はう — speak
your assistant's summaries; no Microsoft endpoint, no cloud TTS.

It dispatches by language:

| Language                | Engine                              | Why |
|-------------------------|-------------------------------------|-----|
| **Japanese / CJK**      | VOICEVOX CORE (C shim)              | fast, offline, GPU-free |
| **English / other**     | [voiceger](https://github.com/zunzun999/voiceger_v2) — GPT-SoVITS Zundamon fine-tune | natural multilingual |

The opencode-tts plugin only knows about an `edge_tts` command, so we point
it at a small `edge-tts` CLI lookalike, `opencode-tts-dispatch`, which looks
at the text and routes it to the right engine. The plugin is otherwise
untouched (summary step, slash commands, playback all work as-is).

```
                ┌──────────────────────────────┐
 /tts-speak,    │   opencode-tts plugin        │   "edge_tts" backend
 idle, /tts-* ─►│   (unmodified)               │
                └───────────────┬──────────────┘
                                │ --text ... --write-media out.mp3
                                ▼
                ┌──────────────────────────────┐
                │ opencode-tts-dispatch (this) │── CJK ──► opencode-tts-voicevox (C) ─► Zundamon
                │      CJK router             │            └ VOICEVOX CORE (offline)
                └──────────────────────────────┘
                                       └─ English/other ─► voiceger server (:18123) ─► Zundamon
                                                              (GPT-SoVITS, CPU)
```

## Layout

| Path                    | What |
|-------------------------|------|
| `opencode-tts-dispatch` | the `edge_tts` lookalike; routes by CJK detection |
| `voicevox/`             | C shim (`opencode-tts-voicevox.c`), `Makefile`, `fetch-voicevox.sh` (asset download) |
| `voiceger/`             | `setup-voiceger.sh` (installs the GPT-SoVITS stack), `tts_server.py` (FastAPI), `run-voiceger-server.sh`, systemd unit + launchd agent, `requirements.txt` |
| `config/opencode-tts.jsonc.template` | sample plugin config |
| `install.sh`            | one-shot installer for both backends |

## Requirements

| | |
|---|---|
| **OS** | Linux (x86_64) or macOS (Apple silicon or Intel) |
| **Build** | a C compiler — `build-essential` on Linux, Xcode command line tools on macOS |
| **Runtime** | `ffmpeg` (WAV → MP3), `python3`, and `curl` + `unzip` for the asset download |
| **voiceger only** | [`uv`](https://docs.astral.sh/uv/), plus `cmake` on macOS (pyopenjtalk builds from source) |

On macOS: `xcode-select --install && brew install ffmpeg cmake uv`.

## Install

```sh
git clone https://github.com/take-cheeze/opencode-tts-voicevox
cd opencode-tts-voicevox
./install.sh --clone-src     # both backends; clones voiceger_v2 if missing
# or
./install.sh --skip-voiceger # Japanese/CJK only (skips the ~GB model download)
```

`install.sh` builds the C shim, installs the dispatcher, (optionally) sets up
voiceger as a background service, writes the plugin config, and registers
`opencode-tts`. **Restart opencode** afterwards.

The background service is whatever the platform uses — a `systemd --user` unit
on Linux, a launchd user agent on macOS:

| | Linux | macOS |
|---|---|---|
| unit | `~/.config/systemd/user/opencode-tts-voiceger.service` | `~/Library/LaunchAgents/com.opencode-tts.voiceger.plist` |
| status | `systemctl --user status opencode-tts-voiceger` | `launchctl print gui/$(id -u)/com.opencode-tts.voiceger` |
| restart | `systemctl --user restart opencode-tts-voiceger` | `launchctl kickstart -k gui/$(id -u)/com.opencode-tts.voiceger` |
| logs | `journalctl --user -u opencode-tts-voiceger -f` | `tail -f ~/Library/Logs/opencode-tts-voiceger.log` |

### Voicevox shim (Japanese/CJK)
- `voicevox/opencode-tts-voicevox.c` dlopen()s `libvoicevox_core.{so,dylib}` +
  a `.vvm` + Open JTalk dict and synthesizes a WAV.
- `voicevox/fetch-voicevox.sh` downloads a pinned, checksummed asset set
  (~90 MiB) for the host platform — `linux-x64`, `osx-arm64`, or `osx-x64`.

### Voiceger (English/other)
- `voiceger/setup-voiceger.sh` creates a Python 3.10 venv, installs
  torch 2.1.2 + deps, downloads the Zundamon fine-tune + GPT-SoVITS
  pretrained models (~1 GB), and installs the NLTK English tagger.
  Pass `--clone-src` to fetch the voiceger_v2 tree (~37 MiB) if you do not
  already have one; point `VOICEGER_SRC` at your checkout otherwise.
- `voiceger/tts_server.py` is a FastAPI server: `POST /tts`, `GET /ping`.
- `voiceger/opencode-tts-voiceger.service` (Linux) and
  `voiceger/com.opencode-tts.voiceger.plist` (macOS) keep the server running;
  `install.sh` bakes your checkout path into whichever one applies.

## Voices

The downloaded `0.vvm` carries four characters, and `--voice` picks among
them — by name, with an optional style, or by bare VOICEVOX style id:

```sh
opencode-tts-voicevox --list-voices
```

| `--voice` | Speaks as | Styles |
|---|---|---|
| `zundamon` *(default)* | ずんだもん | `:normal` 3, `:amaama` 1, `:tsuntsun` 7, `:sexy` 5 |
| `metan` | 四国めたん | `:normal` 2, `:amaama` 0, `:tsuntsun` 6, `:sexy` 4 |
| `tsumugi` | 春日部つむぎ | `:normal` 8 |
| `hau` | 雨晴はう | `:normal` 10 |

The name is matched loosely, so the edge-tts spellings already in configs keep
working (`ja-JP-ZundamonNeural` → ずんだもん, `ja-JP-MetanNeural` → 四国めたん),
as do the Japanese names and a bare id (`--voice 4`). Anything unrecognized —
an English voice like `en-US-AvaNeural` — falls back to ずんだもん.

Where to set it:

| | |
|---|---|
| opencode | `"voice"` in `~/.config/opencode/plugins/opencode-tts.jsonc` (re-running `install.sh` keeps it) |
| Claude Code hook | `CLAUDE_TTS_VOICE=metan:sexy` |
| anywhere, overriding a hardcoded `--voice` | `VOICEVOX_VOICE=tsumugi` |

Only the Japanese/CJK half has a choice: voiceger speaks English with a single
Zundamon fine-tune, whatever `--voice` says.

## Notes & caveats

- **GPU**: on Linux, torch 2.1.2 (cu121) predates Blackwell; an RTX 5050
  (compute 12.0) falls back to CPU. Set `VOICEGER_DEVICE=cuda` once a
  compatible torch is installed. On macOS there is no CUDA build at all —
  setup installs the stock wheels and the service defaults to CPU;
  `VOICEGER_DEVICE=mps` will try the Apple GPU. CPU inference is
  slow-but-fine for 2-sentence summaries.
- **Env isolation**: under direnv/Nix the exported `PYTHONPATH` (Nix Python
  3.13) leaks into the 3.10 venv and breaks imports. The launchers unset it.
- **jieba_fast / pyopenjtalk** have no clean cp310 wheels and are handled in
  `setup-voiceger.sh` (forwarder shim + clean-env build). The pyopenjtalk
  build compiles C++, so macOS needs the Xcode command line tools and `cmake`.
- **Port**: the server listens on **18123**, not the more obvious 8123 —
  that one collides with ClickHouse's HTTP default and, on macOS, with a
  Visual Studio Code plugin helper. A collision is quiet and nasty: the
  dispatcher happily POSTs summaries at whatever else answered. Override with
  `VOICEGER_PORT` (server) and `VOICEGER_URL` (dispatcher) together.
- **Reference audio**: voiceger clones the voice from a reference clip.
  Upstream ships one wav per emotion rather than a single `reference.wav`,
  so the server picks the first alphabetically (the normal-emotion take,
  which is what `ref_text.txt` transcribes). Override with `VOICEGER_REF`.
- **Remote hosts**: `TTS_FORWARD` makes the dispatcher fetch finished audio
  from a `claude-tts-speakd` instead of synthesizing, so a machine you SSH into
  needs no models and no ffmpeg. See `claude-code/README.md`.
- **License**: audio must be credited to the character that spoke it —
  **VOICEVOX:ずんだもん**, **VOICEVOX:四国めたん**, and so on. See
  [zunko.jp](https://zunko.jp/con_ongen_kiyaku.html) and each character's own
  terms; `voicevox/assets/models/TERMS.txt` has the summary.
