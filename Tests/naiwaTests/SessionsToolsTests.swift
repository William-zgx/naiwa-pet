import Foundation
import Testing
@testable import naiwa

struct SessionsToolsTests {
    private let sessionID = "session"

    @Test func testLongRunningToolSurvivesSilenceAndPreservesFinish() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let sessions = Sessions(now: { now })

        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-long"))
        now.addTimeInterval(1801)

        #expect(sessions.mood == .working)
        #expect(sessions.all[sessionID]?.outstandingTools == ["tool-long"])

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-long"))
        guard let finished = sessions.handle(event("Stop")) else {
            Issue.record("Stop should finish the original session")
            return
        }
        #expect(abs(finished.seconds - (1801)) <= 0.001)
        #expect(finished.tier == Sessions.tier(seconds: 1801, tools: 1))
        #expect(finished.project == "project")
        #expect(sessions.mood == .idle)
    }

    @Test func testFailedLongRunningToolCompletesAndPreservesFinish() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let sessions = Sessions(now: { now })

        #expect(Hooks.events.contains { $0.name == "PostToolUseFailure" })
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-failure"))
        now.addTimeInterval(1801)
        _ = sessions.handle(notification("permission_prompt", toolUseID: "tool-failure",
                                         message: "Claude needs your permission to use Bash"))
        #expect(sessions.mood == .waiting)
        _ = sessions.handle(event("PostToolUseFailure", toolUseID: "tool-failure"))

        #expect(sessions.all[sessionID]?.outstandingTools == [])
        #expect(sessions.waitingText == nil)
        guard let finished = sessions.handle(event("Stop")) else {
            Issue.record("Stop should finish a session whose tool failed")
            return
        }
        #expect(abs(finished.seconds - (1801)) <= 0.001)
        #expect(finished.tier == Sessions.tier(seconds: 1801, tools: 1))
    }

    @Test func testFailureOnlyCompletesMatchingOutstandingTool() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let sessions = Sessions(now: { now })

        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-one"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-two"))
        _ = sessions.handle(event("PostToolUseFailure", toolUseID: "tool-one"))

        #expect(sessions.all[sessionID]?.outstandingTools == ["tool-two"])
        now.addTimeInterval(1801)
        #expect(sessions.mood == .working)

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-two"))
        #expect(sessions.all[sessionID]?.outstandingTools == [])
        now.addTimeInterval(1801)
        #expect(sessions.mood == .idle)
    }

    @Test func testAbandonedSessionWithoutOutstandingToolIsPruned() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let sessions = Sessions(now: { now })

        _ = sessions.handle(event("UserPromptSubmit"))
        now.addTimeInterval(1801)

        #expect(sessions.mood == .idle)
        #expect(sessions.all[sessionID]?.start == nil)
    }

    @Test func testParallelToolCompletionDoesNotClearOtherApproval() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-B"))
        _ = sessions.handle(notification("permission_prompt", toolUseID: "tool-B",
                                         message: "Claude needs your permission to use Bash"))

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-A"))

        #expect(sessions.mood == .waiting)
        #expect(sessions.waitingText == "project 等你批准 Bash")

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-B"))

        #expect(sessions.mood == .working)
        #expect(sessions.waitingText == nil)
    }

    @Test func testAnswerNotificationClearsMatchingRequestAfterOtherToolCompletes() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-B"))
        _ = sessions.handle(notification("elicitation_dialog", requestID: "request-B"))
        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-A"))

        #expect(sessions.mood == .waiting)
        #expect(sessions.waitingText == "project 等你回复")

        _ = sessions.handle(notification("elicitation_response", requestID: "request-B"))

        #expect(sessions.mood == .working)
        #expect(sessions.waitingText == nil)
    }

    @Test func testAmbiguousIDLessApprovalSurvivesFirstCompletion() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-B"))
        _ = sessions.handle(notification("permission_prompt",
                                         message: "Claude needs your permission to use Bash"))

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-A"))

        #expect(sessions.mood == .waiting)
        #expect(sessions.waitingText == "project 等你批准 Bash")

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-B"))

        #expect(sessions.mood == .working)
        #expect(sessions.waitingText == nil)
    }

    @Test func testIDLessApprovalClearsWithResidualOutstandingToolAfterFailure() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-residual", toolName: "Read"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-failed", toolName: "Edit"))
        _ = sessions.handle(event("PostToolUseFailure", toolUseID: "tool-failed"))
        #expect(sessions.all[sessionID]?.outstandingTools == ["tool-residual"])

        // PreToolUse carries tool_name, so the "permission to use Bash" notification names its owner even
        // though the Notification payload has no tool_use_id.
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-approval", toolName: "Bash"))
        _ = sessions.handle(notification("permission_prompt",
                                         message: "Claude needs your permission to use Bash"))
        #expect(sessions.mood == .waiting)

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-approval"))

        #expect(sessions.waitingText == nil)
        #expect(sessions.all[sessionID]?.outstandingTools == ["tool-residual"])
        #expect(sessions.mood == .working)
    }

    @Test func testDeniedApprovalIsReleasedWhenTheNextToolStarts() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-denied"))
        _ = sessions.handle(notification("permission_prompt",
                                         message: "Claude needs your permission to use Bash"))
        #expect(sessions.mood == .waiting)

        // The user denied it: Claude Code sends no PostToolUse for that tool, and the model carries on.
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-next"))

        #expect(sessions.mood == .working)
        #expect(sessions.waitingText == nil)
        #expect(sessions.all[sessionID]?.outstandingTools == ["tool-next"])

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-next"))
        #expect(sessions.all[sessionID]?.outstandingTools == [])
    }

    @Test func testRunningParallelToolKeepsAnotherToolsApprovalWhenAThirdStarts() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-B"))
        _ = sessions.handle(notification("permission_prompt", toolUseID: "tool-A",
                                         message: "Claude needs your permission to use Bash"))

        // B is still running, so A may well still be waiting for the user.
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-C"))

        #expect(sessions.mood == .waiting)
        #expect(sessions.waitingText == "project 等你批准 Bash")
        #expect(sessions.all[sessionID]?.outstandingTools == ["tool-A", "tool-B", "tool-C"])
    }

    @Test func testStaleLatestToolIDDoesNotPinIdlessWaitAcrossNextTool() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A"))
        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-A"))
        _ = sessions.handle(notification("elicitation_dialog"))
        #expect(sessions.mood == .waiting)

        // The dialog was answered without a clearing event; the next tool must release it.
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-B"))

        #expect(sessions.mood == .working)
        #expect(sessions.waitingText == nil)
    }

    @Test func testInterruptedToolIsDroppedAfterTheHardCap() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let sessions = Sessions(now: { now })
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-killed"))

        // Claude was killed mid-tool: no PostToolUse, no Stop, nothing for ten hours.
        now.addTimeInterval(10 * 3600)

        #expect(sessions.mood == .idle)
        #expect(sessions.all[sessionID]?.outstandingTools == [])
    }

    @Test func testToolJustUnderTheHardCapIsKept() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let sessions = Sessions(now: { now })
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-long"))
        now.addTimeInterval(Sessions.maxToolSeconds - 60)

        #expect(sessions.mood == .working)
        #expect(sessions.all[sessionID]?.outstandingTools == ["tool-long"])

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-long"))
        guard let finished = sessions.handle(event("Stop")) else {
            Issue.record("Stop should finish the original session")
            return
        }
        #expect(abs(finished.seconds - (Sessions.maxToolSeconds - 60)) <= 0.001)
    }

    @Test func testDeniedToolNextToRunningToolIsDroppedByTheHardCap() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let sessions = Sessions(now: { now })
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-denied"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-running"))
        _ = sessions.handle(notification("permission_prompt", toolUseID: "tool-denied",
                                         message: "Claude needs your permission to use Bash"))
        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-running"))
        #expect(sessions.mood == .waiting)

        now.addTimeInterval(Sessions.maxToolSeconds + 1)

        #expect(sessions.mood == .idle)
        #expect(sessions.waitingText == nil)
    }

    // MARK: Notification has no tool_use_id (SDK NotificationHookInput: message, title?, notification_type)

    /// Probe from the review: A and B run in parallel, A is the one that needs approval, the notification has no ID.
    /// Attributing it to the latest PreToolUse (B) would let B's completion clear A's wait.
    @Test func testMisattributionWhenFirstParallelToolNeedsApproval() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-B"))
        _ = sessions.handle(notification("permission_prompt",
                                         message: "Claude needs your permission to use Bash"))

        // B finishes while A is still waiting for the user.
        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-B"))

        #expect(sessions.mood == .waiting)
        #expect(sessions.waitingText == "project 等你批准 Bash")

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-A"))
        #expect(sessions.mood == .working)
        #expect(sessions.waitingText == nil)
    }

    @Test func testIDLessApprovalAfterTheLatestToolFinishedIsAttributedToTheOnlyOutstandingTool() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-B"))
        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-B"))
        _ = sessions.handle(notification("permission_prompt",
                                         message: "Claude needs your permission to use Bash"))

        #expect(sessions.all[sessionID]?.waiting.keys.sorted() == ["tool-A"])
        #expect(sessions.mood == .waiting)

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-A"))
        #expect(sessions.waitingText == nil)
        #expect(sessions.mood == .working)
    }

    @Test func testDeniedToolAfterTheLatestToolFinishedIsReleasedByTheNextPreToolUse() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-B"))
        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-B"))
        _ = sessions.handle(notification("permission_prompt",
                                         message: "Claude needs your permission to use Bash"))
        #expect(sessions.mood == .waiting)

        // A is denied: no PostToolUse for it. The next tool starting releases the wait.
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-C"))

        #expect(sessions.waitingText == nil)
        #expect(sessions.mood == .working)
        #expect(sessions.all[sessionID]?.outstandingTools == ["tool-C"])
    }

    @Test func testIDLessApprovalWithOneOutstandingToolStaysOnThatTool() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A"))
        _ = sessions.handle(notification("permission_prompt",
                                         message: "Claude needs your permission to use Bash"))

        #expect(sessions.all[sessionID]?.waiting.keys.sorted() == ["tool-A"])
        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-A"))
        #expect(sessions.waitingText == nil)
    }

    @Test func testIDLessApprovalNamingOneOutstandingToolIsAttributedToIt() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A", toolName: "Bash"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-B", toolName: "Read"))
        _ = sessions.handle(notification("permission_prompt",
                                         message: "Claude needs your permission to use Bash"))
        #expect(sessions.all[sessionID]?.waiting.keys.sorted() == ["tool-A"])

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-B"))
        #expect(sessions.mood == .waiting)
        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-A"))
        #expect(sessions.mood == .working)
    }

    @Test func testIDLessApprovalNamingAmbiguousToolFallsBackToUnassigned() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A", toolName: "Bash"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-B", toolName: "Bash"))
        _ = sessions.handle(notification("permission_prompt",
                                         message: "Claude needs your permission to use Bash"))
        #expect(sessions.all[sessionID]?.waiting.keys.sorted() == [""])
    }

    @Test func testUnassignedWaitIsKeptUntilEveryOutstandingToolFinishes() {
        let sessions = Sessions()
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-B"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-C"))
        _ = sessions.handle(notification("permission_prompt",
                                         message: "Claude needs your permission to use Bash"))

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-A"))
        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-C"))
        #expect(sessions.mood == .waiting)
        // A third tool starting does not release it while the others are still running.
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-D"))
        #expect(sessions.mood == .waiting)

        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-D"))
        _ = sessions.handle(event("PostToolUse", toolUseID: "tool-B"))
        #expect(sessions.mood == .working)
        #expect(sessions.waitingText == nil)
    }

    @Test func testUnassignedWaitIsClearedByStopPromptAndSessionEnd() {
        for clearing in ["Stop", "UserPromptSubmit", "SessionEnd"] {
            let sessions = Sessions()
            _ = sessions.handle(event("UserPromptSubmit"))
            _ = sessions.handle(event("PreToolUse", toolUseID: "tool-A"))
            _ = sessions.handle(event("PreToolUse", toolUseID: "tool-B"))
            _ = sessions.handle(notification("permission_prompt",
                                             message: "Claude needs your permission to use Bash"))
            #expect(sessions.mood == .waiting, "\(clearing)")

            _ = sessions.handle(event(clearing))

            #expect(sessions.waitingText == nil, "\(clearing)")
            #expect(sessions.mood != .waiting, "\(clearing)")
            #expect(sessions.all[sessionID]?.toolStarts.isEmpty ?? true, "\(clearing)")
        }
    }

    @Test func testUnassignedWaitIsClearedWhenTheCapDropsEveryTool() {
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

        #expect(sessions.mood == .working)
        #expect(sessions.waitingText == nil)
        #expect(sessions.all[sessionID]?.outstandingTools == [])
    }

    // MARK: Hard cap details

    /// The cap measures each tool's own start, not the session's last event: a session that keeps producing
    /// events must still drop a tool that has been outstanding for more than maxToolSeconds.
    @Test func testCapMeasuresPerToolStartNotLastSessionEvent() {
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

        #expect(sessions.mood == .working)
        #expect(sessions.all[sessionID]?.outstandingTools == ["tool-recent"])
    }

    /// A no-ID prompt arriving after the cap dropped the latest tool must not be pinned to that dead ID.
    @Test func testIDLessPromptAfterCapDroppedLatestToolIsNotPinnedToIt() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let sessions = Sessions(now: { now })
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-dead"))
        now.addTimeInterval(Sessions.maxToolSeconds + 1)
        // Keep the session alive so the 30-minute silence rule cannot be what clears latestToolUseID.
        _ = sessions.handle(notification("idle_prompt"))
        #expect(sessions.all[sessionID]?.outstandingTools == ["tool-dead"]) // only dropped when mood is read
        _ = sessions.mood
        #expect(sessions.all[sessionID]?.outstandingTools == [])
        #expect(sessions.all[sessionID]?.latestToolUseID == nil)

        _ = sessions.handle(notification("elicitation_dialog"))
        #expect(sessions.mood == .waiting)
        #expect(sessions.all[sessionID]?.waiting.keys.sorted() == [""])

        // The next tool starting releases it, as for any ID-less wait with nothing outstanding.
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-next"))
        #expect(sessions.mood == .working)
        #expect(sessions.waitingText == nil)
    }

    @Test func testCapKeepsOtherToolsApproval() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let sessions = Sessions(now: { now })
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-old"))
        now.addTimeInterval(5 * 3600)
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-recent"))
        _ = sessions.handle(notification("permission_prompt", toolUseID: "tool-recent",
                                         message: "Claude needs your permission to use Bash"))
        now.addTimeInterval(3600 + 1) // tool-old is past the cap, tool-recent is not

        #expect(sessions.mood == .waiting)
        #expect(sessions.waitingText == "project 等你批准 Bash")
        #expect(sessions.all[sessionID]?.outstandingTools == ["tool-recent"])
    }

    @Test func testCapClearsTheDroppedToolsOwnApproval() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let sessions = Sessions(now: { now })
        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-old"))
        now.addTimeInterval(5 * 3600)
        // A running tool next to it: a new PreToolUse would otherwise release the lone approval.
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-recent"))
        _ = sessions.handle(notification("permission_prompt", toolUseID: "tool-old",
                                         message: "Claude needs your permission to use Bash"))
        #expect(sessions.mood == .waiting)
        now.addTimeInterval(3600 + 1)

        #expect(sessions.mood == .working)
        #expect(sessions.waitingText == nil)
        #expect(sessions.all[sessionID]?.outstandingTools == ["tool-recent"])
        #expect(sessions.all[sessionID]?.waiting["tool-old"] == nil)
    }

    private func event(_ name: String, toolUseID: String? = nil, toolName: String? = nil) -> [String: Any] {
        var event: [String: Any] = [
            "hook_event_name": name,
            "session_id": sessionID,
            "cwd": "/tmp/example/project",
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
