import SwiftUI

/// 应用级依赖装配（Android `ShufouApplication` 对应）：
/// 内层 GRDB 仓库 → 同步引擎（持内层）→ SyncAware 装饰器（UI 持有），
/// 认证钩子接 RemoteAuthRepository（401 续期），引擎观察 session 自动同步。
final class AppContainer {
    /// UI 使用的仓库（装饰器：写路径登记待推并触发防抖同步）。
    let repository: any LibraryRepository
    let auth: RemoteAuthRepository
    let sync: SyncEngine

    private let inner: GRDBLibraryRepository

    init() {
        do {
            inner = try GRDBLibraryRepository.makeDefault()
        } catch {
            // 数据库打不开属不可恢复错误（磁盘/沙盒异常），启动即失败优于静默丢数据
            fatalError("数据库初始化失败: \(error)")
        }
        let baseURL = URL(string: "https://rrapi.groovy.ink")!
        let publicClient = ApiClient(baseURL: baseURL)
        let authedClient = ApiClient(baseURL: baseURL)
        auth = RemoteAuthRepository(
            publicClient: publicClient,
            memberClient: authedClient,
            tokenStore: TokenStore(),
        )
        let syncApi = SyncApi(client: authedClient)
        sync = SyncEngine(
            repository: inner,
            api: syncApi,
            apiBaseURL: baseURL.absoluteString,
            session: auth.session,
            store: SyncStore(),
        )
        repository = SyncAwareLibraryRepository(inner: inner, engine: sync)
    }

    /// 启动时恢复登录态并启动同步引擎（视图 .task 调用；engine.start 幂等）。
    func bootstrap() {
        auth.restore()
        sync.start()
    }
}

@main
struct ShuhuApp: App {
    private let container = AppContainer()

    var body: some Scene {
        WindowGroup {
            HomeView(
                repository: container.repository,
                auth: container.auth,
                sync: container.sync,
            )
            .task { container.bootstrap() }
        }
    }
}
