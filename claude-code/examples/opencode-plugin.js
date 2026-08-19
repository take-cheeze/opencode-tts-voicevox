/**
 * Zundamon TTS for opencode.
 *
 * Replaces the opencode-tts plugin. It speaks the assistant's reply when a
 * session goes idle, announces permission prompts, and optionally reads your
 * own prompt back in a different voice (OPENCODE_TTS_USER_VOICE) via
 * chat.message, translated first since VOICEVOX only understands Japanese --
 * the same claude-tts-speak --translate this project's Claude Code hook uses,
 * so there is no separate model or code path to maintain for opencode.
 *
 * Everything downstream lives in claude-tts-speak: summarizing, translating,
 * synthesis, playback, remote forwarding and barge-in. This file only decides
 * *when* to speak and *what* text to hand over, which is why it is this short.
 *
 * On a host reached over SSH with `RemoteForward 17999`, claude-tts-speak
 * forwards to the machine with the speakers, and the summarizing/translating
 * happens there too -- so a remote box needs no model, no voice assets and no
 * audio device.
 *
 * Deliberately avoids the plugin's `$` shell: Bun Shell has no `command`
 * builtin, which is the trap that makes opencode-tts report "No audio player
 * found" on Linux while ffplay sits on PATH.
 *
 * chat.message is awaited by opencode -- it blocks the pipeline until the
 * promise resolves -- so, like every other hook here, it must never await the
 * spawned process itself; only the (near-instant) act of spawning it.
 *
 * Env:
 *   OPENCODE_TTS_DISABLED=1     turn it off
 *   OPENCODE_TTS_NO_SUMMARY=1   speak the reply verbatim instead of summarizing
 *   OPENCODE_TTS_TRANSLATE_REPLIES=1  translate the reply to Japanese first,
 *                               so it goes out through the VOICEVOX voice
 *                               instead of voiceger's single English one --
 *                               off by default: whether you want your own
 *                               language back is not this plugin's call to
 *                               make for you the way it is for your own
 *                               already-Japanese-if-you-want-it prompt
 *   OPENCODE_TTS_ASK_PHRASE     what to say on a permission prompt
 *   OPENCODE_TTS_MAXCHARS       cap on text handed over (default 60000)
 *   OPENCODE_TTS_USER_VOICE     voice for your own prompts (chat.message);
 *                               unset disables that hook entirely, e.g. "metan"
 *   OPENCODE_TTS_PROMPT_MAXCHARS cap on how much of a prompt gets spoken (default 200)
 */
const SPEAK = `${process.env.HOME}/.local/bin/claude-tts-speak`
const ASK_PHRASE = process.env.OPENCODE_TTS_ASK_PHRASE ?? "コマンドの確認をお願いするのだ。"
const SUMMARIZE = process.env.OPENCODE_TTS_NO_SUMMARY !== "1"
const TRANSLATE_REPLIES = process.env.OPENCODE_TTS_TRANSLATE_REPLIES === "1"
const MAXCHARS = Number(process.env.OPENCODE_TTS_MAXCHARS ?? 60000)
const USER_VOICE = process.env.OPENCODE_TTS_USER_VOICE ?? ""
const PROMPT_MAXCHARS = Number(process.env.OPENCODE_TTS_PROMPT_MAXCHARS ?? 200)

/** Fire and forget. A prompt or a turn must never wait on audio. */
function speak(args, extraEnv) {
  if (process.env.OPENCODE_TTS_DISABLED === "1") return
  try {
    Bun.spawn([SPEAK, ...args], {
      stdin: "ignore", stdout: "ignore", stderr: "ignore",
      env: extraEnv ? { ...process.env, ...extraEnv } : process.env,
    }).unref()
  } catch {
    // no sound is acceptable; a stalled session is not
  }
}

export const ZundamonTts = async () => {
  // messageID -> latest text; sessionID -> latest assistant messageID
  const textByMessage = new Map()
  const latestBySession = new Map()
  const spoken = new Set()

  return {
    "permission.ask": async (_input, _output) => {
      // _output.status is deliberately untouched: writing it would answer the
      // prompt rather than announce it.
      speak(["--text", ASK_PHRASE])
    },

    "chat.message": async (_input, output) => {
      if (!USER_VOICE) return  // off unless a distinct voice is configured
      // `output` is mutable (plugins can rewrite the message before it goes
      // to the model) but is deliberately not touched here -- same reason
      // permission.ask leaves output.status alone.
      const text = (output.parts ?? [])
        .filter((p) => p.type === "text")
        .map((p) => p.text ?? "")
        .join("")
        .trim()
      if (!text) return
      const payload = text.length > PROMPT_MAXCHARS ? text.slice(0, PROMPT_MAXCHARS) : text
      speak(["--translate", "--text", payload], { CLAUDE_TTS_VOICE: USER_VOICE })
    },

    event: async ({ event }) => {
      if (event.type === "message.updated") {
        const info = event.properties.info
        if (info?.role === "assistant") latestBySession.set(info.sessionID, info.id)
        return
      }

      if (event.type === "message.part.updated") {
        const part = event.properties.part
        // Parts stream in and are replaced as they grow, so keep the newest.
        if (part?.type === "text" && part.messageID) {
          textByMessage.set(part.messageID, part.text ?? "")
        }
        return
      }

      if (event.type !== "session.idle") return

      const messageID = latestBySession.get(event.properties.sessionID)
      if (!messageID || spoken.has(messageID)) return
      const text = (textByMessage.get(messageID) ?? "").trim()
      if (!text) return

      spoken.add(messageID)
      // Unbounded Maps would grow for the life of the process.
      if (spoken.size > 200) {
        for (const k of [...spoken].slice(0, 100)) spoken.delete(k)
        for (const k of [...textByMessage.keys()].slice(0, 100)) textByMessage.delete(k)
      }

      const payload = text.length > MAXCHARS ? text.slice(0, MAXCHARS) : text
      const args = []
      if (TRANSLATE_REPLIES) args.push("--translate")
      if (SUMMARIZE) args.push("--summarize")
      args.push("--text", payload)
      speak(args)
    },
  }
}
