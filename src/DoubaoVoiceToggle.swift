import Foundation
import Carbon
import ApplicationServices
import AppKit
import Darwin

private let doubaoSourceID = "com.bytedance.inputmethod.doubaoime.pinyin"
private let fallbackSourceID = "com.apple.inputmethod.SCIM.Shuangpin"
private let rightCommandKeyCode: Int64 = 54
private let rightOptionKeyCode: Int64 = 61
private let doubaoVoiceStartDelay: TimeInterval = 0.3
private let doubaoInputSourceReadyTimeout: TimeInterval = 1.0
private let doubaoVoicePanelCheckTimeout: TimeInterval = 0.5
private let doubaoVoicePanelRetryDelay: TimeInterval = 0.1
private let doubaoVoiceShortcutMaxAttempts = 5
private let doubaoVoiceStartShortcutHold: useconds_t = 450_000
private let doubaoVoiceStopShortcutHold: useconds_t = 250_000

// Device-specific flag bits are required because Doubao distinguishes the
// left and right modifier keys when matching its voice shortcut.
private let deviceRightCommand = CGEventFlags(rawValue: 0x00000010)
private let deviceRightOption = CGEventFlags(rawValue: 0x00000040)

private let supportDirectory: URL = {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DoubaoVoiceToggle", isDirectory: true)
}()

private let stateFile = supportDirectory.appendingPathComponent("previous-input-source")
private let lastSourceFile = supportDirectory.appendingPathComponent("last-non-doubao-input-source")
private let logFile = supportDirectory.appendingPathComponent("doubao-voice-toggle.log")
private let maxLogFileBytes: UInt64 = 512 * 1024
private let activeRecordSessionFile = supportDirectory.appendingPathComponent("active-record-session")
private let mediaRestoreFile = supportDirectory.appendingPathComponent("media-restore-after-stop")
private let cancelStartFile = supportDirectory.appendingPathComponent("cancel-start")
private let historyFile = FileManager.default
    .urls(for: .desktopDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("豆包语音输入记录.md")

private let recorderPollInterval: TimeInterval = 0.15
private let recorderQuietFinishDelay: TimeInterval = 0.7
private let recorderNoChangeStopWait: TimeInterval = 2.5
private let recorderMaxStopWait: TimeInterval = 4.0
private let recorderSupersededGraceWait: TimeInterval = 0.4
private let recorderMaxSessionDuration: TimeInterval = 900.0
private let previousRecorderSettleWait: TimeInterval = 1.0
private let historyTitle = "# 豆包语音输入记录"
private let mediaWasPlayingMarker = "system-now-playing-was-playing"
private let mediaRemoteFrameworkPath = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
private let mediaRemotePlaybackRateKey = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
private let mediaRemotePlayCommand: Int32 = 0
private let mediaRemotePauseCommand: Int32 = 1

private func mediaRemotePlaybackProbeScript(command: Int32? = nil) -> String {
    let commandExpression = command.map { "Int32(\($0))" } ?? "nil"
    return """
import Foundation
import Dispatch
import Darwin

typealias GetInfo = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
typealias SendCommand = @convention(c) (Int32, CFDictionary?) -> DarwinBoolean

guard let handle = dlopen("\(mediaRemoteFrameworkPath)", RTLD_LAZY),
      let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else {
    print("unknown")
    exit(0)
}

let getInfo = unsafeBitCast(symbol, to: GetInfo.self)
let commandToSend: Int32? = \(commandExpression)
if let commandToSend, let sendSymbol = dlsym(handle, "MRMediaRemoteSendCommand") {
    let send = unsafeBitCast(sendSymbol, to: SendCommand.self)
    _ = send(commandToSend, nil)
    usleep(120_000)
}

let semaphore = DispatchSemaphore(value: 0)
var output = "unknown"

getInfo(DispatchQueue.global(qos: .userInitiated)) { info in
    if let info {
        let dictionary = info as NSDictionary
        let value = dictionary.object(forKey: "\(mediaRemotePlaybackRateKey)")
        if let number = value as? NSNumber {
            output = String(number.doubleValue)
        } else if let double = value as? Double {
            output = String(double)
        } else if let int = value as? Int {
            output = String(Double(int))
        } else if let float = value as? Float {
            output = String(Double(float))
        }
    }
    semaphore.signal()
}

if semaphore.wait(timeout: .now() + 2) == .success {
    print(output)
} else {
    print("unknown")
}
"""
}

private func combinedFlags(_ values: CGEventFlags...) -> CGEventFlags {
    CGEventFlags(rawValue: values.reduce(UInt64(0)) { $0 | $1.rawValue })
}

private func rotateLogIfNeeded() {
    guard
        let attributes = try? FileManager.default.attributesOfItem(atPath: logFile.path),
        let size = attributes[.size] as? NSNumber,
        size.uint64Value > maxLogFileBytes
    else {
        return
    }
    try? FileManager.default.removeItem(at: logFile)
}

private func log(_ message: String) {
    let formatter = ISO8601DateFormatter()
    let line = "\(formatter.string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    rotateLogIfNeeded()
    if !FileManager.default.fileExists(atPath: logFile.path) {
        try? data.write(to: logFile, options: .atomic)
        return
    }
    if let handle = try? FileHandle(forWritingTo: logFile) {
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {}
    }
}

private func readTrimmed(_ file: URL) -> String? {
    try? String(contentsOf: file, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func recordReadyFile(_ sessionID: String) -> URL {
    supportDirectory.appendingPathComponent("record-\(sessionID).ready")
}

private func recordStopFile(_ sessionID: String) -> URL {
    supportDirectory.appendingPathComponent("record-\(sessionID).stop")
}

private func recordDoneFile(_ sessionID: String) -> URL {
    supportDirectory.appendingPathComponent("record-\(sessionID).done")
}

private func withFileLock(_ name: String, _ body: () throws -> Void) throws {
    try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    let lockFile = supportDirectory.appendingPathComponent(name)
    let fd = open(lockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard fd >= 0 else {
        try body()
        return
    }
    defer {
        flock(fd, LOCK_UN)
        close(fd)
    }
    flock(fd, LOCK_EX)
    try body()
}

private func withToggleLock(_ body: () throws -> Void) throws {
    try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    let lockFile = supportDirectory.appendingPathComponent("toggle.lock")
    let fd = open(lockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard fd >= 0 else {
        log("toggle lock open failed; running without lock; errno=\(errno)")
        try body()
        return
    }

    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        close(fd)
        try? "cancel".write(to: cancelStartFile, atomically: true, encoding: .utf8)
        log("toggle lock busy; cancel requested instead of waiting; cancelFile=\(cancelStartFile.path); errno=\(errno)")
        print("busy-cancel-requested")
        return
    }

    defer {
        flock(fd, LOCK_UN)
        close(fd)
    }
    try body()
}

private func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

private func currentSourceID() -> String? {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
    return stringProperty(source, kTISPropertyInputSourceID)
}

private func isDoubaoSourceID(_ sourceID: String) -> Bool {
    sourceID.hasPrefix("com.bytedance.inputmethod.doubaoime")
}

private func restoreSourceID() -> String {
    let candidates = [readTrimmed(stateFile), readTrimmed(lastSourceFile), fallbackSourceID]
    for candidate in candidates {
        guard let sourceID = candidate, !sourceID.isEmpty, !isDoubaoSourceID(sourceID) else {
            continue
        }
        return sourceID
    }
    return fallbackSourceID
}

private func selectSource(id: String) -> Bool {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    guard let unmanaged = TISCreateInputSourceList(filter, true) else { return false }
    let sources = unmanaged.takeRetainedValue() as NSArray
    for case let source as TISInputSource in sources {
        if TISSelectInputSource(source) == noErr { return true }
    }
    return false
}

@discardableResult
private func waitForInputSource(
    matching predicate: (String) -> Bool,
    timeout: TimeInterval,
    pollInterval: useconds_t = 20_000
) -> String? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let sourceID = currentSourceID(), predicate(sourceID) {
            return sourceID
        }
        usleep(pollInterval)
    }

    if let sourceID = currentSourceID(), predicate(sourceID) {
        return sourceID
    }
    return nil
}

private func commandOutput(_ executable: String, _ arguments: [String]) -> String? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    if let nullOutput = FileHandle(forWritingAtPath: "/dev/null") {
        process.standardError = nullOutput
    }

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }

    guard process.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func systemNowPlayingPlaybackRate(after command: Int32? = nil) -> Double? {
    let script = mediaRemotePlaybackProbeScript(command: command)
    let candidates = [
        ("/usr/bin/swift", ["-e", script]),
        ("/usr/bin/xcrun", ["swift", "-e", script])
    ]

    for candidate in candidates {
        guard let output = commandOutput(candidate.0, candidate.1), !output.isEmpty else {
            continue
        }
        if output == "unknown" {
            continue
        }
        if let rate = Double(output) {
            return rate
        }
        log("media playback rate probe unreadable; output=\(output)")
    }

    return nil
}

private func systemNowPlayingIsPlaying() -> Bool? {
    if let playbackRate = systemNowPlayingPlaybackRate() {
        return playbackRate > 0
    }

    return nil
}

private func sendSystemMediaCommand(_ command: Int32) -> Bool {
    let rate = systemNowPlayingPlaybackRate(after: command)
    return rate != nil
}

@discardableResult
private func pauseMediaIfPlayingForVoiceSession() -> Bool {
    try? FileManager.default.removeItem(at: mediaRestoreFile)

    guard let wasPlaying = systemNowPlayingIsPlaying() else {
        log("media pause skipped; system now playing state unavailable")
        return false
    }
    guard wasPlaying else {
        log("media pause skipped; system now playing was idle")
        return false
    }
    guard sendSystemMediaCommand(mediaRemotePauseCommand) else {
        return false
    }
    usleep(120_000)

    do {
        try mediaWasPlayingMarker.write(to: mediaRestoreFile, atomically: true, encoding: .utf8)
        return true
    } catch {
        log("media marker write failed: \(error.localizedDescription)")
        _ = sendSystemMediaCommand(mediaRemotePlayCommand)
        return false
    }
}

private func resumeMediaIfPausedForVoiceSession() {
    guard let markerText = readTrimmed(mediaRestoreFile), !markerText.isEmpty else {
        return
    }

    defer {
        try? FileManager.default.removeItem(at: mediaRestoreFile)
    }

    guard markerText == mediaWasPlayingMarker else {
        return
    }

    _ = sendSystemMediaCommand(mediaRemotePlayCommand)
}

private func postModifier(keyCode: Int64, flags: CGEventFlags) throws {
    guard let event = CGEvent(source: CGEventSource(stateID: .hidSystemState)) else {
        throw NSError(domain: "DoubaoVoiceToggle", code: 10,
                      userInfo: [NSLocalizedDescriptionKey: "无法创建键盘事件"])
    }
    event.type = .flagsChanged
    event.setIntegerValueField(.keyboardEventKeycode, value: keyCode)
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

private func tapDoubaoVoiceShortcut(holdDuration: useconds_t) throws {
    guard CGPreflightPostEventAccess() else {
        throw NSError(domain: "DoubaoVoiceToggle", code: 11,
                      userInfo: [NSLocalizedDescriptionKey: "辅助功能尚未允许后台助手模拟按键"])
    }

    let commandOnly = combinedFlags(.maskCommand, deviceRightCommand)
    let commandAndOption = combinedFlags(
        .maskCommand, .maskAlternate, deviceRightCommand, deviceRightOption
    )

    try postModifier(keyCode: rightCommandKeyCode, flags: commandOnly)
    try postModifier(keyCode: rightOptionKeyCode, flags: commandAndOption)
    // A very short modifier tap is occasionally ignored by Doubao. Holding
    // the captured shortcut briefly matches a normal physical key press.
    usleep(holdDuration)
    try postModifier(keyCode: rightOptionKeyCode, flags: commandOnly)
    try postModifier(keyCode: rightCommandKeyCode, flags: [])
}

private struct WindowInfo {
    let ownerName: String
    let windowName: String
    let layer: Int
    let alpha: Double
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    var isVisibleCandidate: Bool {
        alpha > 0.05 && width >= 80 && height >= 20
    }

    var isVoicePanelCandidate: Bool {
        layer == 3 && alpha > 0.05 && width >= 90 && width <= 180 && height >= 24 && height <= 48
    }

    var summary: String {
        let namePart = windowName.isEmpty ? "" : " name=\(windowName)"
        return "\(ownerName)\(namePart) layer=\(layer) alpha=\(String(format: "%.2f", alpha)) frame=\(x),\(y),\(width),\(height)"
    }
}

private func doubaoInputMethodWindows() -> [WindowInfo] {
    guard let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
        return []
    }

    return windows.compactMap { window -> WindowInfo? in
        let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
        let lowerOwner = ownerName.lowercased()
        guard ownerName.contains("豆包输入法") || lowerOwner.contains("doubaoime") else {
            return nil
        }

        let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
        return WindowInfo(
            ownerName: ownerName,
            windowName: window[kCGWindowName as String] as? String ?? "",
            layer: window[kCGWindowLayer as String] as? Int ?? 0,
            alpha: window[kCGWindowAlpha as String] as? Double ?? 0,
            x: bounds["X"] as? Int ?? 0,
            y: bounds["Y"] as? Int ?? 0,
            width: bounds["Width"] as? Int ?? 0,
            height: bounds["Height"] as? Int ?? 0
        )
    }
}

private func doubaoVoicePanelVisible() -> Bool {
    doubaoInputMethodWindows().contains { $0.isVoicePanelCandidate }
}

@discardableResult
private func waitForDoubaoVoicePanel(timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if doubaoVoicePanelVisible() {
            return true
        }
        usleep(80_000)
    }
    return doubaoVoicePanelVisible()
}

@discardableResult
private func waitBeforeNextDoubaoVoiceRetry(timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: cancelStartFile.path) {
            return false
        }
        if doubaoVoicePanelVisible() {
            return true
        }
        if let sourceID = currentSourceID(), !isDoubaoSourceID(sourceID) {
            return false
        }
        usleep(100_000)
    }
    return doubaoVoicePanelVisible()
}

private func startDoubaoVoiceWithVerification() throws -> Bool {
    for attempt in 1...doubaoVoiceShortcutMaxAttempts {
        if FileManager.default.fileExists(atPath: cancelStartFile.path) {
            return false
        }
        if attempt > 1, doubaoVoicePanelVisible() {
            return true
        }
        if let sourceID = currentSourceID(), !isDoubaoSourceID(sourceID) {
            return false
        }

        if attempt > 1 {
            log("voice panel missing; retrying internal shortcut; attempt=\(attempt)")
        }

        try tapDoubaoVoiceShortcut(holdDuration: doubaoVoiceStartShortcutHold)
        let visible = waitForDoubaoVoicePanel(timeout: doubaoVoicePanelCheckTimeout)

        if visible {
            return true
        }

        if attempt < doubaoVoiceShortcutMaxAttempts {
            if waitBeforeNextDoubaoVoiceRetry(timeout: doubaoVoicePanelRetryDelay) {
                return true
            }
        }
    }

    log("voice start verification failed after all attempts")
    return false
}

private struct FocusedTextTarget {
    let pid: pid_t
    let appName: String
    let bundleIdentifier: String
    let element: AXUIElement
}

private var recorderSessionID = ""
private var recorderTarget: FocusedTextTarget?
private var recorderObserver: AXObserver?
private var recorderInitialValue = ""
private var recorderLatestValue = ""
private var recorderLastChange = Date()
private var recorderStopRequestedAt: Date?

private func axStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
        return nil
    }
    return value as? String
}

private func focusedTextTarget() -> FocusedTextTarget? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success else {
        return nil
    }
    guard CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
    let element = focused as! AXUIElement
    guard isEditableTextElement(element) else { return nil }
    return FocusedTextTarget(
        pid: app.processIdentifier,
        appName: app.localizedName ?? "unknown-app",
        bundleIdentifier: app.bundleIdentifier ?? "",
        element: element
    )
}

private func isEditableTextElement(_ element: AXUIElement) -> Bool {
    let role = axStringAttribute(element, kAXRoleAttribute as CFString) ?? ""
    let subrole = axStringAttribute(element, kAXSubroleAttribute as CFString) ?? ""
    if role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String) {
        return true
    }
    if subrole == (kAXSearchFieldSubrole as String) {
        return true
    }
    var settable = DarwinBoolean(false)
    let status = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
    return status == .success && settable.boolValue
}

private func axValue(_ element: AXUIElement) -> String {
    axStringAttribute(element, kAXValueAttribute as CFString) ?? ""
}

private func commonPrefixLength(_ a: String, _ b: String) -> Int {
    var count = 0
    var i = a.startIndex
    var j = b.startIndex
    while i < a.endIndex, j < b.endIndex, a[i] == b[j] {
        count += 1
        i = a.index(after: i)
        j = b.index(after: j)
    }
    return count
}

private func commonSuffixLength(_ a: String, _ b: String, excludingPrefix prefix: Int) -> Int {
    let aChars = Array(a)
    let bChars = Array(b)
    var count = 0
    while count + prefix < aChars.count,
          count + prefix < bChars.count,
          aChars[aChars.count - 1 - count] == bChars[bChars.count - 1 - count] {
        count += 1
    }
    return count
}

private func insertedText(from old: String, to new: String) -> String {
    guard old != new else { return "" }
    let prefix = commonPrefixLength(old, new)
    let suffix = commonSuffixLength(old, new, excludingPrefix: prefix)
    let chars = Array(new)
    let start = prefix
    let end = max(start, chars.count - suffix)
    guard start < end else { return "" }
    return String(chars[start..<end])
}

private func withoutLeadingNewlines(_ value: String) -> String {
    var result = value
    while result.hasPrefix("\n") || result.hasPrefix("\r") {
        result.removeFirst()
    }
    return result
}

private func historyContentByPrepending(entry: String, existing: String) -> String {
    let header = "\(historyTitle)\n\n"
    guard !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return header + entry
    }

    if existing.hasPrefix(historyTitle) {
        let remainderStart = existing.index(existing.startIndex, offsetBy: historyTitle.count)
        let remainder = withoutLeadingNewlines(String(existing[remainderStart...]))
        return header + entry + remainder
    }

    return header + entry + existing
}

private func appendHistory(text: String, target: FocusedTextTarget, finalValue: String) {
    let timestampFormatter = DateFormatter()
    timestampFormatter.locale = Locale(identifier: "zh_CN")
    timestampFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let timestamp = timestampFormatter.string(from: Date())
    let bundle = target.bundleIdentifier.isEmpty ? "" : "（\(target.bundleIdentifier)）"
    let entry = """
## \(timestamp)

App：\(target.appName)\(bundle)

\(text.trimmingCharacters(in: .whitespacesAndNewlines))

---

"""

    do {
        try withFileLock("history.lock") {
            let existing = (try? String(contentsOf: historyFile, encoding: .utf8)) ?? ""
            let content = historyContentByPrepending(entry: entry, existing: existing)
            try content.write(to: historyFile, atomically: true, encoding: .utf8)
        }
    } catch {
        log("history write failed: \(error.localizedDescription)")
    }
}

private func recorderWasSuperseded() -> Bool {
    guard recorderStopRequestedAt != nil else { return false }
    guard let activeSessionID = readTrimmed(activeRecordSessionFile), !activeSessionID.isEmpty else {
        return false
    }
    return activeSessionID != recorderSessionID
}

private func recorderUpdateLatestValue() {
    guard let target = recorderTarget else { return }
    guard !recorderWasSuperseded() else { return }
    let current = axValue(target.element)
    guard current != recorderLatestValue else { return }
    recorderLatestValue = current
    recorderLastChange = Date()
}

private let recorderCallback: AXObserverCallback = { _, element, notification, _ in
    guard notification as String == kAXValueChangedNotification else { return }
    guard let target = recorderTarget, CFEqual(element, target.element) else { return }
    recorderUpdateLatestValue()
}

private func finishRecorder(reason: String) -> Never {
    if let target = recorderTarget {
        recorderUpdateLatestValue()
        let text = insertedText(from: recorderInitialValue, to: recorderLatestValue)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendHistory(text: text, target: target, finalValue: recorderLatestValue)
            log("record saved; reason=\(reason); app=\(target.appName); initialLen=\(recorderInitialValue.count); finalLen=\(recorderLatestValue.count); chars=\(text.count)")
        } else {
            log("record skipped empty; reason=\(reason); initialLen=\(recorderInitialValue.count); finalLen=\(recorderLatestValue.count)")
        }
    } else {
        log("record skipped no target; reason=\(reason)")
    }

    try? FileManager.default.removeItem(at: recordStopFile(recorderSessionID))
    if readTrimmed(activeRecordSessionFile) == recorderSessionID {
        try? FileManager.default.removeItem(at: activeRecordSessionFile)
    } else {
        log("record active session retained; finished=\(recorderSessionID); active=\(readTrimmed(activeRecordSessionFile) ?? "none")")
    }
    try? "done".write(to: recordDoneFile(recorderSessionID), atomically: true, encoding: .utf8)
    exit(0)
}

private func runRecorder(sessionID: String) -> Never {
    recorderSessionID = sessionID
    let fm = FileManager.default
    try? fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    try? fm.removeItem(at: recordReadyFile(sessionID))
    try? fm.removeItem(at: recordStopFile(sessionID))
    try? fm.removeItem(at: recordDoneFile(sessionID))

    guard AXIsProcessTrusted() else {
        log("record unavailable; accessibility denied")
        try? "error accessibility denied".write(to: recordReadyFile(sessionID), atomically: true, encoding: .utf8)
        exit(1)
    }
    guard let target = focusedTextTarget() else {
        log("record unavailable; no editable focused text element")
        try? "error no editable text element".write(to: recordReadyFile(sessionID), atomically: true, encoding: .utf8)
        exit(1)
    }

    recorderTarget = target
    recorderInitialValue = axValue(target.element)
    recorderLatestValue = recorderInitialValue
    recorderLastChange = Date()

    var observer: AXObserver?
    if AXObserverCreate(target.pid, recorderCallback, &observer) == .success, let createdObserver = observer {
        recorderObserver = createdObserver
        let status = AXObserverAddNotification(
            createdObserver,
            target.element,
            kAXValueChangedNotification as CFString,
            nil
        )
        if status == .success {
            CFRunLoopAddSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(createdObserver),
                .defaultMode
            )
        } else {
            log("record observer notification failed; status=\(status.rawValue); polling fallback active")
        }
    } else {
        log("record observer create failed; polling fallback active")
    }

    try? "ready app=\(target.appName) initialLen=\(recorderInitialValue.count)"
        .write(to: recordReadyFile(sessionID), atomically: true, encoding: .utf8)
    log("record started; session=\(sessionID); app=\(target.appName); initialLen=\(recorderInitialValue.count)")

    let startTime = Date()
    Timer.scheduledTimer(withTimeInterval: recorderPollInterval, repeats: true) { _ in
        if FileManager.default.fileExists(atPath: recordStopFile(sessionID).path) {
            if recorderStopRequestedAt == nil {
                recorderStopRequestedAt = Date()
                log("record stop requested; session=\(sessionID)")
            }
            let stopAt = recorderStopRequestedAt ?? Date()
            let stopElapsed = Date().timeIntervalSince(stopAt)
            let superseded = recorderWasSuperseded()

            if !superseded {
                recorderUpdateLatestValue()
            }

            let text = insertedText(from: recorderInitialValue, to: recorderLatestValue)
            let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let quietEnough = Date().timeIntervalSince(recorderLastChange) >= recorderQuietFinishDelay

            if hasText, quietEnough {
                finishRecorder(reason: "quiet-after-change")
            }
            if stopElapsed >= recorderMaxStopWait {
                finishRecorder(reason: "max-stop-wait")
            }
            if !hasText, superseded, stopElapsed >= recorderSupersededGraceWait {
                finishRecorder(reason: "superseded-before-change")
            }
            if !hasText, stopElapsed >= recorderNoChangeStopWait {
                finishRecorder(reason: "no-change-stop-wait")
            }
        } else {
            recorderUpdateLatestValue()
        }

        if Date().timeIntervalSince(startTime) >= recorderMaxSessionDuration {
            finishRecorder(reason: "timeout")
        }
    }

    RunLoop.current.run()
    exit(0)
}

private func executablePath() -> String {
    if CommandLine.arguments[0].hasPrefix("/") {
        return CommandLine.arguments[0]
    }
    return Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
}

private func startRecorder() {
    settlePreviousRecorderBeforeStart()

    let sessionID = UUID().uuidString
    try? FileManager.default.removeItem(at: recordReadyFile(sessionID))
    try? FileManager.default.removeItem(at: recordStopFile(sessionID))
    try? FileManager.default.removeItem(at: recordDoneFile(sessionID))
    try? sessionID.write(to: activeRecordSessionFile, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath())
    process.arguments = ["record", sessionID]
    if let nullOutput = FileHandle(forWritingAtPath: "/dev/null") {
        process.standardOutput = nullOutput
        process.standardError = nullOutput
    }
    if let nullInput = FileHandle(forReadingAtPath: "/dev/null") {
        process.standardInput = nullInput
    }

    do {
        try process.run()
    } catch {
        log("record launch failed: \(error.localizedDescription)")
        try? FileManager.default.removeItem(at: activeRecordSessionFile)
        return
    }

    for _ in 0..<10 {
        if let ready = readTrimmed(recordReadyFile(sessionID)) {
            log("record launch \(ready)")
            return
        }
        usleep(50_000)
    }
    log("record launch pending; session=\(sessionID)")
}

private func settlePreviousRecorderBeforeStart() {
    guard let sessionID = readTrimmed(activeRecordSessionFile), !sessionID.isEmpty else {
        return
    }

    if FileManager.default.fileExists(atPath: recordDoneFile(sessionID).path) {
        if readTrimmed(activeRecordSessionFile) == sessionID {
            try? FileManager.default.removeItem(at: activeRecordSessionFile)
        }
        return
    }

    log("record previous active before start; waiting; session=\(sessionID)")
    try? "stop".write(to: recordStopFile(sessionID), atomically: true, encoding: .utf8)

    let deadline = Date().addingTimeInterval(previousRecorderSettleWait)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: recordDoneFile(sessionID).path) {
            if readTrimmed(activeRecordSessionFile) == sessionID {
                try? FileManager.default.removeItem(at: activeRecordSessionFile)
            }
            log("record previous settled before start; session=\(sessionID)")
            return
        }
        usleep(50_000)
    }

    log("record previous still finalizing; session=\(sessionID)")
}

private func requestRecorderStop() {
    guard let sessionID = readTrimmed(activeRecordSessionFile), !sessionID.isEmpty else {
        log("record stop skipped; no active session")
        return
    }
    do {
        try "stop".write(to: recordStopFile(sessionID), atomically: true, encoding: .utf8)
        log("record stop signal written; session=\(sessionID)")
    } catch {
        log("record stop signal failed: \(error.localizedDescription)")
    }
}

private func listSources() {
    guard let unmanaged = TISCreateInputSourceList(nil, true) else { return }
    let sources = unmanaged.takeRetainedValue() as NSArray
    for case let source as TISInputSource in sources {
        guard let id = stringProperty(source, kTISPropertyInputSourceID) else { continue }
        let name = stringProperty(source, kTISPropertyLocalizedName) ?? ""
        print("\(id)\t\(name)")
    }
}

private func toggle() throws {
    let fm = FileManager.default
    try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    try? fm.removeItem(at: cancelStartFile)

    guard let current = currentSourceID() else {
        throw NSError(domain: "DoubaoVoiceToggle", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "无法读取当前输入法"])
    }

    if isDoubaoSourceID(current) {
        let previous = restoreSourceID()
        log("stop requested; current=\(current); restore=\(previous)")
        var voiceStopSent = false
        do {
            try tapDoubaoVoiceShortcut(holdDuration: doubaoVoiceStopShortcutHold)
            voiceStopSent = true
            requestRecorderStop()
            let restored = selectSource(id: previous)
            guard restored else {
                throw NSError(domain: "DoubaoVoiceToggle", code: 12,
                              userInfo: [NSLocalizedDescriptionKey: "无法恢复原输入法"])
            }
            resumeMediaIfPausedForVoiceSession()
            try? fm.removeItem(at: stateFile)
            log("stopped; restored=\(previous)")
            print("stopped\t\(previous)")
        } catch {
            if voiceStopSent {
                resumeMediaIfPausedForVoiceSession()
            }
            log("stop failed: \(error.localizedDescription); current=\(currentSourceID() ?? "unknown")")
            throw error
        }
        return
    }

    let previous = current
    try current.write(to: lastSourceFile, atomically: true, encoding: .utf8)

    try previous.write(to: stateFile, atomically: true, encoding: .utf8)
    log("start requested; current=\(current); restore=\(previous)")

    do {
        pauseMediaIfPlayingForVoiceSession()
        startRecorder()
        let selectedDoubao = selectSource(id: doubaoSourceID)
        guard selectedDoubao else {
            throw NSError(domain: "DoubaoVoiceToggle", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法切换到豆包输入法"])
        }

        let switchStart = Date()
        _ = waitForInputSource(
            matching: isDoubaoSourceID,
            timeout: doubaoInputSourceReadyTimeout
        )
        let elapsed = Date().timeIntervalSince(switchStart)

        if elapsed < doubaoVoiceStartDelay {
            usleep(useconds_t((doubaoVoiceStartDelay - elapsed) * 1_000_000))
        }
        let panelVisible = try startDoubaoVoiceWithVerification()
        if !panelVisible {
            log("voice panel still missing after retries; input source remains \(currentSourceID() ?? "unknown")")
            throw NSError(domain: "DoubaoVoiceToggle", code: 15,
                          userInfo: [NSLocalizedDescriptionKey: "豆包语音输入框未出现"])
        }
        log("started; restore=\(previous)")
        print("started\t\(previous)")
    } catch {
        requestRecorderStop()
        resumeMediaIfPausedForVoiceSession()
        _ = selectSource(id: previous)
        try? fm.removeItem(at: stateFile)
        try? fm.removeItem(at: cancelStartFile)
        log("start failed: \(error.localizedDescription)")
        throw error
    }
}

do {
    switch CommandLine.arguments.dropFirst().first ?? "toggle" {
    case "record":
        guard CommandLine.arguments.count >= 3 else { exit(64) }
        runRecorder(sessionID: CommandLine.arguments[2])
    case "list":
        listSources()
    case "current":
        print(currentSourceID() ?? "")
    case "access":
        print(CGPreflightPostEventAccess() ? "granted" : "denied")
    case "media-status":
        if let isPlaying = systemNowPlayingIsPlaying() {
            print(isPlaying ? "playing" : "idle")
        } else {
            print("unknown")
        }
    case "media-pause":
        print(pauseMediaIfPlayingForVoiceSession() ? "paused" : "idle")
    case "media-resume":
        resumeMediaIfPausedForVoiceSession()
        print("resume-requested")
    case "voice-windows":
        let windows = doubaoInputMethodWindows()
        print("voicePanelCandidates=\(windows.filter { $0.isVoicePanelCandidate }.count)")
        print("visibleCandidates=\(windows.filter { $0.isVisibleCandidate }.count)")
        for window in windows {
            print(window.summary)
        }
    case "reset":
        try? FileManager.default.removeItem(at: stateFile)
        try? FileManager.default.removeItem(at: mediaRestoreFile)
        try? FileManager.default.removeItem(at: cancelStartFile)
        print("reset")
    case "select":
        guard CommandLine.arguments.count >= 3 else { exit(64) }
        exit(selectSource(id: CommandLine.arguments[2]) ? 0 : 1)
    default:
        try withToggleLock {
            try toggle()
        }
    }
} catch {
    log("error: \(error.localizedDescription)")
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
