import SwiftUI

@main
struct ShuhuApp: App {
    /// 本地优先（ADR-0001）：无网无账号也可完整使用；同步为后续票据。
    private let repository: GRDBLibraryRepository

    init() {
        do {
            repository = try GRDBLibraryRepository.makeDefault()
        } catch {
            // 数据库打不开属不可恢复错误（磁盘/沙盒异常），启动即失败优于静默丢数据
            fatalError("数据库初始化失败: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            HomeView(repository: repository)
        }
    }
}
