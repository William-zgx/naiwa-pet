import Foundation
import Testing
@testable import naiwa

/// 从 PATH 上跑时 argv[0] 只是个 naiwa：要找到真正的自己，不能按当前目录去解析
@Test func executableIgnoresBareArgv0() {
    let exe = CLI.executable(argv0: "naiwa")
    #expect(exe.path.hasPrefix("/"))
    #expect(exe.path != URL(fileURLWithPath: "naiwa").path)
    #expect(FileManager.default.isExecutableFile(atPath: exe.path))
    #expect(exe == exe.resolvingSymlinksInPath())
}
