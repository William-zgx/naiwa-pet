import Foundation

/// 根据 Claude Code 的 hook 事件给每个会话记账，判断奶蛙该是什么状态、一轮结束时值不值得瞥你一眼。
/// 全在本地算，不调模型。
final class Sessions {
    enum Mood: Equatable { case idle, working, waiting }
    enum Tier { case none, big, huge }

    struct Waiting {
        let text: String
        let seen: Date
    }

    struct Session {
        var cwd: String
        var start: Date?                    // 这一轮开始干活的时间（用户发消息，或者第一次调工具）
        var tools = 0                       // 这一轮调了几次工具
        var waiting: [String: Waiting] = [:] // 按 tool/request ID 记在等你批准什么
        var toolStarts: [String: Date] = [:] // 还没收到完成事件的 tool_use_id → 开始时间
        var toolNames: [String: String] = [:] // 未完成工具的名称，用来归属无 ID 的权限通知
        var outstandingTools: Set<String> { Set(toolStarts.keys) }
        var latestToolUseID: String?         // 最近一次 PreToolUse 的 ID（不再用来归属权限通知）
        var stopped: (start: Date?, tools: Int, glanced: Bool)?
        var seen: Date

        mutating func finishTool(_ id: String) {
            toolStarts[id] = nil
            toolNames[id] = nil
            waiting[id] = nil
            // 已经结束的工具不能再接收无 ID 的通知，否则下一个工具开始时清不掉这条等待
            if latestToolUseID == id { latestToolUseID = nil }
        }

        mutating func clearTools() {
            toolStarts.removeAll()
            toolNames.removeAll()
            latestToolUseID = nil
        }
    }

    struct Finished {
        let tier: Tier
        let project: String
        let seconds: TimeInterval
    }

    private(set) var all: [String: Session] = [:]
    private static let unassignedRequest = ""
    /// 没收到完成事件的工具最多算它还在跑这么久。工具被杀掉或被拒绝时没有 PostToolUse，不设上限会一直显示干活/等你。
    /// 远大于 30 分钟，合法的长构建不受影响。
    static let maxToolSeconds: TimeInterval = 6 * 3600
    static let expiry: TimeInterval = 1800
    var now: () -> Date

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    var mood: Mood {
        prune()
        if all.values.contains(where: { !$0.waiting.isEmpty }) { return .waiting }
        if all.values.contains(where: { $0.start != nil }) { return .working }
        return .idle
    }

    /// 有在跑的工具时等到工具的硬上限；否则按最后事件的半小时超时。
    /// 不返回已过期的 deadline，避免主线程定时器在过去的时间反复触发。
    var nextExpiry: Date? {
        prune()
        return all.values.compactMap { s -> Date? in
            if let start = s.toolStarts.values.min() {
                return start.addingTimeInterval(Self.maxToolSeconds)
            }
            guard s.start != nil || !s.waiting.isEmpty else { return nil }
            return s.seen.addingTimeInterval(Self.expiry)
        }.min()
    }

    /// 等你的那个请求：项目名、在等什么；同一个会话也可能同时等好几个请求
    var waitingText: String? {
        let requests = all.values.flatMap { s -> [(project: String, waiting: Waiting)] in
            s.waiting.values.map { (Self.project(s.cwd), $0) }
        }
        guard let latest = requests.max(by: { $0.waiting.seen < $1.waiting.seen }) else { return nil }
        return "\(latest.project) \(latest.waiting.text)"
    }

    /// 处理一条 hook 事件；一轮结束时返回这一轮的结果
    func handle(_ e: [String: Any], now eventTime: Date? = nil) -> Finished? {
        guard let event = e["hook_event_name"] as? String, let id = e["session_id"] as? String else { return nil }
        let now = eventTime ?? now()
        var s = all[id] ?? Session(cwd: "", seen: now)
        if s.cwd.isEmpty, let cwd = e["cwd"] as? String { s.cwd = cwd }
        s.seen = now
        var finished: Finished?
        switch event {
        case "UserPromptSubmit":
            s.start = now
            s.tools = 0
            s.stopped = nil
            s.waiting.removeAll()
            s.clearTools()
        case "PreToolUse":
            if let id = Self.requestID(e) {
                // Only approvals are outstanding: a tool starting now means they were answered. A denied tool never
                // gets a PostToolUse, so release it here rather than showing "等你批准" until Stop. While any other
                // tool is still running the wait is kept, since parallel tools can legitimately wait for approval.
                if s.outstandingTools.allSatisfy({ s.waiting[$0] != nil }) {
                    for answered in s.outstandingTools { s.waiting[answered] = nil }
                    s.clearTools()
                    s.waiting[Self.unassignedRequest] = nil
                }
                s.toolStarts[id] = now
                s.toolNames[id] = e["tool_name"] as? String
                s.latestToolUseID = id
                s.waiting[id] = nil
            } else {
                // naiwa demo 和旧版事件没有 ID，保留原来的单请求演示行为
                s.waiting[Self.unassignedRequest] = nil
            }
            s.tools += 1
            if s.start == nil { s.start = now }
        case "PostToolUse", "PostToolUseFailure":
            if let id = Self.requestID(e) {
                s.finishTool(id)
            }
            // 完全没有 PreToolUse ID 的旧事件只能挂在未分配请求上
            if s.outstandingTools.isEmpty {
                s.waiting[Self.unassignedRequest] = nil
            }
            if event == "PostToolUseFailure", e["is_interrupt"] as? Bool == true,
               s.outstandingTools.isEmpty {
                s.start = nil
                s.tools = 0
                s.stopped = nil
                s.waiting.removeAll()
                s.clearTools()
            }
        case "StopFailure":
            s.start = nil
            s.tools = 0
            s.stopped = nil
            s.waiting.removeAll()
            s.clearTools()
        case "Notification":
            switch Self.notification(type: e["notification_type"] as? String, message: e["message"] as? String ?? "") {
            case .waiting(let text):
                let id = Self.requestID(e) ?? Self.owner(of: text, in: s)
                s.waiting[id] = Waiting(text: text, seen: now)
            case .answered:
                if let id = Self.requestID(e) {
                    s.waiting[id] = nil
                } else {
                    // 明确的完成/回复通知是旧版无 ID 事件唯一可靠的清除信号
                    s.waiting.removeAll()
                }
            case .ignore: break
            }
        case "Stop":
            var glanced = false
            if e["stop_hook_active"] as? Bool == true, let previous = s.stopped {
                s.start = previous.start ?? s.start
                s.tools += previous.tools
                glanced = previous.glanced
            }
            // naiwa_seconds：`naiwa demo` 用来假装这一轮跑了多久
            let seconds = e["naiwa_seconds"] as? Double ?? s.start.map { now.timeIntervalSince($0) } ?? 0
            let tier = glanced ? .none : Self.tier(seconds: seconds, tools: s.tools)
            finished = Finished(tier: tier, project: Self.project(s.cwd), seconds: seconds)
            s.stopped = (s.start, s.tools, glanced || tier != .none)
            s.start = nil
            s.tools = 0
            s.waiting.removeAll()
            s.clearTools()
        case "SessionEnd":
            all[id] = nil
            return nil
        default:
            break
        }
        all[id] = s
        return finished
    }

    /// 跑满 bigSeconds 且动过工具才算干完一个活；跑满 hugeSeconds 算超长任务。只聊了几句不算
    static func tier(seconds: TimeInterval, tools: Int) -> Tier {
        guard tools > 0, seconds >= Prefs.bigSeconds else { return .none }
        return seconds >= Prefs.hugeSeconds ? .huge : .big
    }

    static func requestID(_ e: [String: Any]) -> String? {
        for key in ["tool_use_id", "request_id"] {
            if let id = e[key] as? String, !id.isEmpty { return id }
        }
        return nil
    }

    /// Notification 的 hook 输入没有 tool_use_id（只有 message / title / notification_type）。
    /// 恰好一个工具没完成时（不管它是不是最近开始的），通知就是它的；同时有好几个时不知道是哪个：
    /// 通知里点了工具名而且只有一个没完成的工具叫这个名字就归它（名字有重复，比如并行的 Bash，就不算），
    /// 否则记在未分配请求上，等所有没完成的工具都结束才清。
    private static func owner(of text: String, in s: Session) -> String {
        if s.toolStarts.count > 1 {
            if text.hasPrefix("等你批准 "), let name = text.split(separator: " ").last {
                let named = s.toolNames.filter { s.toolStarts[$0.key] != nil && $0.value == name }.keys
                if named.count == 1, let id = named.first { return id }
            }
            return unassignedRequest
        }
        return s.toolStarts.count == 1 ? s.toolStarts.keys.first! : unassignedRequest
    }

    enum NotificationKind { case waiting(String), answered, ignore }

    /// 只有真的卡在你身上才算「等你」：要权限、MCP 弹表单问你、后台会话等你回话。
    /// Claude 说完 60 秒你没理它（idle_prompt）、登录成功之类都不算，不然做完的会话放着不管，奶蛙会一直盯着你。
    static func notification(type: String?, message: String) -> NotificationKind {
        switch type {
        case "permission_prompt":
            return .waiting(permissionText(message))
        case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
            return .waiting("等你回复")
        case "elicitation_complete", "elicitation_response":
            return .answered
        case .some:
            return .ignore
        case nil:
            // 老版本 Claude Code 没有 notification_type：只认明确提到权限的
            return message.localizedCaseInsensitiveContains("permission") ? .waiting(permissionText(message)) : .ignore
        }
    }

    /// 「Claude needs your permission to use Bash」→「等你批准 Bash」
    static func permissionText(_ message: String) -> String {
        guard let r = message.range(of: #"permission to use (\S+)"#, options: .regularExpression),
              let tool = message[r].split(separator: " ").last else { return "等你批准" }
        return "等你批准 \(tool)"
    }

    static func project(_ cwd: String) -> String {
        if cwd.isEmpty { return "Claude" }
        if cwd == FileManager.default.homeDirectoryForCurrentUser.path { return "~" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s) 秒" }
        if s < 3600 { return "\(s / 60) 分 \(s % 60) 秒" }
        return "\(s / 3600) 小时 \(s % 3600 / 60) 分"
    }

    /// 会话没收到 Stop 就没了（Claude 被杀掉之类），半小时没动静就不算它还在干活。
    /// 有 tool_use_id 还没完成的会话不是 abandoned：合法构建或测试可以超过半小时。
    /// 没完成的工具超过 maxToolSeconds 也不再算（被杀掉或被拒绝的工具），之后会话按上面的规则清理。
    private func prune() {
        let now = now()
        for (id, s) in all {
            let expired = s.toolStarts.filter { now.timeIntervalSince($0.value) >= Self.maxToolSeconds }.keys
            for tool in expired {
                all[id]?.finishTool(tool)
            }
            if !expired.isEmpty, all[id]?.toolStarts.isEmpty == true {
                all[id]?.waiting[Self.unassignedRequest] = nil
            }
        }
        for (id, s) in all where (s.start != nil || !s.waiting.isEmpty) && s.outstandingTools.isEmpty && now.timeIntervalSince(s.seen) >= Self.expiry {
            all[id]?.start = nil
            all[id]?.tools = 0
            all[id]?.stopped = nil
            all[id]?.waiting.removeAll()
            all[id]?.clearTools()
        }
    }
}
