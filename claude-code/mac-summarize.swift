// mac-summarize: headless CLI over Apple's Foundation Models framework (the
// on-device Apple Intelligence LLM), so claude-tts-speak can summarize
// on-device instead of a paid opencode/claude call or a several-GB local
// model of its own.
//
// Needs macOS 26+ and Apple Intelligence enabled -- System Settings >
// Apple Intelligence & Siri. If it isn't (SystemLanguageModel.availability
// != .available), this prints why and exits non-zero rather than hanging,
// and the caller (claude-tts-speak) falls back to its existing chain.
//
// Usage: mac-summarize <text on stdin>
//   echo "..." | mac-summarize
//
// Build: swiftc -O mac-summarize.swift -o mac-summarize

import Foundation
import FoundationModels

let text = String(data: FileHandle.standardInput.readDataToEndOfFile(),
                   encoding: .utf8) ?? ""
guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    FileHandle.standardError.write("mac-summarize: no input on stdin\n".data(using: .utf8)!)
    exit(2)
}

let model = SystemLanguageModel.default
guard case .available = model.availability else {
    FileHandle.standardError.write(
        "mac-summarize: model unavailable (\(model.availability))\n".data(using: .utf8)!)
    exit(1)
}

let instructions = """
Summarize the user's text as spoken audio copy in 2 short sentences. Keep \
concrete facts, decisions, and next actions. Do not mention that this is a \
summary. No markdown, no bullets, no preamble, plain text only.
"""

Task {
    do {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: text)
        print(response.content)
        exit(0)
    } catch {
        FileHandle.standardError.write("mac-summarize: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}
RunLoop.main.run()
