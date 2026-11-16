import Foundation
import Testing
@testable import naiwa

/// 我们的条目在数组最后、撤空的事件键在 hooks 最后时，删掉后不能留下多余的逗号
extension HooksTests {
    static let other = #"{"hooks": [{"type": "command", "command": "other"}]}"#

    func parsed(_ file: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    }

    @Test func uninstallOursLastInArray() throws {
        try withSettings(nil) { file in
            try #"{"hooks": {"Stop": [\#(Self.other), \#(Hooks.entry(matcher: false))]}}"#
                .write(to: file, atomically: true, encoding: .utf8)
            try Hooks.uninstall()
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(isStrictJSON(text))
            let expected = try Hooks.parse(#"{"hooks": {"Stop": [\#(Self.other)]}}"#)
            #expect(NSDictionary(dictionary: try parsed(file)).isEqual(to: expected))
        }
    }

    @Test func uninstallEmptiedEventLastInHooks() throws {
        try withSettings(nil) { file in
            try #"{"hooks": {"Other": [\#(Self.other)], "Stop": [\#(Hooks.entry(matcher: false))]}}"#
                .write(to: file, atomically: true, encoding: .utf8)
            try Hooks.uninstall()
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(isStrictJSON(text))
            let expected = try Hooks.parse(#"{"hooks": {"Other": [\#(Self.other)]}}"#)
            #expect(NSDictionary(dictionary: try parsed(file)).isEqual(to: expected))
        }
    }

    @Test func installOverOursLastInArray() throws {
        try withSettings(nil) { file in
            try #"{"hooks": {"Stop": [\#(Self.other), \#(Hooks.entry(matcher: false))]}}"#
                .write(to: file, atomically: true, encoding: .utf8)
            try Hooks.install()
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(isStrictJSON(text))
            let hooks = try parsed(file)["hooks"] as! [String: Any]
            let stop = try [Hooks.parse(Hooks.entry(matcher: false)), Hooks.parse(Self.other)]
            #expect(NSArray(array: hooks["Stop"] as! [Any]).isEqual(to: stop))
            #expect(Set(hooks.keys) == Set(Hooks.events.map(\.name)))
        }
    }

    @Test func installOverOursLastInHooks() throws {
        try withSettings(nil) { file in
            try #"{"hooks": {"Other": [\#(Self.other)], "Stop": [\#(Hooks.entry(matcher: false))]}}"#
                .write(to: file, atomically: true, encoding: .utf8)
            try Hooks.install()
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(isStrictJSON(text))
            let hooks = try parsed(file)["hooks"] as! [String: Any]
            #expect(NSArray(array: hooks["Stop"] as! [Any]).isEqual(to: [try Hooks.parse(Hooks.entry(matcher: false))]))
            #expect(NSArray(array: hooks["Other"] as! [Any]).isEqual(to: [try Hooks.parse(Self.other)]))
            #expect(Set(hooks.keys) == Set(Hooks.events.map(\.name) + ["Other"]))
        }
    }

    @Test func strictParseRejectsTrailingComma() throws {
        #expect(throws: Hooks.Failure.self) { try Hooks.parse(#"{"a": [1, 2,]}"#, strict: true) }
        #expect(throws: Hooks.Failure.self) { try Hooks.parse(#"{"a": 1, }"#, strict: true) }
        // 字符串里的逗号和括号不算
        #expect(try Hooks.parse(#"{"a": ",]", "b": "\",}"}"#, strict: true).count == 2)
    }
}
