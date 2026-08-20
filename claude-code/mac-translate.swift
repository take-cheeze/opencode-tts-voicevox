// mac-translate: headless CLI over Apple's Translation framework, so
// claude-tts-speak can translate on-device (no API, no model process of its
// own -- system-managed, ~0.1s/call per community benchmarks) instead of a
// paid opencode/claude call or a several-GB local model.
//
// Needs macOS 26.4+ (TranslationSession's non-SwiftUI `installedSource:
// target:` init) and the target language pack already installed --
// System Settings > General > Language & Region > Translation Languages.
// There is no headless way to trigger that first download: the framework's
// download UI is anchored to a SwiftUI `.translationTask` view, so this
// prints a clear error and exits non-zero rather than hanging, and the
// caller (claude-tts-speak) falls back to its existing chain.
//
// Usage: mac-translate <source-lang> <target-lang> <text...>
//   mac-translate en ja "The build failed."
//
// Build: swiftc -O mac-translate.swift -o mac-translate

import Foundation
import Translation

guard CommandLine.arguments.count >= 4 else {
    FileHandle.standardError.write(
        "usage: mac-translate <source-lang> <target-lang> <text...>\n".data(using: .utf8)!)
    exit(2)
}

let source = Locale.Language(identifier: CommandLine.arguments[1])
let target = Locale.Language(identifier: CommandLine.arguments[2])
let text = CommandLine.arguments[3...].joined(separator: " ")

Task {
    do {
        let session = TranslationSession(installedSource: source, target: target)
        let response = try await session.translate(text)
        print(response.targetText)
        exit(0)
    } catch {
        FileHandle.standardError.write("mac-translate: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}
RunLoop.main.run()
