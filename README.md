# opencode-tts-voicevox — Zundamon TTS for [opencode](https://opencode.ai)

A fully **local** [opencode-tts](https://www.npmjs.com/package/opencode-tts)
backend that makes **Zundamon** speak your assistant's summaries — no
Microsoft endpoint, no cloud TTS.

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
                                       └─ English/other ─► voiceger server (:8123) ─► Zundamon
                                                              (GPT-SoVITS, CPU)
```

## Layout

| Path                    | What |
|-------------------------|------|
| `opencode-tts-dispatch` | the `edge_tts` lookalike; routes by CJK detection |
| `voicevox/`             | C shim (`opencode-tts-voicevox.c`), `Makefile`, `fetch-voicevox.sh` (asset download) |
| `voiceger/`             | `setup-voiceger.sh` (installs the GPT-SoVITS stack), `tts_server.py` (FastAPI), `run-voiceger-server.sh`, systemd unit, `requirements.txt` |
| `config/opencode-tts.jsonc.template` | sample plugin config |
| `install.sh`            | one-shot installer for both backends |

## Install

```sh
git clone https://github.com/take-cheeze/opencode-tts-voicevox
cd opencode-tts-voicevox
./install.sh                 # both backends
# or
./install.sh --skip-voiceger # Japanese/CJK only (skips the ~GB model download)
```

`install.sh` builds the C shim, installs the dispatcher, (optionally) sets up
voiceger + a `systemd --user` service, writes the plugin config, and registers
`opencode-tts`. **Restart opencode** afterwards.

### Voicevox shim (Japanese/CJK)
- `voicevox/opencode-tts-voicevox.c` dlopen()s `libvoicevox_core.so` + a
  Zundamon `.vvm` + Open JTalk dict and synthesizes a WAV.
- `voicevox/fetch-voicevox.sh` downloads a pinned, checksummed asset set (~90 MiB).

### Voiceger (English/other)
- `voiceger/setup-voiceger.sh` creates a Python 3.10 venv, installs
  torch 2.1.2 + deps, downloads the Zundamon fine-tune + GPT-SoVITS
  pretrained models, and installs the NLTK English tagger.
- `voiceger/tts_server.py` is a FastAPI server: `POST /tts`, `GET /ping`.
- `voiceger/opencode-tts-voiceger.service` (installed to
  `~/.config/systemd/user/`) keeps the server running:
  `systemctl --user status opencode-tts-voiceger`

## Notes & caveats

- **GPU**: torch 2.1.2 (cu121) predates Blackwell; an RTX 5050 (compute 12.0)
  falls back to CPU. Set `VOICEGER_DEVICE=cuda` once a compatible torch is
  installed. CPU inference is slow-but-fine for 2-sentence summaries.
- **Env isolation**: under direnv/Nix the exported `PYTHONPATH` (Nix Python
  3.13) leaks into the 3.10 venv and breaks imports. The launchers unset it.
- **jieba_fast / pyopenjtalk** have no clean cp310 wheels and are handled in
  `setup-voiceger.sh` (forwarder shim + clean-env build).
- **License**: audio generated with the Zundamon voice must be credited
  **VOICEVOX:ずんだもん** per [zunko.jp](https://zunko.jp/con_ongen_kiyaku.html).
