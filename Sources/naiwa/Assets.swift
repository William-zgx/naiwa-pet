import AppKit
import AVFoundation

/// 素材目录：
///   assets.json  {"fps": 24,
///                 "pets": ["sleep", "listen", …],
///                 "clips": {"listen": {"video": "listen.mov", "frames": 96, "loop": true, "title": "听歌", "desc": "…"}, …},
///                 "idle": [{"from": 12, "pets": ["listen", "relax"]}, …],
///                 "work": "immerse", "look": "look", "done": "glance"}
///   *.mov        带透明通道的 HEVC（预乘透明度）
///   pets         有哪几只（菜单里的顺序）；循环的那些空闲、干活都能用
///   idle / work  默认的安排，用户可以在 ~/.config/naiwa/config.json 里换（见 Schedule）
///   look / done  等你（播完停在最后一帧）/ 做完（惊鸿一瞥）
struct Assets {
    struct Clip {
        let video: URL
        let frames: Int
        let loop: Bool
        let title: String
        let desc: String
    }

    let fps: Double
    let clips: [String: Clip]
    let pets: [String]
    let defaults: Schedule
    let look: String, done: String

    /// 能拿来空闲、干活的（循环的）那几只
    var loopPets: [String] { pets.filter { clips[$0]?.loop == true } }

    func title(_ name: String) -> String { clips[name]?.title ?? name }

    static func load() -> Assets? {
        for dir in candidates() {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("assets.json")),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = j["clips"] as? [String: [String: Any]] else { continue }
            var clips: [String: Clip] = [:]
            for (name, c) in list {
                guard let video = c["video"] as? String else { continue }
                clips[name] = Clip(video: dir.appendingPathComponent(video), frames: c["frames"] as? Int ?? 0, loop: c["loop"] as? Bool ?? false,
                                   title: c["title"] as? String ?? name, desc: c["desc"] as? String ?? "")
            }
            let pets = (j["pets"] as? [String] ?? clips.keys.sorted()).filter { clips[$0] != nil }
            let defaults = Schedule(json: j, known: Set(clips.keys))
            let look = j["look"] as? String ?? "", done = j["done"] as? String ?? ""
            guard let defaults, clips[done] != nil else { continue }
            return Assets(fps: j["fps"] as? Double ?? 24, clips: clips, pets: pets, defaults: defaults, look: look, done: done)
        }
        return nil
    }

    /// NAIWA_ASSETS → Naiwa.app/Contents/Resources/assets → 可执行文件旁边的 ../Resources/assets → 往上找仓库里的 assets/
    private static func candidates() -> [URL] {
        var out: [URL] = []
        if let env = ProcessInfo.processInfo.environment["NAIWA_ASSETS"] {
            out.append(URL(fileURLWithPath: env))
        }
        if let res = Bundle.main.resourceURL {
            out.append(res.appendingPathComponent("assets"))
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        // 经过 ~/.local/bin/naiwa 软链跑的时候 Bundle.main 认不出 App，按可执行文件的位置找 Contents/Resources/assets
        out.append(dir.deletingLastPathComponent().appendingPathComponent("Resources/assets"))
        for _ in 0..<5 {
            out.append(dir.appendingPathComponent("assets"))
            dir.deleteLastPathComponent()
        }
        return out
    }
}

/// 一段片段的播放器：系统硬件解码视频，播放时按帧取出像素缓冲。
/// 缓冲是 IOSurface 做底的，直接交给图层显示，不复制、不上传（复制成 CGImage 再贴，空闲循环要多占 8% 左右的 CPU）。
final class ClipPlayer {
    let duration: Double
    private let item: AVPlayerItem
    private let player: AVPlayer
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ])
    private var onEnd: (() -> Void)?
    private var playbackGeneration: UInt64 = 0
    private var endObserver: NSObjectProtocol?

    init(_ clip: Assets.Clip, fps: Double) {
        duration = Double(clip.frames) / fps
        item = AVPlayerItem(url: clip.video)
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            let done = self?.onEnd
            self?.onEnd = nil
            done?()
        }
    }

    deinit {
        player.pause()
        endObserver.map(NotificationCenter.default.removeObserver)
    }

    func play(onEnd: @escaping () -> Void) {
        playbackGeneration &+= 1
        let generation = playbackGeneration
        self.onEnd = onEnd
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            // Seek completions can arrive after stop or another play. Serialize the check with those main-queue calls.
            DispatchQueue.main.async { [weak self] in
                guard finished, let self, self.playbackGeneration == generation else { return }
                self.player.play()
            }
        }
    }

    func stop() {
        playbackGeneration &+= 1
        onEnd = nil
        player.pause()
    }

    /// 当前该显示的新帧（BGRA、预乘透明度、IOSurface 做底）；没有新帧返回 nil
    func nextFrame() -> CVPixelBuffer? {
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: t) else { return nil }
        return output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil)
    }
}
