import AppKit

/// 命令行和桌面上那只奶蛙之间的通道：一个具名 CFMessagePort。
/// 端口能连上 = 奶蛙在；同一个名字只能注册一次，顺带保证只有一只。
enum Link {
    enum Message: Int32 {
        case glance = 1   // 做完的反应（惊鸿一瞥）；旧版叫 laugh
        case quit = 2
        case hook = 3   // 数据：Claude Code hook 的输入 JSON
        case play = 4   // 兼容旧版的 naiwa play：现在都是瞥一眼
    }

    static let portName = "com.nwverse.naiwa" as CFString
    private static var handler: ((Message, Data?) -> Void)?
    private static var port: CFMessagePort?

    /// 发给正在跑的奶蛙；没有在跑就返回 false。
    static func send(_ msg: Message, data: Data? = nil) -> Bool {
        guard let remote = CFMessagePortCreateRemote(nil, portName) else { return false }
        return CFMessagePortSendRequest(remote, msg.rawValue, data as CFData?, 1, 0, nil, nil) == kCFMessagePortSuccess
    }

    /// 注册端口；名字被占了（已经有一只）返回 false。
    static func listen(handler: @escaping (Message, Data?) -> Void) -> Bool {
        self.handler = handler
        var ctx = CFMessagePortContext()
        guard let local = CFMessagePortCreateLocal(nil, portName, { _, id, data, _ in
            if let msg = Link.Message(rawValue: id) {
                // CFMessagePort 给的数据只在回调期间有效，必须当场复制一份再丢到主线程
                let payload = data.map { Data(bytes: CFDataGetBytePtr($0), count: CFDataGetLength($0)) }
                DispatchQueue.main.async { Link.handler?(msg, payload) }
            }
            return nil
        }, &ctx, nil) else { return false }
        port = local
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMessagePortCreateRunLoopSource(nil, local, 0), .commonModes)
        return true
    }
}

enum CLI {
    static func glance() {
        if Link.send(.glance) { exit(0) }
        // 用户从菜单里让它走了，就别被下一个任务又叫回来
        if Prefs.dismissed { exit(0) }
        launch(["run", "--glance"])
        exit(0)
    }

    static func play(_ clip: String) {
        exit(Link.send(.play, data: Data(clip.utf8)) ? 0 : 1)
    }

    /// 演示一遍所有状态：空闲 → 干活（沉溺）→ 等你批准 → 批准后接着干 → 干完惊鸿一瞥
    static func demo() {
        if !Link.send(.hook, data: Data("{}".utf8)) {
            launch(["run"])
            for _ in 0..<20 where !Link.send(.hook, data: Data("{}".utf8)) { usleep(100_000) }
        }
        let cwd = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("naiwa-demo").path
        func event(_ name: String, _ extra: [String: Any] = [:], wait: Double, _ note: String = "") {
            if !note.isEmpty { print(note) }
            let e = ["hook_event_name": name, "session_id": "naiwa-demo", "cwd": cwd].merging(extra) { $1 }
            _ = Link.send(.hook, data: try! JSONSerialization.data(withJSONObject: e))
            usleep(useconds_t(wait * 1_000_000))
        }
        print("空闲：这个时段的奶蛙在慢慢地动")
        usleep(3_000_000)
        event("UserPromptSubmit", wait: 0.3, "Claude 开始干活：沉溺奶蛙，闭着眼悬浮在水里")
        event("PreToolUse", wait: 6)
        event("Notification", ["message": "Claude needs your permission to use Bash", "notification_type": "permission_prompt"], wait: 6,
              "等你批准：睁开眼转过来看着你")
        event("PreToolUse", wait: 3, "批准了：接着沉进去干")
        event("Stop", ["naiwa_seconds": 125.0], wait: 6, "干完一个活（假装跑了 2 分钟）：惊鸿一瞥，瞥完回到空闲")
        event("SessionEnd", wait: 0)
    }

    /// 列出有哪几只、现在怎么安排的
    static func pets() {
        guard let assets = Assets.load() else {
            FileHandle.standardError.write(Data("naiwa: 找不到素材目录\n".utf8))
            exit(1)
        }
        let s = Schedule.load(assets)
        let mine = FileManager.default.fileExists(atPath: Schedule.file.path)
        print("有这几只奶蛙：")
        let width = (assets.pets.map(\.count).max() ?? 8) + 2
        for p in assets.pets {
            guard let c = assets.clips[p] else { continue }
            let use = c.loop ? "空闲、干活都能用" : p == assets.look ? "等你批准时" : p == assets.done ? "干完一个活时、点它时" : ""
            print("  " + p.padding(toLength: width, withPad: " ", startingAt: 0) + c.title + "：" + c.desc + "（" + use + "）")
        }
        print("\n现在的安排（" + (mine ? Schedule.file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") : "默认") + "）：")
        for (i, slot) in s.idle.enumerated() {
            let to = s.idle[(i + 1) % s.idle.count].from
            print(String(format: "  空闲 %02d:00–%02d:00  ", slot.from, to) + slot.pets.map(assets.title).joined(separator: "、"))
        }
        print("  干活时         " + assets.title(s.work))
        print("\n改法：右键奶蛙 →「空闲时」「干活时」里勾；或者改 ~/.config/naiwa/config.json（时段起点也能改，改完自动生效）。")
    }

    /// Claude Code 的 hook：把 stdin 里的事件 JSON 原样转给奶蛙，由它记账、决定反应。
    /// 必须快、不输出任何东西、永远返回 0，不能拖慢或干扰 Claude。
    static func hook() {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        if Link.send(.hook, data: data) { exit(0) }
        guard shouldLaunch(data, dismissed: Prefs.dismissed, hasAssets: { Assets.load() != nil }) else { exit(0) }
        let pid = launch(["run"])
        for _ in 0..<20 {
            usleep(100_000)
            if Link.send(.hook, data: data) { break }
            // 拉起来的那只已经退出了：别再白等
            if let pid, waitpid(pid, nil, WNOHANG) == pid { break }
        }
        exit(0)
    }

    /// 奶蛙没开着时要不要把它叫出来：只在新一轮开始时叫（让它走过就不叫），不然这一轮没有开始时间，记不了账。
    /// 拉起来的是同一个可执行文件、同一套环境：这里找不到素材，它一起来也会退出，每次提交都白等 2 秒。
    static func shouldLaunch(_ data: Data, dismissed: Bool, hasAssets: () -> Bool) -> Bool {
        guard !dismissed,
              let e = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              e["hook_event_name"] as? String == "UserPromptSubmit" else { return false }
        return hasAssets()
    }

    /// 在后台起一只奶蛙。打包成 .app 时走 open（交给 LaunchServices，跟调用方脱离关系），
    /// 开发时直接把自己拉起来，并脱离当前会话，返回它的 pid。
    @discardableResult
    static func launch(_ arguments: [String]) -> pid_t? {
        let exe = executable()
        let bundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if bundle.pathExtension == "app" {
            run("/usr/bin/open", ["-g", "-a", bundle.path, "--args"] + arguments)
            return nil
        }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        for fd: Int32 in 0...2 {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        let argv = ([exe.path] + arguments).map { strdup($0) } + [nil]
        var pid: pid_t = 0
        let ok = posix_spawn(&pid, exe.path, &actions, &attr, argv, environ) == 0
        argv.forEach { free($0) }
        return ok ? pid : nil
    }

    /// 自己的可执行文件，软链解开。不能只看 argv[0]：从 PATH 上跑时它就是个 naiwa，会按当前目录去找
    static func executable(argv0: String = CommandLine.arguments[0]) -> URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: argv0)).resolvingSymlinksInPath()
    }

    private static func run(_ path: String, _ arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        try? p.run()
        p.waitUntilExit()
    }
}

enum Prefs {
    // 在 Naiwa.app 里 standard 就是 com.nwverse.naiwa 这个域（拿自己的 bundle id 当 suite 名会返回 nil）；
    // 不在 .app 里跑（开发时、或者经过软链被找不到 bundle）时显式指定同一个域
    private static let d: UserDefaults = Bundle.main.bundleIdentifier == "com.nwverse.naiwa"
        ? .standard : UserDefaults(suiteName: "com.nwverse.naiwa")!

    static var dismissed: Bool {
        get { d.bool(forKey: "dismissed") }
        set { d.set(newValue, forKey: "dismissed") }
    }
    /// 一轮跑满这么多秒、并且动过工具，才算干完一个活（惊鸿一瞥）
    static var bigSeconds: Double { d.object(forKey: "bigSeconds") as? Double ?? 60 }
    /// 跑满这么多秒算超长任务（现在反应一样，只在气泡里报时长）
    static var hugeSeconds: Double { d.object(forKey: "hugeSeconds") as? Double ?? 600 }
    static var size: CGFloat {
        get { d.object(forKey: "size") as? CGFloat ?? 150 }
        set { d.set(newValue, forKey: "size") }
    }
    static var origin: NSPoint? {
        get {
            guard let a = d.array(forKey: "origin") as? [CGFloat], a.count == 2 else { return nil }
            return NSPoint(x: a[0], y: a[1])
        }
        set { d.set(newValue.map { [$0.x, $0.y] }, forKey: "origin") }
    }
}
