import Foundation
import Testing
@testable import naiwa

struct SessionsIntegrationTests {
    func event(_ name: String, tool: String? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        var e: [String: Any] = ["hook_event_name": name, "session_id": "test"]
        e["tool_use_id"] = tool
        return e.merging(extra) { $1 }
    }

    @Test func runningToolSchedulesHardCapAndExpiresExactlyOnTime() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let start = now
        let s = Sessions(now: { now })
        _ = s.handle(event("UserPromptSubmit"))
        _ = s.handle(event("PreToolUse", tool: "long"))
        now += Sessions.expiry
        #expect(s.mood == .working)
        #expect(s.nextExpiry == start + Sessions.maxToolSeconds)
        now = start + Sessions.maxToolSeconds
        #expect(s.mood == .idle)
        #expect(s.nextExpiry == nil)
    }

    @Test func interruptDoesNotDiscardAnotherRunningTool() {
        let s = Sessions()
        _ = s.handle(event("UserPromptSubmit"))
        _ = s.handle(event("PreToolUse", tool: "one"))
        _ = s.handle(event("PreToolUse", tool: "two"))
        _ = s.handle(event("PostToolUseFailure", tool: "one", extra: ["is_interrupt": true]))
        #expect(s.mood == .working)
        #expect(s.all["test"]?.outstandingTools == ["two"])
        _ = s.handle(event("PostToolUseFailure", tool: "two", extra: ["is_interrupt": true]))
        #expect(s.mood == .idle)
        #expect(s.nextExpiry == nil)
    }

    @Test func stopFailureDropsPreviousStopAccounting() {
        let s = Sessions()
        let start = Date()
        _ = s.handle(event("UserPromptSubmit"), now: start)
        _ = s.handle(event("PreToolUse"), now: start + 1)
        _ = s.handle(event("Stop"), now: start + 10)
        _ = s.handle(event("StopFailure"), now: start + 11)
        #expect(s.all["test"]?.stopped == nil)
    }
}
