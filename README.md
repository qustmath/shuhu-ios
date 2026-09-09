# ios/ — iOS 客户端（待创建）

「书否」iOS 版：Swift + SwiftUI + SwiftData，与 Android 端实现同一份 spec（行为契约见 `.scratch/reading-record/spec.md`，见 docs/adr/0001 双端原生决策）。

## 约定

- **工程需在 macOS + Xcode 上创建**（本仓库的开发机是 Linux，无法编译/预览 SwiftUI）。
- 领域规则（当前页、每日目标、含首尾天数、轮次、统计、校验）请对照 Android 端
  `android/app/src/main/java/com/shufou/domain/` 用 **Foundation-only 的 Swift 模块**复刻，
  保证其可在 Linux Swift 工具链下被单元测试（spec: Testing Decisions）。
- 持久化用 SwiftData；封面图存文件、库内存路径；存储接缝对应 Android 的 `LibraryRepository`（协议命名保持一致：Book / ReadingRecord / Remark / Round）。
- 同步：接入 backend 时以 [shared/](../shared/) 的契约为准（见 docs/adr/0003）。
- ⚠️ 永远不要实现逾期/落后 UI（docs/adr/0002）。

## 下一步

1. 在 macOS 上 `xcodeinit` 创建工程放回本目录（建议名 `Shufou`，Bundle ID 与 Android 包名对应）。
2. 先移植 domain 层 + 单元测试（可直接对照 Android 端的测试用例清单）。
3. 再做 UI（主页 / 详情 / 表单 / 记录表单 / 设置），布局对照 `docs/resources/` 截图。
