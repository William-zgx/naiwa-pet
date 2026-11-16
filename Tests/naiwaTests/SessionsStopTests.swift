import Foundation
import Testing
@testable import naiwa

/// 别的 Stop hook 拦下结束（decision: block）时，同一轮的两次 Stop 要算成一轮
struct SessionsStopTests {
    let t0 = Date()   // mood 按真实时间清掉半小时没动静的会话，不能用很早的时间
    let b = Prefs.bigSeconds

    func ev(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["hook_event_name": name, "session_id": "s1", "cwd": "/tmp/my-repo"].merging(extra) { $1 }
    }

    @Test func singleStopGlancesOnce() {
        let s = Sessions()
        _ = s.handle(ev("UserPromptSubmit"), now: t0)
        _ = s.handle(ev("PreToolUse"), now: t0 + 1)
        let f = s.handle(ev("Stop", ["stop_hook_active": false]), now: t0 + 2 * b)
        #expect(f?.tier != Sessions.Tier.none)
        #expect(f?.seconds == 2 * b)
        #expect(s.mood == .idle)
    }

    @Test func blockedStopThenContinuationGlancesOnce() {
        let s = Sessions()
        _ = s.handle(ev("UserPromptSubmit"), now: t0)
        _ = s.handle(ev("PreToolUse"), now: t0 + 1)
        let f1 = s.handle(ev("Stop", ["stop_hook_active": false]), now: t0 + 2 * b)
        #expect(f1?.tier != Sessions.Tier.none)
        _ = s.handle(ev("PreToolUse"), now: t0 + 3 * b)
        #expect(s.mood == .working)
        let f2 = s.handle(ev("Stop", ["stop_hook_active": true]), now: t0 + 4 * b)
        #expect(f2?.tier == Sessions.Tier.none)
        #expect(f2?.seconds == 4 * b)
        #expect(s.mood == .idle)
        // 再被拦一次也不瞥
        let f3 = s.handle(ev("Stop", ["stop_hook_active": true]), now: t0 + 5 * b)
        #expect(f3?.tier == Sessions.Tier.none)
        #expect(f3?.seconds == 5 * b)
    }

    @Test func continuationCountsWholeTurn() {
        // 第一段太短没瞥；接着干到够长，按整轮算，前一段的工具也算
        let s = Sessions()
        _ = s.handle(ev("UserPromptSubmit"), now: t0)
        _ = s.handle(ev("PreToolUse"), now: t0 + 1)
        let f1 = s.handle(ev("Stop", ["stop_hook_active": false]), now: t0 + b / 2)
        #expect(f1?.tier == Sessions.Tier.none)
        let f2 = s.handle(ev("Stop", ["stop_hook_active": true]), now: t0 + 1.5 * b)
        #expect(f2?.tier != Sessions.Tier.none)
        #expect(f2?.seconds == 1.5 * b)
    }

    @Test func newPromptStartsNewTurn() {
        let s = Sessions()
        _ = s.handle(ev("UserPromptSubmit"), now: t0)
        _ = s.handle(ev("PreToolUse"), now: t0 + 1)
        _ = s.handle(ev("Stop"), now: t0 + 2 * b)
        _ = s.handle(ev("UserPromptSubmit"), now: t0 + 3 * b)
        _ = s.handle(ev("PreToolUse"), now: t0 + 3 * b + 1)
        let f = s.handle(ev("Stop", ["stop_hook_active": true]), now: t0 + 5 * b)
        #expect(f?.tier != Sessions.Tier.none)
        #expect(f?.seconds == 2 * b)
    }
}
