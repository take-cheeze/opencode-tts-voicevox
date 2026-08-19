/**
 * Zundamon TTS for opencode.
 *
 * Replaces the opencode-tts plugin. It speaks the assistant's reply when a
 * session goes idle, and announces permission prompts.
 *
 * Everything downstream lives in claude-tts-speak: summarizing, synthesis,
 * playback, remote forwarding and barge-in. This file only decides *when* to
 * speak and *what* text to hand over, which is why it is this short.
 *
 * On a host reached over SSH with `RemoteForward 17999`, claude-tts-speak
 * forwards to the machine with the speakers, and the summarizing happens there
 * too -- so a remote box needs no model, no voice assets and no audio device.
 *
 * Deliberately avoids the plugin's `$` shell: Bun Shell has no `command`
 * builtin, which is the trap that makes opencode-tts report "No audio player
 * found" on Linux while ffplay sits on PATH.
 *
 * Env:
 *   OPENCODE_TTS_DISABLED=1     turn it off
 *   OPENCODE_TTS_NO_SUMMARY=1   speak the reply verbatim instead of summarizing
 *   OPENCODE_TTS_ASK_PHRASE     what to say on a permission prompt
 *   OPENCODE_TTS_MAXCHARS       cap on text handed over (default 60000)
 */
const SPEAK = `${process.env.HOME}/.local/bin/claude-tts-speak`
const ASK_PHRASE = process.env.OPENCODE_TTS_ASK_PHRASE ?? "コマンドの確認をお願いするのだ。"
const SUMMARIZE = process.env.OPENCODE_TTS_NO_SUMMARY !== "1"
const MAXCHARS = Number(process.env.OPENCODE_TTS_MAXCHARS ?? 60000)

/** Fire and forget. A prompt or a turn must never wait on audio. */
function speak(args) {
  if (process.env.OPENCODE_TTS_DISABLED === "1") return
  try {
    Bun.spawn([SPEAK, ...args], {
      stdin: "ignore", stdout: "ignore", stderr: "ignore",
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
      speak(SUMMARIZE ? ["--summarize", "--text", payload] : ["--text", payload])
    },
  }
}
