import Foundation
import Testing
@testable import naiwa

struct SessionsProjectTests {
    func event(_ name: String, cwd: String?, _ extra: [String: Any] = [:]) -> [String: Any] {
        var e: [String: Any] = ["hook_event_name": name, "session_id": "s1"]
        if let cwd { e["cwd"] = cwd }
        return e.merging(extra) { $1 }
    }

    /// Claude cd 进子目录后，项目名还是会话开始时的目录
    @Test func projectKeepsFirstCwd() {
        let s = Sessions()
        let root = "/Users/x/my-repo", sub = "/Users/x/my-repo/Sources/naiwa"
        _ = s.handle(event("UserPromptSubmit", cwd: root))
        _ = s.handle(event("PreToolUse", cwd: root))
        _ = s.handle(event("PostToolUse", cwd: sub))
        _ = s.handle(event("Notification", cwd: sub, ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"]))
        #expect(s.waitingText == "my-repo 等你批准 Bash")
        let f = s.handle(event("Stop", cwd: sub, ["naiwa_seconds": 999.0]))
        #expect(f?.project == "my-repo")
    }

    /// 第一个事件没带 cwd（或是空的），后面带了就用后面的
    @Test func picksUpLateCwd() {
        let s = Sessions()
        _ = s.handle(event("UserPromptSubmit", cwd: nil))
        _ = s.handle(event("PreToolUse", cwd: ""))
        _ = s.handle(event("PostToolUse", cwd: "/Users/x/my-repo"))
        _ = s.handle(event("PreToolUse", cwd: "/Users/x/my-repo/Sources"))
        let f = s.handle(event("Stop", cwd: "/Users/x/my-repo/Sources", ["naiwa_seconds": 999.0]))
        #expect(f?.project == "my-repo")
    }
}
