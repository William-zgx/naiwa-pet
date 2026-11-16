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

    func testDeniedApprovalIsReleasedWhenTheNextToolStarts() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-denied"))
        _ = sessions.handle(notification("permission_prompt",
                                         message: "Claude needs your permission to use Bash"))
        XCTAssertEqual(sessions.mood, .waiting)

        // The user denied it: Claude Code sends no PostToolUse for that tool, and the model carries on.
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-next"))

        XCTAssertEqual(sessions.mood, .working)
        XCTAssertNil(sessions.waitingText)
        XCTAssertEqual(sessions.all[sessionID]?.outstandingTools, ["tool-next"])

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-next"))
        XCTAssertEqual(sessions.all[sessionID]?.outstandingTools, [])
    }

    func testRunningParallelToolKeepsAnotherToolsApprovalWhenAThirdStarts() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-B"))
        _ = sessions.handle(notification("permission_prompt", toolUseID: "tool-A",
                                         message: "Claude needs your permission to use Bash"))

        // B is still running, so A may well still be waiting for the user.
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-C"))

        XCTAssertEqual(sessions.mood, .waiting)
        XCTAssertEqual(sessions.waitingText, "project 等你批准 Bash")
        XCTAssertEqual(sessions.all[sessionID]?.outstandingTools, ["tool-A", "tool-B", "tool-C"])
    }

    func testStaleLatestToolIDDoesNotPinIdlessWaitAcrossNextTool() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A"))
        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-A"))
        _ = sessions.handle(notification("elicitation_dialog"))
        XCTAssertEqual(sessions.mood, .waiting)

        // The dialog was answered without a clearing event; the next tool must release it.
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-B"))

        XCTAssertEqual(sessions.mood, .working)
        XCTAssertNil(sessions.waitingText)
    }

    func testInterruptedToolIsDroppedAfterTheHardCap() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let sessions = Sessions(now: { now })
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-killed"))

        // Claude was killed mid-tool: no PostToolUse, no Stop, nothing for ten hours.
        now.addTimeInterval(10 * 3600)

        XCTAssertEqual(sessions.mood, .idle)
        XCTAssertEqual(sessions.all[sessionID]?.outstandingTools, [])
    }

    func testToolJustUnderTheHardCapIsKept() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let sessions = Sessions(now: { now })
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-long"))
        now.addTimeInterval(Sessions.maxToolSeconds - 60)

        XCTAssertEqual(sessions.mood, .working)
        XCTAssertEqual(sessions.all[sessionID]?.outstandingTools, ["tool-long"])

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-long"))
        guard let finished = sessions.handle(event("Stop")) else {
            return XCTFail("Stop should finish the original session")
        }
        XCTAssertEqual(finished.seconds, Sessions.maxToolSeconds - 60, accuracy: 0.001)
    }

    func testDeniedToolNextToRunningToolIsDroppedByTheHardCap() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let sessions = Sessions(now: { now })
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-denied"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-running"))
        _ = sessions.handle(notification("permission_prompt", toolUseID: "tool-denied",
                                         message: "Claude needs your permission to use Bash"))
        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-running"))
        XCTAssertEqual(sessions.mood, .waiting)

        now.addTimeInterval(Sessions.maxToolSeconds + 1)

        XCTAssertEqual(sessions.mood, .idle)
        XCTAssertNil(sessions.waitingText)
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
