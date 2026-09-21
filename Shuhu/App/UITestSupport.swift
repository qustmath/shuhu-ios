import Foundation

/// UI 测试支持（XCUITest 通过启动参数驱动；见 `ios/ShuhuUITests/HomeShelfUITests.swift`）。
///
/// **Release 构建里 `isSeeded` 恒为 false**：发版包不含任何播种/跳过逻辑，行为与加这套测试前完全一致。
enum UITestSupport {

    /// 启动参数：清库并写入演示书单（`GRDBLibraryRepository.resetAndSeedForUITest`），
    /// 同时跳过开屏广告拉取，让书架立刻可见（UI 测试不测开屏）。
    static let seedArgument = "-uiTestSeed"

    static var isSeeded: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(seedArgument)
        #else
        return false
        #endif
    }

    #if DEBUG
    /// 演示书单标题。**UI 测试里有一份同名常量**（UI 测试进程不能链接 App 模块），改动要同步。
    enum Seed {
        static let readingTitles = (1...8).map { "演示书 \($0)" }
        static let finishedTitles = ["演示完结 1", "演示完结 2"]
    }
    #endif
}
