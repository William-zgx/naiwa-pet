import Foundation
import Testing
@testable import naiwa

extension HooksTests {
    /// 打断（PostToolUseFailure）和 API 出错（StopFailure）也要装上，不然奶蛙一直以为还在干活
    @Test func installsFailureEvents() throws {
        try withSettings("{}\n") { file in
            try Hooks.install()
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(isStrictJSON(text))
            let hooks = try Hooks.parse(text)["hooks"] as? [String: Any] ?? [:]
            let failure = (hooks["PostToolUseFailure"] as? [[String: Any]])?.first
            #expect(failure?["matcher"] as? String == "*")
            let stop = (hooks["StopFailure"] as? [[String: Any]])?.first
            #expect(stop != nil && stop?["matcher"] == nil)
        }
    }
}
