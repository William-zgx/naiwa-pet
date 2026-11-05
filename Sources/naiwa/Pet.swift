import AppKit

/// 桌面上那只奶蛙：一个透明、置顶、不抢焦点的小窗，没有声音：
///   空闲：按一天的时段换一只，在那里慢慢地动（安睡、听歌、悠闲、云幻、封闭、孤独），首尾接上一直循环；
///         鼠标在它身上停一下就换下一只（到下个时段恢复）
///   干活：沉溺奶蛙，闭着眼悬浮在水里，沉浸在活里
///   等你：沉溺奶蛙睁开眼转过来看着你，停住，头顶冒「项目 等你批准 Bash」
///   做完：惊鸿一瞥：镜头推近，它斜着瞥你一眼，头顶冒「项目 做完了 · 时长」；摸它、点它也会瞥你
/// 优先级：瞥 > 等你 > 干活 > 空闲。瞥的时候不会被打断，瞥完再回到当时该有的状态。状态之间硬切（透明的画面叠化会出重影）。
/// 窗口被挡住、屏幕睡了、锁屏就停播，不白占 CPU。
final class Pet {
    static var shared: Pet?

    let panel: PetPanel
    let view: PetView
    private let assets: Assets
    private var schedule: Schedule
    private var scheduleStamp: Date?   // config.json 的修改时间，变了就重读（手改了文件不用重启）
    private var clips: [String: ClipPlayer] = [:]
    private let sessions = Sessions()
    private let bubble = Bubble()
    private var playing: (name: String, player: ClipPlayer, start: CFTimeInterval)?
    /// 现在演的是哪段；nil = 下次 render 重新挑
    private var shown: String?
    private var idleTurn = 0
    private var reacting = false
    private var visible = true
    private var away = Pet.screenLocked()   // 屏幕睡了、锁屏了，或者切到了别的用户
    private var frameTimer: Timer?
    private var slotTimer: Timer?
    private var expiryTimer: Timer?
    private var bubbleIsWaiting = false
    /// 鼠标停在它身上换出来的那只，到下个时段（或者换了安排）就不算了
    private var picked: String?
    private var hovering = false
    private var hoverTimer: Timer?

    init(assets: Assets) {
        self.assets = assets
        schedule = Schedule.load(assets)
        scheduleStamp = Self.stamp()
        idleTurn = Int.random(in: 0..<12)
        panel = PetPanel(size: Prefs.size)
        view = PetView(frame: NSRect(x: 0, y: 0, width: Prefs.size, height: Prefs.size))
        view.pet = self
        panel.contentView = view
        // 透明的地方要让鼠标穿过去：窗口默认不接鼠标，指针移到奶蛙身上才接
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in self?.updatePassThrough() }
        let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.placeOnScreen() }
        nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in self?.updateVisibility() }
        for (n, away) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
                          (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                self?.away = away
                self?.updateVisibility()
            }
        }
        // 锁屏时窗口的遮挡状态还是「看得见」，要单独听锁屏 / 解锁
        for (n, away) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            DistributedNotificationCenter.default().addObserver(forName: .init(n), object: nil, queue: .main) { [weak self] _ in
                self?.away = away
                self?.updateVisibility()
            }
        }
    }

    func show() {
        placeOnScreen()
        panel.orderFrontRegardless()
        visible = !away   // 锁着屏启动就先别播，解锁的通知来了再播
        scheduleSlotChange()
        render()
    }

    func handle(_ msg: Link.Message, _ data: Data?) {
        switch msg {
        case .glance, .play: glance()
        case .quit: NSApp.terminate(nil)
        case .hook: hook(data)
        }
    }

    func glance() {
        hoverTimer?.invalidate()   // 点它、摸它不算「停一下」
        react(text: nil)
    }

    private func hook(_ data: Data?) {
        guard let data, let e = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let f = sessions.handle(e), f.tier != .none {
            react(text: "\(f.project) 做完了 · \(Sessions.duration(f.seconds))")
        }
        render()
        scheduleExpiry()
    }

    /// 一轮被打断（Esc）时 Claude Code 不发 Stop，之后也可能再没有事件：到最早那个会话过期时重画一次，回到该有的状态
    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let at = sessions.nextExpiry else { return }
        let t = Timer(fire: at.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.render()
            self.scheduleExpiry()
        }
        RunLoop.main.add(t, forMode: .common)
        expiryTimer = t
    }

    // MARK: 状态

    private func react(text: String?) {
        guard clip(assets.done) != nil else { return }
        if reacting {
            // 正在瞥就不打断，快瞥完了再来一次就从头来
            guard let p = playing, CACurrentMediaTime() - p.start >= p.player.duration * 0.8 else { return }
        }
        reacting = true
        if let text, let c = clip(assets.done) {
            bubbleIsWaiting = false
            bubble.show(text, above: panel.frame, for: c.duration + 1.5)
        }
        shown = assets.done
        play(assets.done) { [weak self] in
            guard let self else { return }
            self.reacting = false
            self.shown = nil
            self.render()
        }
    }

    /// 按当前状态摆好奶蛙。正在瞥就等瞥完（瞥完会再调一次）
    private func render() {
        reloadIfEdited()
        if reacting { return }
        let mood = sessions.mood
        if mood == .waiting, let t = sessions.waitingText, bubble.text != t || !bubbleIsWaiting {
            bubbleIsWaiting = true
            bubble.show(t, above: panel.frame)
        } else if mood != .waiting, bubbleIsWaiting {
            bubbleIsWaiting = false
            bubble.hide()
        }
        var want = mood == .waiting ? assets.look : mood == .working ? schedule.work : idleClip()
        if clip(want) == nil { want = idleClip() }
        guard want != shown, visible || want == assets.look else { return }
        shown = want
        let loop = assets.clips[want]?.loop ?? false
        play(want, loop: loop)   // 不循环的（等你）播完停在最后一帧：一直看着你
    }

    /// 这个时段该出来的那只。鼠标换过就是换出来的那只；已经在演这个时段的某一只就不换；同一时段有几只，每回到空闲换下一只
    private func idleClip() -> String {
        if let p = picked, assets.clips[p] != nil { return p }
        let names = schedule.slot().pets
        if let s = shown, names.contains(s) { return s }
        idleTurn += 1
        return names[idleTurn % names.count]
    }

    // MARK: 片段

    private func clip(_ name: String) -> ClipPlayer? {
        if let c = clips[name] { return c }
        guard let c = assets.clips[name] else { return nil }
        clips[name] = ClipPlayer(c, fps: assets.fps)
        return clips[name]
    }

    private func play(_ name: String, loop: Bool = false, then: (() -> Void)? = nil) {
        guard let c = clip(name) else { then?(); return }
        playing?.player.stop()
        playing = (name, c, CACurrentMediaTime())
        // 播放器只留现在这只和干活 / 等你 / 做完要用的，别的放掉（每个都占着解码器和缓冲）
        let keep: Set = [name, schedule.work, assets.look, assets.done]
        clips = clips.filter { keep.contains($0.key) }
        if frameTimer == nil {
            let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                if let img = self?.playing?.player.nextFrame() { self?.view.show(img) }
            }
            RunLoop.main.add(t, forMode: .common)
            frameTimer = t
        }
        c.play { [weak self] in
            guard let self, self.playing?.player === c else { return }
            if loop { return self.play(name, loop: true) }
            self.stopPlaying()
            then?()
        }
    }

    private func stopPlaying() {
        playing?.player.stop()
        playing = nil
        frameTimer?.invalidate()
        frameTimer = nil
    }

    private static func screenLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// 被别的窗口挡住、屏幕睡了、锁屏、切走用户：停掉循环；回来再接着演
    private func updateVisibility() {
        let now = panel.occlusionState.contains(.visible) && !away
        guard now != visible else { return }
        visible = now
        if !visible, !reacting, let s = shown, assets.clips[s]?.loop == true {
            stopPlaying()
            shown = nil
        }
        if visible { render() }
    }

    /// 到点换下一个时段的奶蛙（正在干活、等你、瞥的时候不动，回到空闲时自然换）
    private func scheduleSlotChange() {
        slotTimer?.invalidate()
        guard let at = schedule.nextChange() else { return }
        let t = Timer(fire: at.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.picked = nil
            self.render()
            self.scheduleSlotChange()
        }
        RunLoop.main.add(t, forMode: .common)
        slotTimer = t
    }

    // MARK: 安排（哪个时段出来哪几只、干活时是哪只）

    private static func stamp() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Schedule.file.path))?[.modificationDate] as? Date
    }

    private func reloadIfEdited() {
        let now = Self.stamp()
        guard now != scheduleStamp else { return }
        scheduleStamp = now
        use(Schedule.load(assets))
    }

    /// 换一套安排：正在演的空闲 / 干活那只要是被换掉了，回到当时该有的那只
    private func use(_ s: Schedule) {
        guard s != schedule else { return }
        schedule = s
        picked = nil
        if let cur = shown, cur != assets.look, cur != assets.done, !reacting {
            stopPlaying()
            shown = nil
        }
        scheduleSlotChange()
        render()
    }

    private func change(_ edit: (inout Schedule) -> Void) {
        var s = schedule
        edit(&s)
        try? s.save()
        scheduleStamp = Self.stamp()
        use(s)
    }

    private func scheduleMenu() -> [NSMenuItem] {
        let idle = NSMenu()
        let now = schedule.slot()
        for (i, slot) in schedule.idle.enumerated() {
            let to = schedule.idle[(i + 1) % schedule.idle.count].from
            let pets = NSMenu()
            for p in assets.loopPets {
                let it = item("\(assets.title(p))　\(assets.clips[p]?.desc ?? "")") { [weak self] in
                    self?.change { $0.toggle(p, inSlotFrom: slot.from) }
                }
                it.state = slot.pets.contains(p) ? .on : .off
                pets.addItem(it)
            }
            let names = slot.pets.map(assets.title).joined(separator: "、")
            let it = NSMenuItem(title: String(format: "%02d:00–%02d:00　%@%@", slot.from, to, names, slot == now ? "　← 现在" : ""),
                                action: nil, keyEquivalent: "")
            it.submenu = pets
            idle.addItem(it)
        }
        idle.addItem(.separator())
        idle.addItem(NSMenuItem(title: "同一时段勾了几只，每回到空闲轮流出来一只", action: nil, keyEquivalent: ""))
        idle.addItem(NSMenuItem(title: "鼠标在奶蛙身上停一下就换下一只，到下个时段恢复", action: nil, keyEquivalent: ""))
        idle.addItem(item("改时段的起止时间…（打开配置文件）") { [weak self] in self?.openConfig() })
        idle.addItem(item("恢复默认") { [weak self] in
            try? FileManager.default.removeItem(at: Schedule.file)
            self?.reloadIfEdited()
        })
        let idleItem = NSMenuItem(title: "空闲时", action: nil, keyEquivalent: "")
        idleItem.submenu = idle

        let work = NSMenu()
        for p in assets.loopPets {
            let it = item("\(assets.title(p))　\(assets.clips[p]?.desc ?? "")") { [weak self] in self?.change { $0.work = p } }
            it.state = schedule.work == p ? .on : .off
            work.addItem(it)
        }
        let workItem = NSMenuItem(title: "干活时：\(assets.title(schedule.work))", action: nil, keyEquivalent: "")
        workItem.submenu = work
        return [idleItem, workItem]
    }

    /// 打开 config.json 改时段；还没有就先把现在的安排写出去
    private func openConfig() {
        if !FileManager.default.fileExists(atPath: Schedule.file.path) {
            try? schedule.save()
            scheduleStamp = Self.stamp()
        }
        NSWorkspace.shared.open(Schedule.file)
    }

    // MARK: 位置和鼠标

    func updatePassThrough() {
        guard !view.dragging else { return }
        let m = NSEvent.mouseLocation
        let over = panel.frame.contains(m) && view.isOpaque(atScreen: m)
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
        // 停一下：指针进到奶蛙身上开始计时；离开整个窗口才能再来一次（换了一只以后形状变了，指针可能落在透明处，不算离开）
        if over, !hovering {
            hovering = true
            hoverTimer?.invalidate()
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in self?.pickNext() }
        } else if hovering, !panel.frame.contains(m) {
            hovering = false
            hoverTimer?.invalidate()
        }
    }

    /// 空闲时换下一只（所有能循环的轮着来），头顶报一下名字
    private func pickNext() {
        guard !reacting, !view.dragging, sessions.mood == .idle, let cur = shown else { return }
        let all = assets.loopPets
        guard let i = all.firstIndex(of: cur) ?? all.indices.first else { return }
        let next = all[(i + 1) % all.count]
        picked = next
        stopPlaying()
        shown = nil
        render()
        bubble.show(assets.title(next), above: panel.frame, for: 1.5)
    }

    func placeOnScreen() {
        let size = Prefs.size
        var origin = Prefs.origin
        if let o = origin, !NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -size / 2, dy: -size / 2).contains(NSRect(origin: o, size: CGSize(width: size, height: size))) }) {
            origin = nil  // 原来的屏幕没了
        }
        if origin == nil, let vf = NSScreen.main?.visibleFrame {
            origin = NSPoint(x: vf.maxX - size - 24, y: vf.minY)
        }
        panel.setFrame(NSRect(origin: origin ?? .zero, size: CGSize(width: size, height: size)), display: true)
    }

    func savePosition() { Prefs.origin = panel.frame.origin }

    func followBubble() { bubble.follow(panel.frame, animated: false) }

    func resize(to size: CGFloat) {
        // 脚底中点不动
        let f = panel.frame
        let origin = NSPoint(x: f.midX - size / 2, y: f.minY)
        Prefs.size = size
        Prefs.origin = origin
        panel.setFrame(NSRect(origin: origin, size: CGSize(width: size, height: size)), display: true)
        followBubble()
    }

    func menu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("瞥你一眼") { [weak self] in self?.glance() })
        let sizes = NSMenu()
        for (name, s) in [("小", 110.0), ("中", 150.0), ("大", 200.0), ("特大", 260.0)] {
            let it = item(name) { [weak self] in self?.resize(to: s) }
            it.state = abs(Prefs.size - s) < 1 ? .on : .off
            sizes.addItem(it)
        }
        let size = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        size.submenu = sizes
        m.addItem(size)
        m.addItem(.separator())
        scheduleMenu().forEach(m.addItem)
        m.addItem(.separator())
        m.addItem(item("让它走（naiwa 叫回来）") {
            Prefs.dismissed = true
            NSApp.terminate(nil)
        })
        return m
    }

    private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let it = ClosureMenuItem(title: title, action: #selector(ClosureMenuItem.fire), keyEquivalent: "")
        it.target = it
        it.closure = action
        return it
    }
}

final class ClosureMenuItem: NSMenuItem {
    var closure: (() -> Void)?
    @objc func fire() { closure?() }
}

final class PetPanel: NSPanel {
    init(size: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PetView: NSView {
    weak var pet: Pet?
    /// 正在显示的那一帧：留着它，解码器就不会把这块 IOSurface 拿去复用
    private(set) var current: CVPixelBuffer?
    private(set) var dragging = false
    private var downAt: NSPoint = .zero
    private var downOrigin: NSPoint = .zero
    private var stroke = Stroke()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ pb: CVPixelBuffer) {
        guard let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        // IOSurface 自己不带色彩空间：标成 sRGB，和编码时一致（不标的话按设备色彩解释，颜色会偏）
        if IOSurfaceCopyValue(surface, kIOSurfaceColorSpace) == nil, let srgb = CGColorSpace(name: CGColorSpace.sRGB)?.copyPropertyList() {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, srgb)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = surface
        CATransaction.commit()
        current = pb
    }

    /// 屏幕坐标这一点上奶蛙是不是实心的（透明处让鼠标穿过去）：直接读当前帧那个像素的透明度
    func isOpaque(atScreen p: NSPoint) -> Bool {
        guard let win = window, let pb = current else { return false }
        let local = convert(win.convertPoint(fromScreen: p), from: nil)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        // 画面是方的、按比例撑满视图（resizeAspect）；y 从下往上
        let x = Int(local.x / bounds.width * CGFloat(w)), y = Int((1 - local.y / bounds.height) * CGFloat(h))
        guard (0..<w).contains(x), (0..<h).contains(y) else { return false }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return false }
        let alpha = base.load(fromByteOffset: y * CVPixelBufferGetBytesPerRow(pb) + x * 4 + 3, as: UInt8.self)   // BGRA
        return alpha > 60
    }

    override func mouseMoved(with event: NSEvent) {
        pet?.updatePassThrough()
        if !(window?.ignoresMouseEvents ?? true), stroke.add(NSEvent.mouseLocation) {
            pet?.glance()
        }
    }

    override func mouseExited(with event: NSEvent) {
        stroke = Stroke()
        pet?.updatePassThrough()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        dragging = false
        downAt = NSEvent.mouseLocation
        downOrigin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        let m = NSEvent.mouseLocation
        if !dragging, hypot(m.x - downAt.x, m.y - downAt.y) < 3 { return }
        dragging = true
        window?.setFrameOrigin(NSPoint(x: downOrigin.x + m.x - downAt.x, y: downOrigin.y + m.y - downAt.y))
        pet?.followBubble()
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            dragging = false
            pet?.savePosition()
            pet?.updatePassThrough()
        } else {
            pet?.glance()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = pet?.menu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 来回摸：1.2 秒内同一个方向上折返 3 次就算摸到了
struct Stroke {
    private var last: NSPoint?
    private var dir = (x: 0, y: 0)
    private var turns: [CFTimeInterval] = []

    mutating func add(_ p: NSPoint) -> Bool {
        defer { last = p }
        guard let l = last else { return false }
        let now = CACurrentMediaTime()
        let dx = p.x - l.x, dy = p.y - l.y
        if abs(dx) >= 2 {
            let d = dx > 0 ? 1 : -1
            if dir.x != 0 && d != dir.x { turns.append(now) }
            dir.x = d
        }
        if abs(dy) >= 2 {
            let d = dy > 0 ? 1 : -1
            if dir.y != 0 && d != dir.y { turns.append(now) }
            dir.y = d
        }
        turns.removeAll { now - $0 > 1.2 }
        if turns.count >= 3 {
            turns.removeAll()
            return true
        }
        return false
    }
}


