import Foundation
import Testing
@testable import naiwa

extension HooksTests {
    /// 存在但不是 UTF-8 的 settings.json：报错，文件原样不动，也不留备份
    @Test func installRefusesNonUTF8() throws {
        try withSettings(nil) { file in
            let bytes = Data(#"{"model":"opus","env":{"N":"caf"#.utf8) + Data([0xE9]) + Data(#""}}"#.utf8)
            try bytes.write(to: file)
            #expect(throws: Hooks.Failure.self) { try Hooks.install() }
            #expect(try Data(contentsOf: file) == bytes)
            #expect(!FileManager.default.fileExists(atPath: file.path + ".bak-naiwa"))
        }
    }

    /// 文件不存在时照常从空对象开始装
    @Test func installCreatesMissingFile() throws {
        try withSettings(nil) { file in
            try Hooks.install()
            let parsed = try Hooks.parse(try String(contentsOf: file, encoding: .utf8))
            #expect(Hooks.containsOurs(parsed))
            #expect(!FileManager.default.fileExists(atPath: file.path + ".bak-naiwa"))
        }
    }

    /// 装、撤、再装：备份一直是第一次装之前的原件
    @Test func installKeepsFirstBackup() throws {
        let original = #"{"model": "opus", "permissions": {"allow": ["Bash"]}}"# + "\n"
        try withSettings(original) { file in
            try Hooks.install()
            try Hooks.uninstall()
            try Hooks.install()
            let backup = try String(contentsOfFile: file.path + ".bak-naiwa", encoding: .utf8)
            #expect(backup == original)
        }
    }
}
