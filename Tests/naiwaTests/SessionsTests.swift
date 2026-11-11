import Foundation
import XCTest
@testable import naiwa

final class SessionsTests: XCTestCase {
    private let sessionID = "session"

    func testLongRunningToolSurvivesSilenceAndPreservesFinish() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let sessions = Sessions(now: { now })

        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-long"))
        now.addTimeInterval(1801)

        XCTAssertEqual(sessions.mood, .working)
        XCTAssertEqual(sessions.all[sessionID]?.outstandingTools, ["tool-long"])

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-long"))
        guard let finished = sessions.handle(event("Stop")) else {
            return XCTFail("Stop should finish the original session")
        }
        XCTAssertEqual(finished.seconds, 1801, accuracy: 0.001)
        XCTAssertEqual(finished.tier, Sessions.tier(seconds: 1801, tools: 1))
        XCTAssertEqual(finished.project, "project")
        XCTAssertEqual(sessions.mood, .idle)
    }

    func testFailedLongRunningToolCompletesAndPreservesFinish() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let sessions = Sessions(now: { now })

        XCTAssertTrue(Hooks.events.contains { $0.name == "PostToolUseFailure" })
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-failure"))
        now.addTimeInterval(1801)
        _ = sessions.handle(notification("permission_prompt", toolUseID: "tool-failure",
                                         message: "Claude needs your permission to use Bash"))
        XCTAssertEqual(sessions.mood, .waiting)
        _ = sessions.handle(event("PostToolUseFailure", toolUseID: "tool-failure"))

        XCTAssertEqual(sessions.all[sessionID]?.outstandingTools, [])
        XCTAssertNil(sessions.waitingText)
        guard let finished = sessions.handle(event("Stop")) else {
            return XCTFail("Stop should finish a session whose tool failed")
        }
        XCTAssertEqual(finished.seconds, 1801, accuracy: 0.001)
        XCTAssertEqual(finished.tier, Sessions.tier(seconds: 1801, tools: 1))
    }

    func testFailureOnlyCompletesMatchingOutstandingTool() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let sessions = Sessions(now: { now })

        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-one"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-two"))
        _ = sessions.handle(event("PostToolUseFailure", toolUseID: "tool-one"))

        XCTAssertEqual(sessions.all[sessionID]?.outstandingTools, ["tool-two"])
        now.addTimeInterval(1801)
        XCTAssertEqual(sessions.mood, .working)

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-two"))
        XCTAssertEqual(sessions.all[sessionID]?.outstandingTools, [])
        now.addTimeInterval(1801)
        XCTAssertEqual(sessions.mood, .idle)
    }

    func testAbandonedSessionWithoutOutstandingToolIsPruned() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let sessions = Sessions(now: { now })

        _ = sessions.handle(event("UserPromptSubmit"))
        now.addTimeInterval(1801)

        XCTAssertEqual(sessions.mood, .idle)
        XCTAssertNil(sessions.all[sessionID]?.start)
    }

    func testParallelToolCompletionDoesNotClearOtherApproval() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-B"))
        _ = sessions.handle(notification("permission_prompt", toolUseID: "tool-B",
                                         message: "Claude needs your permission to use Bash"))

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-A"))

        XCTAssertEqual(sessions.mood, .waiting)
        XCTAssertEqual(sessions.waitingText, "project 等你批准 Bash")

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-B"))

        XCTAssertEqual(sessions.mood, .working)
        XCTAssertNil(sessions.waitingText)
    }

    func testAnswerNotificationClearsMatchingRequestAfterOtherToolCompletes() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-B"))
        _ = sessions.handle(notification("elicitation_dialog", requestID: "request-B"))
        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-A"))

        XCTAssertEqual(sessions.mood, .waiting)
        XCTAssertEqual(sessions.waitingText, "project 等你回复")

        _ = sessions.handle(notification("elicitation_response", requestID: "request-B"))

        XCTAssertEqual(sessions.mood, .working)
        XCTAssertNil(sessions.waitingText)
    }

    func testIDLessApprovalUsesMostRecentPreToolUse() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-B"))
        _ = sessions.handle(notification("permission_prompt",
                                         message: "Claude needs your permission to use Bash"))

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-A"))

        XCTAssertEqual(sessions.mood, .waiting)
        XCTAssertEqual(sessions.waitingText, "project 等你批准 Bash")

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-B"))

        XCTAssertEqual(sessions.mood, .working)
        XCTAssertNil(sessions.waitingText)
    }

    func testIDLessApprovalClearsWithResidualOutstandingToolAfterFailure() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-residual"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-failed"))
        _ = sessions.handle(event("PostToolUseFailure", toolUseID: "tool-failed"))
        XCTAssertEqual(sessions.all[sessionID]?.outstandingTools, ["tool-residual"])

        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-approval"))
        _ = sessions.handle(notification("permission_prompt",
                                         message: "Claude needs your permission to use Bash"))
        XCTAssertEqual(sessions.mood, .waiting)

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-approval"))

        XCTAssertNil(sessions.waitingText)
        XCTAssertEqual(sessions.all[sessionID]?.outstandingTools, ["tool-residual"])
        XCTAssertEqual(sessions.mood, .working)
    }

    private func event(_ name: String, toolUseID: String? = nil) -> [String: Any] {
        var event: [String: Any] = [
            "hook_event_name": name,
            "session_id": sessionID,
            "cwd": "/data00/example/project",
        ]
        event["tool_use_id"] = toolUseID
        return event
    }

    private func notification(_ type: String, toolUseID: String? = nil, requestID: String? = nil,
                              message: String = "") -> [String: Any] {
        var extra: [String: Any] = ["notification_type": type, "message": message]
        if let toolUseID { extra["tool_use_id"] = toolUseID }
        if let requestID { extra["request_id"] = requestID }
        return event("Notification").merging(extra) { $1 }
    }
}
