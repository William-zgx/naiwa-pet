import AppKit

/// 奶蛙头顶的气泡：「my-repo 做完了 · 4 分 12 秒」「my-repo 等你批准 Bash」。
/// 单独一个不接鼠标的小窗，跟着奶蛙的窗口走。
final class Bubble {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var hideTimer: Timer?
    private(set) var text: String?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 0.9).cgColor
        box.layer?.cornerRadius = 9
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        box.addSubview(label)
        panel.contentView = box
    }

    /// 显示在 petFrame 上方；seconds 为 nil 时一直显示，直到 hide()
    func show(_ text: String, above petFrame: NSRect, for seconds: Double? = nil) {
        self.text = text
        hideTimer?.invalidate()
        label.stringValue = text
        label.sizeToFit()
        let w = min(label.frame.width, 260), h = label.frame.height
        label.frame = NSRect(x: 9, y: 4, width: w, height: h)
        panel.setContentSize(NSSize(width: w + 18, height: h + 8))
        follow(petFrame, animated: false)
        panel.orderFrontRegardless()
        if let seconds {
            hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.hide() }
        }
    }

    func hide() {
        hideTimer?.invalidate()
        text = nil
        panel.orderOut(nil)
    }

    /// 奶蛙的头顶在窗口顶边附近，气泡底边压住窗口顶边一点
    func follow(_ petFrame: NSRect, animated: Bool) {
        guard text != nil else { return }
        let size = panel.frame.size
        var origin = NSPoint(x: petFrame.midX - size.width / 2, y: petFrame.maxY - 4)
        if let vf = NSScreen.screens.first(where: { $0.frame.intersects(petFrame) })?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX + 4), vf.maxX - size.width - 4)
            origin.y = min(origin.y, vf.maxY - size.height - 2)
        }
        let frame = NSRect(origin: origin, size: size)
        if animated {
            panel.animator().setFrame(frame, display: true)
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}
