import Foundation
import Testing
@testable import naiwa

/// Hooks 读写的 settings.json 由环境变量 NAIWA_CLAUDE_SETTINGS 指定，这组测试要一个一个跑
@Suite(.serialized) struct HooksTests {
    /// 在临时目录里放一份 settings.json（nil 就不放），把 NAIWA_CLAUDE_SETTINGS 指过去，
    /// 再在 `binDir` 下放一个假的 naiwa 并让 PATH 只有它，然后跑 body
    func withSettings(_ text: String?, binDir: String = "bin", _ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("naiwa-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        if let text { try text.write(to: file, atomically: true, encoding: .utf8) }
        let bin = dir.appendingPathComponent(binDir)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let naiwa = bin.appendingPathComponent("naiwa")
        try "#!/bin/sh\n".write(to: naiwa, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: naiwa.path)
        let path = ProcessInfo.processInfo.environment["PATH"]
        setenv("NAIWA_CLAUDE_SETTINGS", file.path, 1)
        setenv("PATH", bin.path, 1)
        defer {
            unsetenv("NAIWA_CLAUDE_SETTINGS")
            if let path { setenv("PATH", path, 1) } else { unsetenv("PATH") }
        }
        try body(file)
    }

    /// 严格的 JSON 校验：JSONSerialization 会放过多余的逗号，这里另外查一遍
    func isStrictJSON(_ text: String) -> Bool {
        guard (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil else { return false }
        var inString = false, escaped = false, lastSignificant: Character = " "
        for c in text {
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            if c == "\"" { inString = true; lastSignificant = c; continue }
            if c.isWhitespace { continue }
            if (c == "]" || c == "}") && lastSignificant == "," { return false }
            lastSignificant = c
        }
        return true
    }
}
