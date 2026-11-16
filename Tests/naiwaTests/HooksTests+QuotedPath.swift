import Foundation
import Testing
@testable import naiwa

/// naiwa 装在带空格、带 ' 的目录里
extension HooksTests {
    static let oddDirs = ["My Apps", "Oliver's Apps"]

    @Test(arguments: oddDirs) func installReinstallUninstallWithOddPath(_ binDir: String) throws {
        let original = #"{"model": "opus"}"# + "\n"
        try withSettings(original, binDir: binDir) { file in
            try Hooks.install()
            let installed = try String(contentsOf: file, encoding: .utf8)
            #expect(isStrictJSON(installed))
            #expect(Hooks.containsOurs(try Hooks.parse(installed)))

            try Hooks.install()
            #expect(try String(contentsOf: file, encoding: .utf8) == installed)

            try Hooks.uninstall()
            let removed = try String(contentsOf: file, encoding: .utf8)
            #expect(isStrictJSON(removed))
            #expect(!Hooks.containsOurs(try Hooks.parse(removed)))
        }
    }

    @Test(arguments: oddDirs) func installedCommandRunsUnderSh(_ binDir: String) throws {
        try withSettings(nil, binDir: binDir) { file in
            // 换成一个把自己收到的 argv 逐行打出来的假 naiwa
            let naiwa = file.deletingLastPathComponent().appendingPathComponent(binDir).appendingPathComponent("naiwa")
            try "#!/bin/sh\nprintf '%s\\n' \"$0\" \"$@\"\n".write(to: naiwa, atomically: true, encoding: .utf8)
            #expect(Hooks.binary == naiwa.path)

            try Hooks.install()
            let hooks = try Hooks.parse(String(contentsOf: file, encoding: .utf8))["hooks"] as? [String: Any]
            let group = (hooks?["Stop"] as? [[String: Any]])?.first
            let command = try #require((group?["hooks"] as? [[String: Any]])?.first?["command"] as? String)

            let sh = Process()
            sh.executableURL = URL(fileURLWithPath: "/bin/sh")
            sh.arguments = ["-c", command]
            let out = Pipe()
            sh.standardOutput = out
            try sh.run()
            sh.waitUntilExit()
            let argv = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(sh.terminationStatus == 0)
            #expect(argv == "\(naiwa.path)\nhook\n")
        }
    }

    /// Codex 的 notify 要原样路径，按 JSON/TOML 字符串转义
    @Test(arguments: oddDirs + [#"Say "Hi" \ Apps"#]) func codexNotifyKeepsRawPath(_ binDir: String) throws {
        try withSettings(nil, binDir: binDir) { file in
            let path = file.deletingLastPathComponent().appendingPathComponent(binDir).appendingPathComponent("naiwa").path
            let parsed = try JSONSerialization.jsonObject(with: Data("[\(Hooks.quoted(Hooks.binary)), \"glance\"]".utf8)) as? [String]
            #expect(parsed == [path, "glance"])
        }
    }
}
