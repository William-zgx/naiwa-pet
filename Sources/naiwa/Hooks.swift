import Foundation

/// 接入 Claude Code：在 ~/.claude/settings.json 的 hooks 里，给下面几个事件各加一条 `naiwa hook`。
/// 奶蛙拿到事件自己记账：谁在干活、谁在等你批准、一轮跑了多久、动没动工具。
///
/// 只在原文里插入文本，不整体重写，免得把用户的格式和键顺序打乱；
/// 写之前解析新旧两份，确认除了这几条以外完全一样才落盘，并留一份备份。
enum Hooks {
    static let events: [(name: String, matcher: Bool)] = [
        ("UserPromptSubmit", false), ("PreToolUse", true), ("PostToolUse", true), ("PostToolUseFailure", true),
        ("Notification", false), ("Stop", false), ("StopFailure", false), ("SessionEnd", false),
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

    /// 符号链接（dotfiles）解析到目标：读、备份、写都对目标做，链接本身不动
    static var settings: URL {
        if let path = ProcessInfo.processInfo.environment["NAIWA_CLAUDE_SETTINGS"] {
            return URL(fileURLWithPath: path).resolvingSymlinksInPath()
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
            .resolvingSymlinksInPath()
    }

    /// PATH 上的 naiwa，找不到就用当前可执行文件的绝对路径（原样，不带引号）
    static var binary: String {
        ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("naiwa").path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? CLI.executable().path
    }

    /// 路径里有 shell 特殊字符就整段单引号括起来，里面的 ' 写成 '\''
    static var command: String {
        let plain = binary.allSatisfy { $0.isLetter || $0.isNumber || "/._-+@%:,=".contains($0) }
        return (plain ? binary : "'" + binary.replacingOccurrences(of: "'", with: #"'\''"#) + "'") + " hook"
    }

    /// 带引号的 JSON 字符串，TOML 的基本字符串也认
    static func quoted(_ s: String) -> String {
        String(String(data: try! JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]), encoding: .utf8)!
            .dropFirst().dropLast())
    }

    static func entry(matcher: Bool) -> String {
        let hooks = #""hooks": [{"type": "command", "command": \#(quoted(command))}]"#
        return matcher ? #"{"matcher": "*", \#(hooks)}"# : "{\(hooks)}"
    }

    /// 我们插进去的条目（含旧版只在 Stop 里放的 `naiwa laugh`；路径可能带引号）
    static let ours = separated(#"\{("matcher": "\*", )?"hooks": \[\{"type": "command", "command": "([^"\\]|\\.)*naiwa'? (hook|laugh)"\}\]\}"#)

    /// 连同分隔的逗号一起去掉：前面有逗号去前面的（它可能是最后一个），否则去后面的
    static func separated(_ pattern: String) -> String { #",\s*\#(pattern)|\#(pattern)\s*,?"# }

    static func install() throws {
        let fm = FileManager.default
        // 只有文件不存在才从空对象开始；存在但读不出来就报错，不能当成空的覆盖掉
        let original: String
        if fm.fileExists(atPath: settings.path) {
            guard let text = String(data: try Data(contentsOf: settings), encoding: .utf8) else {
                throw Failure("\(settings.path) 不是 UTF-8 编码，没有写入。请先把它存成 UTF-8 再装")
            }
            original = text
        } else {
            original = "{}\n"
        }
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
        guard NSDictionary(dictionary: try parse(new, strict: true)).isEqual(to: expected) else {
            throw Failure("插入后内容和预期不一致，没有写入。请手动加，见 `naiwa hooks`")
        }
        if new == original {
            print("已经接入过了：\(settings.path)")
            return
        }
        try fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: settings.path) {
            // 只留第一次接入前的原件：之后再装，当前文件可能已经是装过、撤过的版本
            let backup = settings.path + ".bak-naiwa"
            if !fm.fileExists(atPath: backup) {
                try fm.copyItem(atPath: settings.path, toPath: backup)
            }
        }
        try write(new)
        print("""
        已接入 Claude Code：\(settings.path)
          \(events.map(\.name).joined(separator: "、")) 各加了一条 `\(command)`（第一次接入前的原文件备份在 .bak-naiwa）
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
            new = new.replacingOccurrences(of: separated(#""\#(e.name)": \[\]"#), with: "", options: .regularExpression)
        }
        guard let parsed = try? parse(new, strict: true), !containsOurs(parsed) else {
            throw Failure("settings.json 被重新排版过，找不到原样那几段。请手动删掉 hooks 里含 `naiwa` 的条目")
        }
        try write(new)
        print("已撤掉：\(settings.path)")
    }

    /// 原子写会换成新文件（默认 0644），写完把原来的权限设回去；settings.json 里可能有 token
    static func write(_ text: String) throws {
        let fm = FileManager.default
        let permissions = try? fm.attributesOfItem(atPath: settings.path)[.posixPermissions]
        try text.write(to: settings, atomically: true, encoding: .utf8)
        if let permissions {
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: settings.path)
        }
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

    /// strict：JSONSerialization 放过 `,]` `,}` 这种多余的逗号，要落盘的内容另外查一遍
    static func parse(_ text: String, strict: Bool = false) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw Failure("settings.json 不是一个 JSON 对象")
        }
        if strict && hasTrailingComma(text) { throw Failure("settings.json 里有多余的逗号") }
        return obj
    }

    /// 跳过字符串，看 `]` `}` 前面最近的非空白字符是不是逗号
    static func hasTrailingComma(_ text: String) -> Bool {
        var inString = false, escaped = false, last: Character = " "
        for c in text {
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            if c.isWhitespace { continue }
            if (c == "]" || c == "}") && last == "," { return true }
            if c == "\"" { inString = true }
            last = c
        }
        return false
    }

    static func printSnippets() {
        let lines = events.map { "    \"\($0.name)\": [ \(entry(matcher: $0.matcher)) ]" }.joined(separator: ",\n")
        print("""
        Claude Code（~/.claude/settings.json，或者直接 `naiwa hooks install`）：
          "hooks": {
        \(lines)
          }

        Codex（~/.codex/config.toml 最上面，[xxx] 表之前；已经有 notify 的话只能留一个）：
          notify = [\(quoted(binary)), "glance"]

        其他任何命令行：长任务后面接一句
          make build; naiwa glance
        """)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ s: String) { description = s }
    }
}
