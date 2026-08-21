// mac-notify-watch: speak macOS notification banners aloud, through the same
// Zundamon TTS stack Claude Code and opencode use.
//
// There is no public API for "tell me when any app posts a notification" --
// Apple locked that down years ago. Instead this watches the process that
// draws the banners (com.apple.notificationcenterui) via the Accessibility
// API for new banner windows, reads the sender/title/body text straight out
// of the AX tree, and hands it to claude-tts-speak --text.
//
// Needs Accessibility access for THIS BINARY: System Settings > Privacy &
// Security > Accessibility. Only sees notifications that actually display a
// banner/alert on screen -- Do Not Disturb, Scheduled Summary delivery, and
// per-app "silence" settings are invisible to this the same way they would
// be to a human glancing at the screen. If NotificationCenter itself
// restarts (rare outside a crash), this process needs a restart too --
// AXObserver attaches to a specific pid, not "whichever process currently
// owns the bundle id".
//
// Build: swiftc -O mac-notify-watch.swift -o mac-notify-watch
//
// Environment:
//   NOTIFY_TTS_SPEAK     path to claude-tts-speak (default ~/.local/bin/claude-tts-speak)
//   NOTIFY_TTS_VOICE     VOICEVOX voice for notifications, e.g. "hau" or
//                        "metan:sexy" (default: whatever CLAUDE_TTS_VOICE is
//                        set to, else claude-tts-speak's own default,
//                        Zundamon) -- overrides CLAUDE_TTS_VOICE for this
//                        process only, same idea as CLAUDE_TTS_USER_VOICE
//                        distinguishing your own prompts from Claude's replies
//   NOTIFY_TTS_INCLUDE   comma-separated substrings; only speak notifications
//                        whose first text line (sender/app name) contains one,
//                        case-insensitive. Empty (default) = speak everything.
//   NOTIFY_TTS_EXCLUDE   comma-separated substrings to always skip, checked
//                        before NOTIFY_TTS_INCLUDE
//   NOTIFY_TTS_MAXCHARS  cap on how much of a notification gets spoken (default 200)
//   NOTIFY_TTS_DEDUP_SECS  drop an identical banner seen again within this many
//                        seconds -- some banners fire more than one AX event
//                        (default 30)
//   NOTIFY_TTS_DEBUG     1 to log what it sees/skips to stderr

import ApplicationServices
import AppKit
import Foundation

let env = ProcessInfo.processInfo.environment
let HOME = FileManager.default.homeDirectoryForCurrentUser.path
let SPEAK = env["NOTIFY_TTS_SPEAK"] ?? (HOME + "/.local/bin/claude-tts-speak")
let VOICE = env["NOTIFY_TTS_VOICE"] ?? ""
let MAXCHARS = Int(env["NOTIFY_TTS_MAXCHARS"] ?? "") ?? 200
let DEDUP_SECS = Double(env["NOTIFY_TTS_DEDUP_SECS"] ?? "") ?? 30
let DEBUG = env["NOTIFY_TTS_DEBUG"] == "1"

func splitList(_ raw: String?) -> [String] {
    (raw ?? "").split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .filter { !$0.isEmpty }
}
let INCLUDE = splitList(env["NOTIFY_TTS_INCLUDE"])
let EXCLUDE = splitList(env["NOTIFY_TTS_EXCLUDE"])

func debugLog(_ msg: String) {
    guard DEBUG else { return }
    FileHandle.standardError.write(("mac-notify-watch: " + msg + "\n").data(using: .utf8)!)
}

// -- Accessibility permission -------------------------------------------

func waitForAccessibilityTrust() {
    if AXIsProcessTrusted() { return }
    let promptOnce: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: true]
    _ = AXIsProcessTrustedWithOptions(promptOnce)   // triggers the system prompt once
    FileHandle.standardError.write((
        "mac-notify-watch: waiting for Accessibility permission -- grant it in " +
        "System Settings > Privacy & Security > Accessibility for this binary, " +
        "then it picks up automatically.\n"
    ).data(using: .utf8)!)
    while !AXIsProcessTrusted() {
        Thread.sleep(forTimeInterval: 5)
    }
    debugLog("Accessibility permission granted")
}

// -- AX tree walking -------------------------------------------------------

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
          let children = value as? [AXUIElement] else { return [] }
    return children
}

func axString(_ element: AXUIElement, _ attr: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else { return nil }
    return value as? String
}

/// Depth/count-bounded so a pathological AX tree can't hang the watcher.
func collectText(_ element: AXUIElement, depth: Int, into out: inout [String]) {
    guard depth < 12, out.count < 20 else { return }
    if axString(element, kAXRoleAttribute as String) == (kAXStaticTextRole as String),
       let text = axString(element, kAXValueAttribute as String)?
           .trimmingCharacters(in: .whitespacesAndNewlines),
       !text.isEmpty {
        out.append(text)
    }
    for child in axChildren(element) {
        collectText(child, depth: depth + 1, into: &out)
    }
}

// -- speak + dedup -----------------------------------------------------------

var seen: [String: Date] = [:]
let seenLock = NSLock()

func speak(_ text: String) {
    let clipped = String(text.prefix(MAXCHARS))
    debugLog("speaking: \(clipped)")
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: SPEAK)
    // claude-tts-speak --translate is a no-op for text that's already
    // Japanese (has_cjk() short-circuits) and Japanese-ifies everything else
    // for the VOICEVOX voice -- same call either way.
    proc.arguments = ["--translate", "--text", clipped]
    if !VOICE.isEmpty {
        var childEnv = env
        childEnv["CLAUDE_TTS_VOICE"] = VOICE
        proc.environment = childEnv
    }
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
    } catch {
        debugLog("failed to launch claude-tts-speak at \(SPEAK): \(error)")
    }
}

func handleNewWindow(_ window: AXUIElement) {
    if DEBUG {
        let role = axString(window, kAXRoleAttribute as String) ?? "?"
        let subrole = axString(window, kAXSubroleAttribute as String) ?? "?"
        let desc = axString(window, kAXDescriptionAttribute as String) ?? "?"
        let identifier = axString(window, "AXIdentifier") ?? "?"
        debugLog("window created: role=\(role) subrole=\(subrole) description=\(desc) identifier=\(identifier)")
    }
    var texts: [String] = []
    collectText(window, depth: 0, into: &texts)
    guard !texts.isEmpty else { return }

    var deduped: [String] = []
    for t in texts where !deduped.contains(t) { deduped.append(t) }

    // NotificationCenter's own empty-state placeholder for the list panel --
    // not a real notification, just its "nothing here" copy leaking through
    // the same AX window-created event as everything else.
    if deduped == ["No recent notifications"] {
        debugLog("skipped (NotificationCenter empty-state placeholder)")
        return
    }

    // NotificationCenter's grouped history/list panel also fires
    // kAXWindowCreatedNotification and its AX tree is otherwise
    // indistinguishable from a single fresh banner -- but it stacks multiple
    // *different* notifications, each carrying its own relative-time marker
    // ("2m ago", "1h ago", ...), whereas one genuine banner carries at most
    // one. Seeing more than one is the cheapest reliable signal that this is
    // stale list content, not a new notification, without needing a role/
    // subrole that turned out identical (AXWindow/AXSystemDialog) either way.
    let relativeTimeMarker = try! NSRegularExpression(
        pattern: #"\b\d+\s*(s|sec|secs|m|min|mins|h|hr|hrs|d)\b\s*ago\b|[0-9]+\s*(分|時間|秒|日)前"#,
        options: .caseInsensitive)
    let timeMarkerCount = deduped.reduce(0) { count, t in
        count + relativeTimeMarker.numberOfMatches(
            in: t, range: NSRange(t.startIndex..., in: t))
    }
    if timeMarkerCount > 1 {
        debugLog("skipped (looks like the grouped notification list, "
                 + "\(timeMarkerCount) relative-time markers): "
                 + deduped.joined(separator: ": "))
        return
    }

    let sender = deduped[0].lowercased()
    if EXCLUDE.contains(where: { sender.contains($0) }) {
        debugLog("excluded (NOTIFY_TTS_EXCLUDE): \(deduped[0])")
        return
    }
    if !INCLUDE.isEmpty && !INCLUDE.contains(where: { sender.contains($0) }) {
        debugLog("skipped (not in NOTIFY_TTS_INCLUDE): \(deduped[0])")
        return
    }

    let message = deduped.joined(separator: ": ")
    let now = Date()
    seenLock.lock()
    seen = seen.filter { now.timeIntervalSince($0.value) < DEDUP_SECS }
    if seen[message] != nil {
        seenLock.unlock()
        debugLog("duplicate within \(Int(DEDUP_SECS))s, skipping: \(message)")
        return
    }
    seen[message] = now
    seenLock.unlock()

    speak(message)
}

let axObserverCallback: AXObserverCallback = { _, element, _, _ in
    handleNewWindow(element)
}

// -- attach to NotificationCenter -------------------------------------------

func notificationCenterPID() -> pid_t? {
    NSWorkspace.shared.runningApplications
        .first(where: { $0.bundleIdentifier == "com.apple.notificationcenterui" })?
        .processIdentifier
}

func attachObserver() -> AXObserver? {
    guard let pid = notificationCenterPID() else {
        debugLog("NotificationCenter process not found yet")
        return nil
    }
    var observer: AXObserver?
    guard AXObserverCreate(pid, axObserverCallback, &observer) == .success, let obs = observer else {
        debugLog("AXObserverCreate failed for pid \(pid)")
        return nil
    }
    let appElement = AXUIElementCreateApplication(pid)
    let result = AXObserverAddNotification(obs, appElement, kAXWindowCreatedNotification as CFString, nil)
    guard result == .success else {
        debugLog("AXObserverAddNotification failed (\(result.rawValue)) for pid \(pid)")
        return nil
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
    debugLog("attached to NotificationCenter pid \(pid)")
    return obs
}

waitForAccessibilityTrust()

var observer = attachObserver()
while observer == nil {
    Thread.sleep(forTimeInterval: 5)
    observer = attachObserver()
}

RunLoop.main.run()
