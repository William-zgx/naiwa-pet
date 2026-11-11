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

        _ = sessions.handle(event("UserPromptSubmit"))
        _ = sessions.handle(event("PreToolUse", toolUseID: "tool-failure"))
        now.addTimeInterval(1801)
        _ = sessions.handle(event("PostToolUseFailure", toolUseID: "tool-failure"))

        XCTAssertEqual(sessions.all[sessionID]?.outstandingTools, [])
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

    private func event(_ name: String, toolUseID: String? = nil) -> [String: Any] {
        var event: [String: Any] = [
            "hook_event_name": name,
            "session_id": sessionID,
            "cwd": "/data00/example/project",
        ]
        event["tool_use_id"] = toolUseID
        return event
    }
}
