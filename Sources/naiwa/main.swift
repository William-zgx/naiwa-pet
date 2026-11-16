import AppKit

let usage = """
naiwa — 桌面上的奶蛙：空闲时按时段换一只慢慢地动，Claude 干活时沉溺在水里，\n等你批准时睁眼转过来看着你，干完一个活斜着瞥你一眼（惊鸿一瞥）。

用法：
  naiwa                 把奶蛙放到桌面上（已经在了就什么都不做）
  naiwa glance          让它瞥你一眼（旧名 naiwa laugh 也行）；没开着会自动打开（你从菜单退出过就不会）
  naiwa demo            演示一遍：空闲 → 干活 → 等你批准 → 干完惊鸿一瞥
  naiwa pets            有哪几只奶蛙、现在哪个时段出来哪几只
  naiwa quit            让它离开
  naiwa hooks install   接入 Claude Code
  naiwa hooks uninstall 撤掉接入
  naiwa hooks           打印 Claude Code / Codex 的接入配置
  naiwa hook            （给 Claude Code 的 hook 调用，从 stdin 读事件）

在奶蛙身上：点一下或来回摸几下 = 瞥你一眼；拖动 = 换位置；右键 = 菜单（大小、每个时段出来哪几只、干活时是哪只）。
一轮跑满 60 秒且动过工具才算干完：defaults write com.nwverse.naiwa bigSeconds -float 30
"""

let args = Array(CommandLine.arguments.dropFirst())

switch args.first ?? "run" {
case "run":
    runPet(glanceOnStart: args.contains("--glance") || args.contains("--laugh"))
case "glance", "laugh":
    // Codex 的 notify 会在最后追加一个 JSON 参数，这里不用它
    CLI.glance()
case "pets":
    CLI.pets()
case "quit":
    exit(Link.send(.quit) ? 0 : 1)
case "play":
    CLI.play(args.dropFirst().first ?? "glance")
case "hook":
    CLI.hook()
case "demo":
    CLI.demo()
case "hooks":
    Hooks.main(Array(args.dropFirst()))
case "-h", "--help", "help":
    print(usage)
default:
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}

func runPet(glanceOnStart: Bool) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard Link.listen(handler: { msg, data in Pet.shared?.handle(msg, data) }) else {
        // 已经有一只在桌面上了
        if glanceOnStart { _ = Link.send(.glance) }
        exit(0)
    }
    guard let assets = Assets.load() else {
        FileHandle.standardError.write(Data("naiwa: 找不到素材目录（设置 NAIWA_ASSETS 或用打包好的 Naiwa.app）\n".utf8))
        exit(1)
    }
    Prefs.dismissed = false
    Pet.shared = Pet(assets: assets)
    Pet.shared?.show()
    if glanceOnStart {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Pet.shared?.glance() }
    }
    app.run()
}
