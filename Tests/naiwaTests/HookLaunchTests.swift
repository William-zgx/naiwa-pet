import Foundation
import Testing
@testable import naiwa

/// 奶蛙没开着时 naiwa hook 要不要把它叫出来（CLI.shouldLaunch）
struct HookLaunchTests {
    let prompt = Data(#"{"hook_event_name":"UserPromptSubmit"}"#.utf8)

    @Test func launchesOnPromptWithAssets() {
        #expect(CLI.shouldLaunch(prompt, dismissed: false, hasAssets: { true }))
    }

    /// 找不到素材：拉起来也会马上退出，不拉、不等
    @Test func skipsWithoutAssets() {
        #expect(!CLI.shouldLaunch(prompt, dismissed: false, hasAssets: { false }))
    }

    /// 别的事件、让它走过、坏 JSON：不叫，也不去找素材（快路径不多做事）
    @Test func otherCasesSkipWithoutLoadingAssets() {
        var looked = false
        let has = { looked = true; return true }
        #expect(!CLI.shouldLaunch(Data(#"{"hook_event_name":"PreToolUse"}"#.utf8), dismissed: false, hasAssets: has))
        #expect(!CLI.shouldLaunch(prompt, dismissed: true, hasAssets: has))
        #expect(!CLI.shouldLaunch(Data("not json".utf8), dismissed: false, hasAssets: has))
        #expect(!looked)
    }
}
