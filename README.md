# shuhu-ios — 书乎 iOS 客户端

「书乎」iOS 版：Swift + SwiftUI，与 Android 端实现同一份 spec（行为契约见根仓库 `.scratch/reading-record/spec.md`；双端原生决策见 docs/adr/0001）。应用名「书乎」。

## 已定参数（微信开放平台 iPhone 应用登记值，勿改）

| 参数 | 值 |
|---|---|
| Bundle ID | `ink.groovy.shuhu`（与 Android 包名一致） |
| Universal Links | `https://rrapi.groovy.ink/app/`（AASA 已上线，见根仓库 docs/deploy.md） |
| Apple Team ID | **待注册** Apple Developer Program 后填入 `project.yml` 的 `DEVELOPMENT_TEAM`，并替换 AASA 占位符 |

## 工程形态（Linux 开发 + GitHub Actions 构建）

本仓库的开发机是 Ubuntu（无 macOS/Xcode），因此：

- **XcodeGen**：工程由根目录 `project.yml` 描述，`*.xcodeproj` 为生成产物不入库。任何有 macOS 的环境（本机/CI）执行 `xcodegen generate` 即可还原。
- **编译与测试全部走 GitHub Actions**（`.github/workflows/ci.yml`，macOS runner）：XcodeGen 生成工程 → `xcodebuild test` 在 iOS 模拟器跑全量单测 → `xcodebuild build`（device, unsigned）冒烟。每次 push 自动执行。

## 约定

- 领域层（`Shuhu/Domain/`）**只用 Foundation**，逐文件镜像 Android 端
  `android/app/src/main/java/com/shufou/domain/` 的模型与纯函数，测试用例一一对应
  （`ReadingPlanTests` 镜像 `ReadingPlanTest`）。
- 持久化用 **GRDB（SQLite）**，表结构与 Android Room **v8 最终形态同构**
  （`guid`/`updated_at`/`deleted_at` 同步三件套 + guid 唯一索引），为 ADR-0007 客户端主从同步直接铺路。
  —— 这是相对于早期占位计划（SwiftData）的决策变更，理由见 ADR-0010：同步需要真实的
  SQLite 控制（墓碑批量更新、按 guid 的 LWW upsert、索引），GRDB 的迁移器也与 Room 语义同构。
- 存储接缝对应 Android 的 `LibraryRepository`（协议命名一致：Book / ReadingRecord / Remark / Round）。
- 同步：接入 backend 时以 [shared/](../shared/) 的契约为准（见 docs/adr/0003）。
- ⚠️ 永远不要实现逾期/落后 UI（docs/adr/0002）。

## TestFlight 发版（签名与上传已预埋）

`ExportOptions.plist` + `.github/workflows/release.yml`（手动触发）已就绪。首次启用需要往
GitHub 仓库 Settings → Secrets and variables → Actions 配置四枚 secret：

| Secret | 取值 |
|---|---|
| `ASC_TEAM_ID` | Apple Developer Team ID（10 位，developer.apple.com/account 可查） |
| `ASC_KEY_ID` | App Store Connect API Key 的 Key ID |
| `ASC_KEY_ISSUER_ID` | 同一 Key 的 Issuer ID |
| `ASC_KEY_P8_B64` | 下载的 `AuthKey_<KeyID>.p8` 的 base64（`cat AuthKey_xxx.p8 \| base64`） |

API Key 在 App Store Connect → 用户和访问 → 集成 → App Store Connect API 生成
（角色 Admin；.p8 只能下载一次）。配齐后 Actions 页选 **Release (TestFlight) → Run workflow**：
archive（自动签名，API Key 现场管理证书/描述文件）→ 导出 IPA → altool 上传。
`CURRENT_PROJECT_VERSION` 用 CI run number 自动递增，满足 TestFlight 每包版本号递增要求。

TestFlight 包处理完成后（10-30 分钟）：内部测试需把测试员的 Apple ID 加入
App Store Connect 用户，对方装 TestFlight App 接受邀请；外部测试需过 Beta App Review。
构建 90 天过期需重传。

## 当前状态（首票：工程骨架 + 本地核心）

- 领域层：Book / ReadingRecord / CalendarDay / ReadingPlan（含每日目标、日期校验、展示文案）
- 持久化：GRDB 迁移 v1（Android v8 同构）+ `GRDBLibraryRepository`（软删级联/排序/当前页）
- UI（最小可用）：书架列表（进度 + 今日目标）→ 添加书籍（含计划与校验）→ 详情（记录时间线 + 记一笔/删记录）
- 测试：计划计算逐条镜像 Android 用例 + 仓库写语义 + CalendarDay 跨天/解析

## 下一步（候选票）

1. 封面（文件存储 + 选图）与重读（round +1）UI。
2. 同步引擎对齐 ADR-0007（游标/防抖/LWW，契约 `shared/sync-api-v1.yaml`）。
3. 微信登录（OpenSDK iOS，等开放平台审核与 Team ID；Universal Links 接缝已定）。
4. 签名与分发：注册 Apple Developer 后补 `DEVELOPMENT_TEAM`、证书/描述文件进 CI（match 或 secrets）。
