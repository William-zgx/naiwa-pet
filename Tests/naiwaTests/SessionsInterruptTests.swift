import Foundation
import Testing
@testable import naiwa

/// 一轮被打断、因为 API 出错结束时，奶蛙要回到空闲；没动静的会话到点自己过期
struct SessionsInterruptTests {
    final class Clock {
        var t = Date(timeIntervalSince1970: 1_000_000)
    }

    func make() -> (Sessions, Clock) {
        let s = Sessions(), c = Clock()
        s.now = { c.t }
        return (s, c)
    }

    func event(_ name: String, _ id: String = "A", _ extra: [String: Any] = [:]) -> [String: Any] {
        ["hook_event_name": name, "session_id": id, "cwd": "/tmp/proj"].merging(extra) { $1 }
    }

    @Test func interruptEndsTurn() {
        let (s, _) = make()
        _ = s.handle(event("UserPromptSubmit"))
        _ = s.handle(event("PreToolUse", "A", ["tool_name": "Bash"]))
        #expect(s.mood == .working)
        let f = s.handle(event("PostToolUseFailure", "A", ["tool_name": "Bash", "error": "interrupted", "is_interrupt": true]))
        #expect(f == nil)
        #expect(s.mood == .idle)
        #expect(s.nextExpiry == nil)
    }

    @Test func stopFailureEndsTurnWithoutReaction() {
        let (s, _) = make()
        _ = s.handle(event("UserPromptSubmit"))
        _ = s.handle(event("PreToolUse"))
        _ = s.handle(event("PostToolUse"))
        let f = s.handle(event("StopFailure", "A", ["error": "rate_limit"]))
        #expect(f == nil)
        #expect(s.mood == .idle)
    }

    @Test func plainToolFailureKeepsWorking() {
        let (s, _) = make()
        _ = s.handle(event("UserPromptSubmit"))
        _ = s.handle(event("PreToolUse"))
        _ = s.handle(event("PostToolUseFailure", "A", ["error": "exit 1", "is_interrupt": false]))
        #expect(s.mood == .working)
        _ = s.handle(event("PreToolUse"))
        _ = s.handle(event("PostToolUseFailure", "A", ["error": "exit 1"]))
        #expect(s.mood == .working)
        #expect(s.all["A"]?.tools == 2)
    }

    @Test func interruptClearsOnlyItsOwnWaiting() {
        let (s, _) = make()
        _ = s.handle(event("UserPromptSubmit", "A"))
        _ = s.handle(event("UserPromptSubmit", "B"))
        _ = s.handle(event("PreToolUse", "A"))
        _ = s.handle(event("Notification", "A", ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"]))
        #expect(s.mood == .waiting)
        _ = s.handle(event("PostToolUseFailure", "A", ["is_interrupt": true]))
        #expect(s.waitingText == nil)
        #expect(s.mood == .working)   // B 还在干
        _ = s.handle(event("StopFailure", "B"))
        #expect(s.mood == .idle)
    }

    @Test func nextExpiryIsEarliestBusySession() {
        let (s, c) = make()
        #expect(s.nextExpiry == nil)
        let t0 = c.t
        _ = s.handle(event("UserPromptSubmit", "A"))
        c.t = t0.addingTimeInterval(60)
        _ = s.handle(event("UserPromptSubmit", "B"))
        _ = s.handle(event("SessionStart", "C"))   // 没在干活的不算
        #expect(s.nextExpiry == t0.addingTimeInterval(Sessions.expiry))
        c.t = t0.addingTimeInterval(Sessions.expiry)
        #expect(s.mood == .working)   // A 到点了，B 还没
        #expect(s.all["A"]?.start == nil)
        #expect(s.nextExpiry == t0.addingTimeInterval(60 + Sessions.expiry))
        c.t = t0.addingTimeInterval(60 + Sessions.expiry)
        #expect(s.mood == .idle)
        #expect(s.nextExpiry == nil)
    }
}
