# shuhu-ios — 书乎 iOS 客户端

「书乎」iOS 版：Swift + SwiftUI，与 Android 端实现同一份 spec（行为契约见根仓库 `.scratch/reading-record/spec.md`；双端原生决策见 docs/adr/0001）。应用名「书乎」。

## 已定参数（微信开放平台 iPhone 应用登记值，勿改）

| 参数 | 值 |
|---|---|
| Bundle ID | `ink.groovy.shuhu`（与 Android 包名一致） |
| Universal Links | `https://rrapi.groovy.ink/app/`（AASA 已上线，见根仓库 docs/deploy.md） |
| Apple Team ID | `RHXA5ZS73K`（已填入 `project.yml` 的 `DEVELOPMENT_TEAM`，AASA 已替换） |

## 工程形态（Linux 开发 + GitHub Actions 构建）

本仓库的开发机是 Ubuntu（无 macOS/Xcode），因此：

- **XcodeGen**：工程由根目录 `project.yml` 描述，`*.xcodeproj` 为生成产物不入库。任何有 macOS 的环境（本机/CI）执行 `xcodegen generate` 即可还原。
- **编译与测试全部走 GitHub Actions**（`.github/workflows/ci.yml`，macOS runner）：XcodeGen 生成工程 → `xcodebuild test` 在 iOS 模拟器跑全量单测 + UI 测试 → `xcodebuild build`（device, unsigned）冒烟。每次 push 自动执行。
- **UI 测试（`ShuhuUITests/`, XCUITest）**：手势与滚动这类只有真在模拟器上做手势才现形的行为
  （行上滑动能不能滚动列表、长按拖动换位、广告「▾」下拉）。App 侧配套一个 **Debug 专用**启动参数
  `-uiTestSeed`：清库写入演示书单并跳过开屏（`Shuhu/App/UITestSupport.swift` +
  `GRDBLibraryRepository.resetAndSeedForUITest`）。Release 构建里 `UITestSupport.isSeeded` 恒为 false，
  播种代码整段 `#if DEBUG`，发版包行为不受影响。

## 约定

- 领域层（`Shuhu/Domain/`）**只用 Foundation**，逐文件镜像 Android 端
  `android/app/src/main/java/com/shufou/domain/` 的模型与纯函数，测试用例一一对应
  （`ReadingPlanTests` 镜像 `ReadingPlanTest`、`ReadingRulesTests` 镜像 `ReadingRulesTest`）。
- 持久化用 **GRDB（SQLite）**，表结构与 Android Room **v8 最终形态同构**
  （`guid`/`updated_at`/`deleted_at` 同步三件套 + guid 唯一索引），为 ADR-0007 客户端主从同步直接铺路。
  —— 这是相对于早期占位计划（SwiftData）的决策变更，理由见 ADR-0010：同步需要真实的
  SQLite 控制（墓碑批量更新、按 guid 的 LWW upsert、索引），GRDB 的迁移器也与 Room 语义同构。
- 存储接缝对应 Android 的 `LibraryRepository`（协议命名一致：Book / ReadingRecord / Remark / Round），
  应用层持有 `SyncAwareLibraryRepository` 装饰器（写路径登记待推并防抖同步）。
- 同步：以 [shared/](../shared/) 契约为准（ADR-0007/0003）；引擎、账号切换裁决、封面自愈均镜像 Android
  `data/sync/SyncEngine.kt`（测试桩用 URLProtocol）。
- 逾期提示：计划到期后（今天 > 结束日期）今日目标与倒计时消失，改显示「超 N 天 / 差 M 页」与截止日期
  （赭红点缀色 `#9A5048`）。2026-09-21 反转了原「永不实现逾期 UI」的决策，见根仓库 `docs/adr/0002`（已修订）。

## TestFlight 发版

> **发版操作、签名架构、排障速查见 [docs/RELEASE.md](docs/RELEASE.md)（权威手册，新 session 必读）。**
> 发版唯一动作：Actions → Release (TestFlight) → Run workflow；绿了之后必须用 ASC REST 验证构建入库（手册有现成命令）。

签名走**手动模式**：分发证书 p12 与描述文件持久化在仓库 Secrets（`DIST_P12_B64`/`DIST_P12_PASSWORD`/`DIST_PROFILE_B64`），
ASC API Key Secrets（`ASC_KEY_*`/`ASC_TEAM_ID`）用于上传。构建号 = GitHub run_number 自动递增。

TestFlight 包处理完成后（10-30 分钟）：内部测试需把测试员的 Apple ID 加入
App Store Connect 用户，对方装 TestFlight App 接受邀请；外部测试需过 Beta App Review。
构建 90 天过期需重传。

## 当前状态（本地功能追平 Android + 同步全链路）

- 领域层：Book / ReadingRecord / CalendarDay / ReadingPlan / **ReadingRules（轮次与校验）** / **ReadingStats**
- 持久化：GRDB 迁移 v1（Android v8 同构）+ `GRDBLibraryRepository`
  （软删级联/排序/当前页/**封面文件存取/新记录归轮/applyRemote LWW/物理清空**）
- UI：书架（封面 + 在读/已读完分区 + 轮次标记）→ 表单（新增/编辑 + 封面相册/拍照/更换/移除）→
  详情（重读 + 分轮记录 + 记录编辑）→ 我页（统计 + 登录/注册/立即同步/换账号裁决/协议入口）
- 同步：**SyncEngine 全链路**（首登静默合并、游标分页拉取、防抖推送、401 续期、封面本地文件→服务端引用自愈、
  换账号「并入/清空」裁决）；契约 `shared/sync-api-v1.yaml`
- 测试：镜像 Android 用例 + URLProtocol 网络桩（引擎分支矩阵、401 续期重试、换账号挂起）；
  书架手势另有一层 XCUITest（`ShuhuUITests/HomeShelfUITests.swift`），配合换位判定的纯函数单测
  `HomeReorderTests`（拖动排序的「手指不动就不可能换位」这条性质写死在测试里）

## 下一步（候选票）

1. 微信登录（OpenSDK iOS，等开放平台移动应用审核；Universal Links 接缝已定）。
2. 手机号换绑/未登录重置密码（Android 已有，iOS 待镜像）。
3. 记录拖动排序、首页广告位等 Android 后续能力对齐（视产品需要）。
