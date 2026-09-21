import XCTest

/// 书架手势 UI 测试（XCUITest，跑在模拟器上）。
///
/// 为什么要有这一层：单测能覆盖换位**判定**，但覆盖不到 SwiftUI 的**手势/滚动仲裁**——
/// 2026-09-21 用户反馈的三条里，「列表不能上下滑」「广告▾点了没反应」全是手势层问题，
/// 「拖动晃动」也是（位移被布局跳动污染）。这些只有真的在模拟器上做手势才测得出来。
///
/// App 侧配合：启动参数 `-uiTestSeed` 让 App 清库写入演示书单（Debug 专用，见
/// `Shuhu/App/UITestSupport.swift` 与 `GRDBLibraryRepository.resetAndSeedForUITest`）。
/// 演示书单标题在两边各有一份常量（UI 测试进程不能链接 App 模块），改动要同步。
final class HomeShelfUITests: XCTestCase {

    private enum Seed {
        static let readingTitles = (1...8).map { "演示书 \($0)" }
    }

    override func setUp() {
        continueAfterFailure = false
    }

    @discardableResult
    private func launchSeeded() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestSeed"]
        app.launch()
        XCTAssertTrue(row(app, 1).waitForExistence(timeout: 30), "书架没起来（播种或加载失败）")
        return app
    }

    /// 按标题定位书行：标题 Text 就在行内，取它的 frame 即可判断行序与位移。
    private func row(_ app: XCUIApplication, _ index: Int) -> XCUIElement {
        app.staticTexts[Seed.readingTitles[index - 1]]
    }

    /// 取行的 y；元素不存在（被 LazyVStack 回收）时返回 nil —— 直接读 `.frame` 会抛测试失败。
    private func minY(_ element: XCUIElement) -> CGFloat? {
        element.exists ? element.frame.minY : nil
    }

    /// 轮询等条件成立：拖动/滚动都有动画，加上松手后的落库回灌，断言必须等状态稳定。
    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }

    /// 用坐标做一次「按下即拖」：0.05s 短按远小于 0.35s 长按阈值，所以这只会滚动、不会起拖。
    private func swipe(_ element: XCUIElement, dy: CGFloat) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)))
    }

    // MARK: - 列表滚动

    /// 在书行上滑动必须能滚动整屏列表。
    ///
    /// 回归：行的拖动识别原来用 `.gesture`（后来试过 `.simultaneousGesture`，实测仍不放行），
    /// 子手势把 `ScrollView` 的 pan 抢走了，于是**只有没挂手势的广告区能滑**，书行上怎么滑都不动。
    /// 现在行上没有任何 SwiftUI 手势，长按识别器挂在 ScrollView 上且只在「原地按住」时识别。
    func testSwipeOnBookRowScrollsTheShelf() {
        let app = launchSeeded()
        let before = minY(row(app, 2))!

        swipe(row(app, 2), dy: -160)

        XCTAssertTrue(
            waitUntil { (self.minY(self.row(app, 2)) ?? .infinity) < before - 40 },
            "在书行上向上滑没有滚动列表（before=\(before)）",
        )
    }

    // MARK: - 长按拖动排序

    /// 长按拖动：把第 1 本拖到第 2 本之后，顺序必须真的变成 2、1、3…（而不是原地弹回或来回乱跳）。
    func testLongPressDragReordersBooks() {
        let app = launchSeeded()
        let first = row(app, 1)
        let second = row(app, 2)
        XCTAssertLessThan(first.frame.minY, second.frame.minY, "初始顺序应为 1、2、3…")

        // 0.8s > 0.35s 长按阈值；拖到第 2 本中心，跨过「两槽位中点 + 12pt 滞回」
        first.press(forDuration: 0.8, thenDragTo: second)

        XCTAssertTrue(
            waitUntil {
                guard let y1 = self.minY(self.row(app, 1)),
                      let y2 = self.minY(self.row(app, 2)) else { return false }
                return y1 > y2
            },
            "拖动后顺序没变",
        )
    }

    /// 长按后不动就松手（位移为 0）不能改顺序。
    ///
    /// 这条是「上下跳动 / 来回交替晃动」的机械侧防线：手指不动 ⇒ 顺序不动。
    func testLongPressWithoutMovementKeepsOrder() {
        let app = launchSeeded()
        let second = row(app, 2)
        let before = second.frame.minY

        second.press(forDuration: 1.2)
        Thread.sleep(forTimeInterval: 0.6)

        XCTAssertEqual(second.frame.minY, before, accuracy: 4, "长按不动就松手，顺序与位置都不该变")
        XCTAssertLessThan(row(app, 1).frame.minY, second.frame.minY, "第 1 本仍在第 2 本之前")
        // 起拖会取消本次触摸：长按松手不该被书行的点按接住跳进详情页
        XCTAssertTrue(row(app, 1).exists && row(app, 2).exists, "长按松手跳进了详情页")
    }

    // MARK: - 广告「广告 ▾」下拉

    /// 点右上角「广告 ▾」应展开下拉，「关闭这条广告」应把广告整条移除。
    ///
    /// 回归：原来是个 20pt 的 SwiftUI `Menu`，点击区摸不准，点偏就落到素材图上（无落地动作 → 没反应）。
    /// 素材来自线上接口，拉不到时跳过（不算失败）。
    func testInlineAdMenuClosesTheAd() throws {
        let app = launchSeeded()
        let badge = app.buttons["ad-menu-button"]
        guard badge.waitForExistence(timeout: 10) else {
            throw XCTSkip("本次没拉到广告素材（素材来自线上接口），跳过")
        }

        badge.tap()
        let close = app.buttons["ad-close-menu-item"]
        XCTAssertTrue(close.waitForExistence(timeout: 3), "点「广告 ▾」没有展开下拉")

        close.tap()
        XCTAssertTrue(waitUntil { !badge.exists }, "点了「关闭这条广告」广告还在")
    }
}
