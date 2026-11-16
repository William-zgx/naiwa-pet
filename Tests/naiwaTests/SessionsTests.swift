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
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-residual", toolName: "Read"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-failed", toolName: "Edit"))
        _ = sessions.handle(event("PostToolUseFailure", toolUseID: "tool-failed"))
        XCTAssertEqual(sessions.all[sessionID]?.outstandingTools, ["tool-residual"])

        // PreToolUse carries tool_name, so the "permission to use Bash" notification names its owner even
        // though the Notification payload has no tool_use_id.
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-approval", toolName: "Bash"))
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

    // MARK: Notification has no tool_use_id (SDK NotificationHookInput: message, title?, notification_type)

    /// Probe from the review: A and B run in parallel, A is the one that needs approval, the notification has no ID.
    /// Attributing it to the latest PreToolUse (B) would let B's completion clear A's wait.
    func testMisattributionWhenFirstParallelToolNeedsApproval() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-B"))
        _ = sessions.handle(notification("permission_prompt",
                                         message: "Claude needs your permission to use Bash"))

        // B finishes while A is still waiting for the user.
        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-B"))

        XCTAssertEqual(sessions.mood, .waiting)
        XCTAssertEqual(sessions.waitingText, "project 等你批准 Bash")

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-A"))
        XCTAssertEqual(sessions.mood, .working)
        XCTAssertNil(sessions.waitingText)
    }

    func testIDLessApprovalWithOneOutstandingToolStaysOnThatTool() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A"))
        _ = sessions.handle(notification("permission_prompt",
                                         message: "Claude needs your permission to use Bash"))

        XCTAssertEqual(sessions.all[sessionID]?.waiting.keys.sorted(), ["tool-A"])
        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-A"))
        XCTAssertNil(sessions.waitingText)
    }

    func testIDLessApprovalNamingOneOutstandingToolIsAttributedToIt() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A", toolName: "Bash"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-B", toolName: "Read"))
        _ = sessions.handle(notification("permission_prompt",
                                         message: "Claude needs your permission to use Bash"))
        XCTAssertEqual(sessions.all[sessionID]?.waiting.keys.sorted(), ["tool-A"])

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-B"))
        XCTAssertEqual(sessions.mood, .waiting)
        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-A"))
        XCTAssertEqual(sessions.mood, .working)
    }

    func testIDLessApprovalNamingAmbiguousToolFallsBackToUnassigned() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A", toolName: "Bash"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-B", toolName: "Bash"))
        _ = sessions.handle(notification("permission_prompt",
                                         message: "Claude needs your permission to use Bash"))
        XCTAssertEqual(sessions.all[sessionID]?.waiting.keys.sorted(), [""])
    }

    func testUnassignedWaitIsKeptUntilEveryOutstandingToolFinishes() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-B"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-C"))
        _ = sessions.handle(notification("permission_prompt",
                                         message: "Claude needs your permission to use Bash"))

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-A"))
        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-C"))
        XCTAssertEqual(sessions.mood, .waiting)
        // A third tool starting does not release it while the others are still running.
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-D"))
        XCTAssertEqual(sessions.mood, .waiting)

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-D"))
        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-B"))
        XCTAssertEqual(sessions.mood, .working)
        XCTAssertNil(sessions.waitingText)
    }

    func testUnassignedWaitIsClearedByStopPromptAndSessionEnd() {
        for clearing in ["Stop", "UserPromptSubmit", "SessionEnd"] {
            let sessions = Sessions()
            _ = sessions.handle(event("UserPromptSubmit"))
            _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A"))
            _ = sessions.handle(event("PreToolUse", toolUseID: "tool-B"))
            _ = sessions.handle(notification("permission_prompt",
                                             message: "Claude needs your permission to use Bash"))
            XCTAssertEqual(sessions.mood, .waiting, clearing)

            _ = sessions.handle(event(clearing))

            XCTAssertNil(sessions.waitingText, clearing)
            XCTAssertNotEqual(sessions.mood, .waiting, clearing)
            XCTAssertTrue(sessions.all[sessionID]?.toolStarts.isEmpty ?? true, clearing)
        }
    }

    func testUnassignedWaitIsClearedWhenTheCapDropsEveryTool() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let sessions = Sessions(now: { now })
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-B"))
        _ = sessions.handle(notification("permission_prompt",
                                         message: "Claude needs your permission to use Bash"))
        now.addTimeInterval(Sessions.maxToolSeconds + 1)
        // Keep the session alive so the 30-minute silence rule cannot be what clears the wait.
        _ = sessions.handle(notification("idle_prompt"))

        XCTAssertEqual(sessions.mood, .working)
        XCTAssertNil(sessions.waitingText)
        XCTAssertEqual(sessions.all[sessionID]?.outstandingTools, [])
    }

    // MARK: Hard cap details

    /// The cap measures each tool's own start, not the session's last event: a session that keeps producing
    /// events must still drop a tool that has been outstanding for more than maxToolSeconds.
    func testCapMeasuresPerToolStartNotLastSessionEvent() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let sessions = Sessions(now: { now })
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-old"))
        now.addTimeInterval(5 * 3600)
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-recent"))
        // The session stays busy: an event every ten minutes keeps `seen` fresh.
        for _ in 0..<7 {
            now.addTimeInterval(600)
            _ = sessions.handle(notification("idle_prompt"))
        }
        // tool-old is now 7 h old, tool-recent 2 h; the last event was 50 minutes ago.
        now.addTimeInterval(3000)

        XCTAssertEqual(sessions.mood, .working)
        XCTAssertEqual(sessions.all[sessionID]?.outstandingTools, ["tool-recent"])
    }

    /// A no-ID prompt arriving after the cap dropped the latest tool must not be pinned to that dead ID.
    func testIDLessPromptAfterCapDroppedLatestToolIsNotPinnedToIt() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let sessions = Sessions(now: { now })
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-dead"))
        now.addTimeInterval(Sessions.maxToolSeconds + 1)
        // Keep the session alive so the 30-minute silence rule cannot be what clears latestToolUseID.
        _ = sessions.handle(notification("idle_prompt"))
        XCTAssertEqual(sessions.all[sessionID]?.outstandingTools, ["tool-dead"]) // only dropped when mood is read
        _ = sessions.mood
        XCTAssertEqual(sessions.all[sessionID]?.outstandingTools, [])
        XCTAssertNil(sessions.all[sessionID]?.latestToolUseID)

        _ = sessions.handle(notification("elicitation_dialog"))
        XCTAssertEqual(sessions.mood, .waiting)
        XCTAssertEqual(sessions.all[sessionID]?.waiting.keys.sorted(), [""])

        // The next tool starting releases it, as for any ID-less wait with nothing outstanding.
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-next"))
        XCTAssertEqual(sessions.mood, .working)
        XCTAssertNil(sessions.waitingText)
    }

    func testCapKeepsOtherToolsApproval() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let sessions = Sessions(now: { now })
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-old"))
        now.addTimeInterval(5 * 3600)
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-recent"))
        _ = sessions.handle(notification("permission_prompt", toolUseID: "tool-recent",
                                         message: "Claude needs your permission to use Bash"))
        now.addTimeInterval(3600 + 1) // tool-old is past the cap, tool-recent is not

        XCTAssertEqual(sessions.mood, .waiting)
        XCTAssertEqual(sessions.waitingText, "project 等你批准 Bash")
        XCTAssertEqual(sessions.all[sessionID]?.outstandingTools, ["tool-recent"])
    }

    func testCapClearsTheDroppedToolsOwnApproval() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let sessions = Sessions(now: { now })
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-old"))
        now.addTimeInterval(5 * 3600)
        // A running tool next to it: a new PreToolUse would otherwise release the lone approval.
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-recent"))
        _ = sessions.handle(notification("permission_prompt", toolUseID: "tool-old",
                                         message: "Claude needs your permission to use Bash"))
        XCTAssertEqual(sessions.mood, .waiting)
        now.addTimeInterval(3600 + 1)

        XCTAssertEqual(sessions.mood, .working)
        XCTAssertNil(sessions.waitingText)
        XCTAssertEqual(sessions.all[sessionID]?.outstandingTools, ["tool-recent"])
        XCTAssertNil(sessions.all[sessionID]?.waiting["tool-old"])
    }

    private func event(_ name: String, toolUseID: String? = nil, toolName: String? = nil) -> [String: Any] {
        var event: [String: Any] = [
            "hook_event_name": name,
            "session_id": sessionID,
            "cwd": "/data00/example/project",
        ]
        event["tool_use_id"] = toolUseID
        event["tool_name"] = toolName
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
