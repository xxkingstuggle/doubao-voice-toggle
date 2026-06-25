import Foundation
import Carbon
import ApplicationServices
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
        _ = selectSource(id: previous)
        try? fm.removeItem(at: stateFile)
        log("start failed: \(error.localizedDescription)")
        throw error
    }
}

do {
    switch CommandLine.arguments.dropFirst().first ?? "toggle" {
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
