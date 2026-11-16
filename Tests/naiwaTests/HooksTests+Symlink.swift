import Foundation
import Testing
@testable import naiwa

extension HooksTests {
    /// settings.json 是相对路径的符号链接、目标是 0600：装和撤都写到目标里，链接和权限不变，备份是目标原件的普通文件
    @Test func installAndUninstallKeepSymlink() throws {
        let original = #"{"env": {"TOKEN": "x"}}"# + "\n"
        try withSettings(nil) { link in
            let fm = FileManager.default
            let dir = link.deletingLastPathComponent().appendingPathComponent("dotfiles")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent("settings.json")
            try original.write(to: target, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "dotfiles/settings.json")

            func check() throws {
                #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == "dotfiles/settings.json")
                #expect(try fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int == 0o600)
            }

            try Hooks.install()
            try check()
            #expect(Hooks.containsOurs(try Hooks.parse(try String(contentsOf: target, encoding: .utf8))))
            let backup = target.path + ".bak-naiwa"
            #expect(try fm.attributesOfItem(atPath: backup)[.type] as? FileAttributeType == .typeRegular)
            #expect(try String(contentsOfFile: backup, encoding: .utf8) == original)

            try Hooks.uninstall()
            try check()
            #expect(!Hooks.containsOurs(try Hooks.parse(try String(contentsOf: target, encoding: .utf8))))
        }
    }
}
