import Foundation

/// 接入 Claude Code：在 ~/.claude/settings.json 的 hooks 里，给下面几个事件各加一条 `naiwa hook`。
/// 奶蛙拿到事件自己记账：谁在干活、谁在等你批准、一轮跑了多久、动没动工具。
///
/// 只在原文里插入文本，不整体重写，免得把用户的格式和键顺序打乱；
/// 写之前解析新旧两份，确认除了这几条以外完全一样才落盘，并留一份备份。
enum Hooks {
    static let events: [(name: String, matcher: Bool)] = [
        ("UserPromptSubmit", false), ("PreToolUse", true), ("PostToolUse", true),
        ("Notification", false), ("Stop", false), ("SessionEnd", false),
    ]

    static func main(_ args: [String]) {
        do {
            switch args.first {
            case "install": try install()
            case "uninstall": try uninstall()
            default: printSnippets()
            }
        } catch {
            FileHandle.standardError.write(Data("naiwa: \(error)\n".utf8))
            exit(1)
        }
    }

    static var settings: URL {
        if let path = ProcessInfo.processInfo.environment["NAIWA_CLAUDE_SETTINGS"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// PATH 上的 naiwa，找不到就用当前可执行文件的绝对路径
    static var binary: String {
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("naiwa").path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        return path.contains(" ") ? "'\(path)'" : path
    }

    static var command: String { "\(binary) hook" }

    static func entry(matcher: Bool) -> String {
        let cmd = String(data: try! JSONSerialization.data(withJSONObject: [command], options: [.withoutEscapingSlashes]), encoding: .utf8)!
            .dropFirst().dropLast()
        let hooks = #""hooks": [{"type": "command", "command": \#(cmd)}]"#
        return matcher ? #"{"matcher": "*", \#(hooks)}"# : "{\(hooks)}"
    }

    /// 我们插进去的条目（含旧版只在 Stop 里放的 `naiwa laugh`），后面紧跟的逗号一起去掉。
    /// 路径带空格时 `binary` 会加单引号（`'/…/My Apps/naiwa' hook`），所以 `naiwa` 后面可以跟一个 `'`
    static let ours = #"\{("matcher": "\*", )?"hooks": \[\{"type": "command", "command": "[^"]*naiwa'? (hook|laugh)"\}\]\},?"#

    static func install() throws {
        let fm = FileManager.default
        let original = (try? String(contentsOf: settings, encoding: .utf8)) ?? "{}\n"
        // 先去掉旧的（包括旧版的 `naiwa laugh`），再整套重新装
        let text = original.replacingOccurrences(of: ours, with: "", options: .regularExpression)
        let old = try parse(text)
        guard !containsOurs(old) else {
            throw Failure("settings.json 被重新排版过，找不到原样的旧条目。请先手动删掉 hooks 里含 `naiwa` 的条目再装")
        }
        var new = text
        var expectedHooks = old["hooks"] as? [String: Any] ?? [:]
        for e in events {
            guard let next = insert(entry(matcher: e.matcher), event: e.name, into: new) else {
                throw Failure("没找到能插入的位置，请手动加，见 `naiwa hooks`")
            }
            new = next
            expectedHooks[e.name] = [try parse(entry(matcher: e.matcher))] + (expectedHooks[e.name] as? [Any] ?? [])
        }
        var expected = old
        expected["hooks"] = expectedHooks
        guard NSDictionary(dictionary: try parse(new)).isEqual(to: expected) else {
            throw Failure("插入后内容和预期不一致，没有写入。请手动加，见 `naiwa hooks`")
        }
        if new == original {
            print("已经接入过了：\(settings.path)")
            return
        }
        try fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: settings.path) {
            let backup = settings.path + ".bak-naiwa"
            try? fm.removeItem(atPath: backup)
            try fm.copyItem(atPath: settings.path, toPath: backup)
        }
        try new.write(to: settings, atomically: true, encoding: .utf8)
        print("""
        已接入 Claude Code：\(settings.path)
          \(events.map(\.name).joined(separator: "、")) 各加了一条 `\(command)`（原文件备份在 .bak-naiwa）
          新开的 Claude Code 会话生效；已经开着的要重开
        """)
    }

    static func uninstall() throws {
        let text = try String(contentsOf: settings, encoding: .utf8)
        guard containsOurs(try parse(text)) else {
            print("没有接入过")
            return
        }
        var new = text.replacingOccurrences(of: ours, with: "", options: .regularExpression)
        // 撤掉后剩下的空数组一起去掉（多是安装时新建的；空数组和没有这个键效果一样）
        for e in events {
            new = new.replacingOccurrences(of: #""\#(e.name)": \[\],?"#, with: "", options: .regularExpression)
        }
        guard let parsed = try? parse(new), !containsOurs(parsed) else {
            throw Failure("settings.json 被重新排版过，找不到原样那几段。请手动删掉 hooks 里含 `naiwa` 的条目")
        }
        try new.write(to: settings, atomically: true, encoding: .utf8)
        print("已撤掉：\(settings.path)")
    }

    /// 在 hooks.<event> 数组开头插入；没有这个事件就在 hooks 里加；没有 hooks 就在最外层加
    static func insert(_ entry: String, event: String, into text: String) -> String? {
        func sep(after i: String.Index, close: Character) -> String {
            text[i...].first { !$0.isWhitespace } == close ? "" : ","
        }
        if let hooks = text.range(of: #""hooks"\s*:\s*\{"#, options: .regularExpression) {
            if let list = text.range(of: #""\#(event)"\s*:\s*\["#, options: .regularExpression, range: hooks.upperBound..<text.endIndex) {
                return text.replacingCharacters(in: list.upperBound..<list.upperBound, with: entry + sep(after: list.upperBound, close: "]"))
            }
            return text.replacingCharacters(in: hooks.upperBound..<hooks.upperBound,
                                            with: #""\#(event)": ["# + entry + "]" + sep(after: hooks.upperBound, close: "}"))
        }
        guard let brace = text.firstIndex(of: "{") else { return nil }
        let at = text.index(after: brace)
        return text.replacingCharacters(in: at..<at, with: #""hooks": {"\#(event)": ["# + entry + "]}" + sep(after: at, close: "}"))
    }

    static func containsOurs(_ settings: [String: Any]) -> Bool {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        return hooks.values.contains { groups in
            (groups as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains {
                    guard let c = $0["command"] as? String else { return false }
                    return c.contains("naiwa") && (c.hasSuffix(" hook") || c.hasSuffix(" laugh"))
                }
            }
        }
    }

    static func parse(_ text: String) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw Failure("settings.json 不是一个 JSON 对象")
        }
        return obj
    }

    static func printSnippets() {
        let lines = events.map { "    \"\($0.name)\": [ \(entry(matcher: $0.matcher)) ]" }.joined(separator: ",\n")
        print("""
        Claude Code（~/.claude/settings.json，或者直接 `naiwa hooks install`）：
          "hooks": {
        \(lines)
          }

        Codex（~/.codex/config.toml 最上面，[xxx] 表之前；已经有 notify 的话只能留一个）：
          notify = ["\(binary.replacingOccurrences(of: "'", with: ""))", "glance"]

        其他任何命令行：长任务后面接一句
          make build; naiwa glance
        """)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ s: String) { description = s }
    }
}
