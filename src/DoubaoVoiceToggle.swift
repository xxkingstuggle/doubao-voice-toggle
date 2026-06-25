import Foundation
import Carbon
import ApplicationServices
import AppKit
import Darwin

private let doubaoSourceID = "com.bytedance.inputmethod.doubaoime.pinyin"
private let fallbackSourceID = "com.apple.inputmethod.SCIM.Shuangpin"
private let rightCommandKeyCode: Int64 = 54
private let rightOptionKeyCode: Int64 = 61
private let doubaoVoiceStartDelay: useconds_t = 300_000

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
private let activeRecordSessionFile = supportDirectory.appendingPathComponent("active-record-session")
private let historyFile = FileManager.default
    .urls(for: .desktopDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("豆包语音输入记录.md")

private let recorderQuietFinishDelay: TimeInterval = 1.0
private let recorderMaxStopWait: TimeInterval = 3.0
private let recorderMaxSessionDuration: TimeInterval = 900.0

private func combinedFlags(_ values: CGEventFlags...) -> CGEventFlags {
    CGEventFlags(rawValue: values.reduce(UInt64(0)) { $0 | $1.rawValue })
}

private func log(_ message: String) {
    let formatter = ISO8601DateFormatter()
    let line = "\(formatter.string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
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

private func tapDoubaoVoiceShortcut() throws {
    guard CGPreflightPostEventAccess() else {
        throw NSError(domain: "DoubaoVoiceToggle", code: 11,
                      userInfo: [NSLocalizedDescriptionKey: "辅助功能尚未允许后台助手模拟按键"])
    }

    let commandOnly = combinedFlags(.maskCommand, deviceRightCommand)
    let commandAndOption = combinedFlags(
        .maskCommand, .maskAlternate, deviceRightCommand, deviceRightOption
    )

    try postModifier(keyCode: rightCommandKeyCode, flags: commandOnly)
    usleep(70_000)
    try postModifier(keyCode: rightOptionKeyCode, flags: commandAndOption)
    // A very short modifier tap is occasionally ignored by Doubao. Holding
    // the captured shortcut briefly matches a normal physical key press.
    usleep(250_000)
    try postModifier(keyCode: rightOptionKeyCode, flags: commandOnly)
    usleep(70_000)
    try postModifier(keyCode: rightCommandKeyCode, flags: [])
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
    guard let data = entry.data(using: .utf8) else { return }
    if !FileManager.default.fileExists(atPath: historyFile.path) {
        let header = "# 豆包语音输入记录\n"
        var firstData = Data(header.utf8)
        firstData.append(data)
        try? firstData.write(to: historyFile, options: .atomic)
        return
    }
    if let handle = try? FileHandle(forWritingTo: historyFile) {
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {}
    }
}

private func recorderUpdateLatestValue() {
    guard let target = recorderTarget else { return }
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
            log("record saved; reason=\(reason); app=\(target.appName); chars=\(text.count)")
        } else {
            log("record skipped empty; reason=\(reason)")
        }
    } else {
        log("record skipped no target; reason=\(reason)")
    }

    try? FileManager.default.removeItem(at: recordStopFile(recorderSessionID))
    try? FileManager.default.removeItem(at: activeRecordSessionFile)
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
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
        recorderUpdateLatestValue()

        if FileManager.default.fileExists(atPath: recordStopFile(sessionID).path) {
            if recorderStopRequestedAt == nil {
                recorderStopRequestedAt = Date()
                log("record stop requested; session=\(sessionID)")
            }
            let stopAt = recorderStopRequestedAt ?? Date()
            let quietEnough = Date().timeIntervalSince(recorderLastChange) >= recorderQuietFinishDelay
            let waitedEnough = Date().timeIntervalSince(stopAt) >= recorderMaxStopWait
            if quietEnough || waitedEnough {
                finishRecorder(reason: quietEnough ? "quiet-after-stop" : "max-stop-wait")
            }
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
    let sessionID = UUID().uuidString
    try? FileManager.default.removeItem(at: recordReadyFile(sessionID))
    try? FileManager.default.removeItem(at: recordStopFile(sessionID))
    try? FileManager.default.removeItem(at: recordDoneFile(sessionID))
    try? sessionID.write(to: activeRecordSessionFile, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath())
    process.arguments = ["record", sessionID]
    process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
    process.standardError = FileHandle(forWritingAtPath: "/dev/null")
    process.standardInput = FileHandle(forReadingAtPath: "/dev/null")

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

    guard let current = currentSourceID() else {
        throw NSError(domain: "DoubaoVoiceToggle", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "无法读取当前输入法"])
    }

    if isDoubaoSourceID(current) {
        let previous = restoreSourceID()
        log("stop requested; current=\(current); restore=\(previous)")
        do {
            try tapDoubaoVoiceShortcut()
            requestRecorderStop()
            guard selectSource(id: previous) else {
                throw NSError(domain: "DoubaoVoiceToggle", code: 12,
                              userInfo: [NSLocalizedDescriptionKey: "无法恢复原输入法"])
            }
            try? fm.removeItem(at: stateFile)
            log("stopped; restored=\(previous)")
            print("stopped\t\(previous)")
        } catch {
            log("stop failed: \(error.localizedDescription)")
            throw error
        }
        return
    }

    let previous = current
    try current.write(to: lastSourceFile, atomically: true, encoding: .utf8)

    try previous.write(to: stateFile, atomically: true, encoding: .utf8)
    log("start requested; current=\(current); restore=\(previous)")

    do {
        startRecorder()
        guard selectSource(id: doubaoSourceID) else {
            throw NSError(domain: "DoubaoVoiceToggle", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法切换到豆包输入法"])
        }
        usleep(doubaoVoiceStartDelay)
        log("start delay elapsed: 0.3s")
        try tapDoubaoVoiceShortcut()
        log("started; restore=\(previous)")
        print("started\t\(previous)")
    } catch {
        requestRecorderStop()
        _ = selectSource(id: previous)
        try? fm.removeItem(at: stateFile)
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
    case "reset":
        try? FileManager.default.removeItem(at: stateFile)
        print("reset")
    case "select":
        guard CommandLine.arguments.count >= 3 else { exit(64) }
        exit(selectSource(id: CommandLine.arguments[2]) ? 0 : 1)
    default:
        try toggle()
    }
} catch {
    log("error: \(error.localizedDescription)")
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
