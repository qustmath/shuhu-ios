import SwiftUI

/// 应用级依赖装配（Android `ShufouApplication` 对应）：
/// 内层 GRDB 仓库 → 同步引擎（持内层）→ SyncAware 装饰器（UI 持有），
/// 认证钩子接 RemoteAuthRepository（401 续期），引擎观察 session 自动同步。
final class AppContainer {
    /// UI 使用的仓库（装饰器：写路径登记待推并触发防抖同步）。
    let repository: any LibraryRepository
    let auth: RemoteAuthRepository
    let sync: SyncEngine
    let adsClient: AdsClient

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
        // 广告走 authed 客户端（登录态自动带 token；匿名/失效均被服务端匿名放行）
        adsClient = AdsClient(api: AdsApi(client: authedClient))
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

    @State private var splashCreative: AdCreativeData?
    @State private var splashReady = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                if !splashReady {
                    // 开屏拉取等待态：主题底色，避免主页先闪一帧再跳开屏
                    Color(UIColor.systemBackground).ignoresSafeArea()
                } else if let splashCreative {
                    SplashAdView(creative: splashCreative, adsClient: container.adsClient) {
                        splashCreative = nil
                    }
                } else {
                    HomeView(
                        repository: container.repository,
                        auth: container.auth,
                        sync: container.sync,
                        adsClient: container.adsClient,
                    )
                    .task { container.bootstrap() }
                }
            }
            .task { await fetchSplash() }
        }
    }

    /// 冷启动拉取开屏素材（含失败/无素材）：完成即放行进主页。
    private func fetchSplash() async {
        let creatives = await container.adsClient.activeCreatives(slot: AdSlots.splash)
        splashCreative = creatives.first
        splashReady = true
    }
}
