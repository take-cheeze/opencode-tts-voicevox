# opencode-tts-voicevox — Zundamon TTS for [opencode](https://opencode.ai)

A fully **local** [opencode-tts](https://www.npmjs.com/package/opencode-tts)
backend that makes **Zundamon** — or 四国めたん, 春日部つむぎ, 雨晴はう — speak
your assistant's summaries; no Microsoft endpoint, no cloud TTS.

It dispatches by language:

| Language                | Engine                              | Why |
|-------------------------|-------------------------------------|-----|
| **Japanese / CJK**      | VOICEVOX CORE (C shim)              | fast, offline, GPU-free |
| **English / other**     | voiceger — [Audio8-TTS-Preview-0.1b](https://huggingface.co/Audio8/Audio8-TTS-Preview-0.1b), zero-shot Zundamon voice clone | small, CPU-viable, multilingual |

voiceger can also run
[Audio8-TTS-Preview-0.6B-ONNX-INT4](https://huggingface.co/Audio8/Audio8-TTS-Preview-0.6B-ONNX-INT4)
(`VOICEGER_ENGINE=audio8-onnx`) — the official quantized build, a larger
model but a smaller runtime footprint (~1GB vs ~1.4-5GB for the default) and
Apache-2.0 licensed — or
[KRAFTON/Raon-OpenTTS-1B](https://huggingface.co/KRAFTON/Raon-OpenTTS-1B)
(`VOICEGER_ENGINE=raon`) — English-only, a much heavier ~16.7GB checkpoint,
and GPU-recommended; see [Voiceger (English/other)](#voiceger-englishother)
below.

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
                                                              (Audio8-TTS, CPU)
```

## Layout

| Path                    | What |
|-------------------------|------|
| `opencode-tts-dispatch` | the `edge_tts` lookalike; routes by CJK detection |
| `voicevox/`             | C shim (`opencode-tts-voicevox.c`), `Makefile`, `fetch-voicevox.sh` (asset download) |
| `voiceger/`             | `setup-voiceger.sh` (installs the TTS stack), `tts_server.py` (FastAPI, engines: `audio8` default / `audio8-onnx` opt-in / `raon` opt-in), `run-voiceger-server.sh`, systemd unit + launchd agent, `requirements.txt` |
| `config/opencode-tts.jsonc.template` | sample plugin config |
| `install.sh`            | one-shot installer for both backends |

## Requirements

| | |
|---|---|
| **OS** | Linux (x86_64) or macOS (Apple silicon or Intel) |
| **Build** | a C compiler — `build-essential` on Linux, Xcode command line tools on macOS |
| **Runtime** | `ffmpeg` (WAV → MP3), `python3`, and `curl` + `unzip` for the asset download |
| **voiceger only** | [`uv`](https://docs.astral.sh/uv/) |

On macOS: `xcode-select --install && brew install ffmpeg uv`.

## Install

```sh
git clone https://github.com/take-cheeze/opencode-tts-voicevox
cd opencode-tts-voicevox
./install.sh --clone-src     # both backends; clones voiceger_v2 if missing
# or
./install.sh --skip-voiceger # Japanese/CJK only (skips the ~GB model download)
# or
./install.sh --translate-always # same as --skip-voiceger, if this box's
                              # hooks always translate to Japanese first --
                              # voiceger's English path would never run
# or
./install.sh --clone-src --with-raon # also install the optional, heavier
                              # KRAFTON/Raon-OpenTTS-1B engine (English-only,
                              # ~16.7GB checkpoint, GPU-recommended)
# or
./install.sh --clone-src --with-audio8-onnx # also install the official
                              # Audio8-TTS-Preview-0.6B-ONNX-INT4 build
                              # (~1GB runtime footprint, Apache-2.0)
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
- `voiceger/setup-voiceger.sh` creates a Python venv and installs torch +
  `transformers` + deps. It also needs the voiceger_v2 tree (~37 MiB) purely
  for its `reference/` Zundamon voice clip + transcript — pass `--clone-src`
  to fetch it if you do not already have one, or point `VOICEGER_SRC` at your
  checkout otherwise. Pass `--with-raon` and/or `--with-audio8-onnx` to also
  install those optional engines.
- `voiceger/tts_server.py` is a FastAPI server: `POST /tts`, `GET /ping`. It
  loads one of three engines, chosen by `VOICEGER_ENGINE`:
  - `audio8` *(default)* — [Audio8-TTS-Preview-0.1b](https://huggingface.co/Audio8/Audio8-TTS-Preview-0.1b),
    a small (~170M+120M param) multilingual zero-shot voice-cloning model,
    loaded via plain `transformers` (`trust_remote_code=True`). Its weights
    download through the normal Hugging Face cache the first time the server
    starts. CPU-viable, but synthesis peaks at 3.5-5GB RSS (see
    [Resource usage](#resource-usage)).
  - `audio8-onnx` — [Audio8-TTS-Preview-0.6B-ONNX-INT4](https://huggingface.co/Audio8/Audio8-TTS-Preview-0.6B-ONNX-INT4),
    Audio8's own official quantized build via
    [github.com/Audio8-AI/Audio8_TTS](https://github.com/Audio8-AI/Audio8_TTS)'s
    `arktts_runtime` (pure `onnxruntime`, no PyTorch needed — runs fine
    under this same venv despite the standalone project asking for Python
    3.11+). Larger model (0.6B vs 0.1b) but a much smaller runtime footprint
    (~1-2.3GB vs ~1.4-5GB), Apache-2.0 licensed, and 11 languages. Unlike the
    other two engines it registers a named "voice profile" from
    `VOICEGER_REF`/`VOICEGER_REF_TEXT` once at startup (`arktts_runtime`'s
    own model) rather than taking reference audio per request; installed by
    `setup-voiceger.sh --with-audio8-onnx`, which clones the runtime repo to
    `VOICEGER_ONNX_SRC` (default `~/dev/Audio8_TTS`) and downloads the model.
  - `raon` — [Raon-OpenTTS-1B](https://huggingface.co/KRAFTON/Raon-OpenTTS-1B),
    KRAFTON's F5-TTS-based model. **English-only**, needs its own pip package
    (installed by `setup-voiceger.sh --with-raon`) plus a ~16.7GB checkpoint,
    and has not been verified to run at an acceptable speed on CPU — treat it
    as experimental, for a box with a working GPU.
  All three clone the same Zundamon reference clip voiceger already ships
  with, so switching between them is just
  `VOICEGER_ENGINE=audio8|audio8-onnx|raon`.
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
cloned Zundamon voice, whatever `--voice` says.

## Pronunciation dictionary

OpenJtalk's base dictionary does not know most dev jargon (`API`, `README`,
`git`, ...) and falls back to spelling it out letter by letter. `install.sh`
fixes the terms listed in `voicevox/user_dict_terms.tsv` by compiling them
into a VOICEVOX user dictionary (`assets/user_dict.json`), which
`opencode-tts-voicevox` loads automatically — no flag or env var needed once
it's built once.

Add a term and re-run, or rebuild by hand:

```sh
# surface	pronunciation	accent_type	word_type	priority
echo -e 'Zenn\tゼン\t0\tPROPER_NOUN\t10' >> voicevox/user_dict_terms.tsv
opencode-tts-voicevox --build-user-dict voicevox/user_dict_terms.tsv "$VOICEVOX_DIR/user_dict.json"
```

`VOICEVOX_USER_DICT` overrides the dictionary path if you keep it somewhere
other than `$VOICEVOX_DIR/user_dict.json`.

### No manual dictionary maintenance required

Two things work together so `user_dict_terms.tsv` never *has* to be hand-edited:

1. **Every text-generation step already in the pipeline is told to spell
   jargon in katakana.** When `claude-tts-speak` translates or summarizes via
   an LLM (self-hosted endpoint, `claude`/`opencode` CLI fallback, or
   `mac-summarize` on-device), the prompt asks it to render unfamiliar
   product names, acronyms, and technical terms as katakana approximating
   their pronunciation instead of leaving them in the Latin alphabet. This
   catches most jargon *before* it ever reaches VOICEVOX/OpenJtalk.
2. **What still reaches VOICEVOX untranslated is learned automatically.**
   `claude-tts-speak` scans the *final* text right before speaking it --
   after translate/summarize have already run, so this is the actual
   Japanese VOICEVOX receives, not the (usually English) source -- and
   records any identifier still left in Latin script -- `LangChain`, `RAG`,
   `Krafton`, ... -- to `~/.local/share/opencode-tts-speakd/unknown_words.txt`.
   (`claude-tts-speakd`, the SSH-forwarding receiver, spawns this same
   script for every request rather than detecting jargon itself, since it
   never sees the translated result -- that only exists inside the spawned
   process.) A throttled background job then runs
   `voicevox/import-candidates.py --auto-apply`, which guesses a katakana
   reading with the same Hepburn-romanization heuristic `import-candidates.py`
   has always used for its preview suggestions, writes it to
   `~/.local/share/opencode-tts-speakd/auto_dict_terms.tsv` (never to the
   hand-curated `user_dict_terms.tsv` above), and rebuilds the compiled
   dictionary -- so a word mispronounced once is usually fixed by the next
   time it comes up, with nothing to review or copy in. Disable with
   `CLAUDE_TTS_AUTO_DICT=0`.

If an auto-generated reading turns out wrong (multi-syllable proper nouns are
the usual culprit), the fix is the "add a term" step above: a hand-curated
entry in `user_dict_terms.tsv` always takes precedence over an
auto-generated one for the same word -- both files are merged on every
rebuild, curated first.

To curate from the collected candidates by hand instead of relying on
`--auto-apply`, preview and append them as placeholders for review:

```sh
# preview what would be imported, then append each as a pending candidate
python3 voicevox/import-candidates.py
python3 voicevox/import-candidates.py --write
# supply the kana reading for each new line, then rebuild
python3 voicevox/import-candidates.py --write --build
```

Turn candidate collection and the auto-apply rebuild off entirely with
`CLAUDE_TTS_AUTO_DICT=0`, set wherever `claude-tts-speak` actually runs
(when forwarding over SSH, that's the receiver's environment --
`claude-tts-speakd` passes its own environment through to the
`claude-tts-speak` process it spawns for every request).

## Resource usage

Measured on an Apple **M4 Mac mini** (10 cores: 4P+6E, 16 GB RAM), all CPU
paths — nothing here uses the M4's GPU except the optional Ollama
summarizer. Your numbers will vary with text length, core count, and
whether a component is cold (first call after startup) or warm. The
`voiceger (audio8)` rows are for the `VOICEGER_ENGINE=audio8` default
(Audio8-TTS-Preview-0.1b); `voiceger (audio8-onnx)` is the
`Audio8-TTS-Preview-0.6B-ONNX-INT4` engine; `raon` has not been measured.

| Component | Model | Peak RSS | GPU | Time |
|---|---|---|---|---|
| `opencode-tts-voicevox` (per-invocation CLI) | short (6 chars) | 420 MB | none (CPU) | 0.9 s |
| | medium (40 chars) | 550 MB | none (CPU) | 1.9 s |
| | long (~80 chars) | 840 MB | none (CPU) | 2.9 s |
| audio player (`afplay`, per-invocation) | ~75 CJK chars | 20 MB | none | duration of the clip |
| `voiceger` (`tts_server.py`, `audio8`, persistent) | idle, model loaded | 1.4 GB | none (CPU¹) | — |
| | warm request, short sentence (~6s audio) | 3.5 GB | none (CPU¹) | 11.1 s |
| | warm request, longer sentence (~10s audio) | 5.1 GB | none (CPU¹) | 14.0 s |
| `voiceger` (`tts_server.py`, `audio8-onnx`, persistent) | idle, model loaded | 1.0 GB | none (CPU) | — |
| | warm request (~8-11s audio) | 2.0-2.3 GB³ | none (CPU) | 5-8 s |
| Ollama summarizer (`qwen2.5:1.5b`, persistent) | cold (loads into GPU) | 1.1 GB² | 100% | 3.2 s |
| | warm | 1.1 GB² | 100% | 0.7 s |
| `claude-tts-speakd` (idle daemon) | — | 6 MB | none | — |

¹ voiceger defaults to CPU on macOS (`VOICEGER_DEVICE=mps` is opt-in — see
[Notes & caveats](#notes--caveats)). Synthesis roughly triples RSS over idle
and grows further with output length — decode-time buffers for the
autoregressive generation loop (`max_new_tokens=1024`) that PyTorch does not
release back to the OS between requests, so RSS ratchets up to its
high-water mark and stays there rather than returning to the idle baseline.
Budget for the peak (~5 GB seen here), not the idle figure, when sizing a
box that also runs other things. ² GPU-resident via Metal, from `ollama ps`,
not counted in the `ollama serve` process's own RSS. ³ Higher than Audio8's
own published ~1.1-1.2GB synthesis-peak figure for this ONNX build (measured
on an Apple M2); most likely macOS not reclaiming freed pages between
requests the same way — the same effect shows up in the `audio8` rows above,
so it looks like a platform quirk on this box rather than something wrong
with the model.

The VOICEVOX CLI figure includes fixed per-invocation startup (dlopen,
ONNX Runtime init, Open JTalk dictionary, model load) — roughly 400 MB and
0.7-0.9 s before any text-dependent cost, since it is a one-shot process
rather than a resident server. voiceger and Ollama pay a similar one-time
cost only on the *first* request after their model loads.

**With `--skip-voiceger`/`--translate-always`** (see [Install](#install)),
`voiceger` and the Ollama rows above never run — VOICEVOX (CJK-only, since
translation guarantees Japanese text before it reaches the dispatcher) plus
the audio player are the whole footprint, well under 1 GB peak, and the two
barely overlap: the dispatcher writes finished audio to a temp file and
exits before playback starts, so it's sequential, not additive. Swapping the
summarizer/translator from the Ollama endpoint to `CLAUDE_TTS_SUMMARY_OPENCODE=1`
(see `claude-code/README.md`) adds no local RSS of its own either — `opencode
run` is a remote API call, so its cost shows up as latency and API quota, not
memory on this box.

## Notes & caveats

- **GPU**: `setup-voiceger.sh` installs an unpinned `torch` (cu121 index on
  Linux, stock wheels on macOS), so whether an RTX 5050 or similar Blackwell
  card (compute 12.0) gets CUDA support depends on the torch version that
  resolves at install time — check with `VOICEGER_VENV/bin/python -c
  "import torch;print(torch.cuda.is_available())"`. Set `VOICEGER_DEVICE=cuda`
  once it reports `True`. On macOS there is no CUDA build at all — setup
  installs the stock wheels and the service defaults to CPU;
  `VOICEGER_DEVICE=mps` will try the Apple GPU. CPU inference is
  slow-but-fine for 2-sentence summaries with the default `audio8` engine.
- **Env isolation**: under direnv/Nix the exported `PYTHONPATH` (Nix
  site-packages for a different Python version) leaks into the venv and
  breaks imports. The launchers unset it.
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
  terms; `voicevox/assets/models/TERMS.txt` has the summary. The `audio8` and
  `raon` engines' weights are **CC-BY-NC-4.0** (non-commercial) —
  [Audio8-TTS-Preview-0.1b](https://huggingface.co/Audio8/Audio8-TTS-Preview-0.1b)
  and [Raon-OpenTTS-1B](https://huggingface.co/KRAFTON/Raon-OpenTTS-1B). The
  `audio8-onnx` engine's weights are **Apache-2.0** —
  [Audio8-TTS-Preview-0.6B-ONNX-INT4](https://huggingface.co/Audio8/Audio8-TTS-Preview-0.6B-ONNX-INT4).
