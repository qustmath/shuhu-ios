import CoreGraphics
import XCTest
@testable import Shuhu

/// 拖动换位判定测试（对齐 Android `HomeScreen` 的拖动度量）。
///
/// 回归重点：2026-09-21「拖动排序时两本书来回交替晃动」——手指停住不动时，判定必须恒定不变。
/// 判定是 `(当前槽位, 手指位移)` 的纯函数，故本测试直接锁死这条性质。
final class HomeReorderTests: XCTestCase {

    private let bookHeight: CGFloat = 131
    private let adHeight: CGFloat = 200
    private let hysteresis: CGFloat = 12

    /// 三本书、无广告：槽位中线 65.5 / 196.5 / 327.5。
    private func mids(books: Int, ad: Bool = false) -> [CGFloat] {
        HomeReorder.slotMids(
            bookCount: books,
            bookRowHeight: bookHeight,
            adHeight: adHeight,
            hasAd: ad,
        )
    }

    private func target(
        current: Int,
        from: Int,
        books: Int,
        offsetY: CGFloat,
        ad: Bool = false,
    ) -> Int {
        HomeReorder.targetBookIndex(
            current: current,
            fromBookIndex: from,
            bookCount: books,
            mids: mids(books: books, ad: ad),
            hasAd: ad,
            offsetY: offsetY,
            hysteresis: hysteresis,
        )
    }

    // MARK: - 槽位几何

    func testSlotMidsWithoutAd() {
        XCTAssertEqual(mids(books: 3), [65.5, 196.5, 327.5])
    }

    func testSlotMidsWithAdInsertsThirdSlot() {
        // 广告插在第 3 个显示位：书 0/1 在前，其余书整体后移一个槽位
        XCTAssertEqual(mids(books: 3, ad: true), [65.5, 196.5, 362, 527.5])
    }

    func testSlotOfBookSkipsAdSlot() {
        XCTAssertEqual(HomeReorder.slotOfBook(0, bookCount: 3, hasAd: true), 0)
        XCTAssertEqual(HomeReorder.slotOfBook(1, bookCount: 3, hasAd: true), 1)
        XCTAssertEqual(HomeReorder.slotOfBook(2, bookCount: 3, hasAd: true), 3, "第 3 本书在广告之后")
        XCTAssertEqual(HomeReorder.slotOfBook(2, bookCount: 3, hasAd: false), 2)
        // 不足 2 本时广告排在最后，不占中间槽位
        XCTAssertEqual(HomeReorder.slotOfBook(0, bookCount: 1, hasAd: true), 0)
    }

    // MARK: - 换位阈值

    func testDownwardSwapNeedsHalfRowPlusHysteresis() {
        // 第一、二槽位中点 = 131；越过 131 + 12 = 143（手指位移 77.5）才换位
        XCTAssertEqual(target(current: 0, from: 0, books: 3, offsetY: 70), 0, "未到阈值不换")
        XCTAssertEqual(target(current: 0, from: 0, books: 3, offsetY: 78), 1)
        XCTAssertEqual(target(current: 0, from: 0, books: 3, offsetY: 210), 2, "一次跨两位")
        XCTAssertEqual(target(current: 0, from: 0, books: 2, offsetY: 500), 1, "到列表末尾就停住")
    }

    func testUpwardSwapSymmetric() {
        XCTAssertEqual(target(current: 2, from: 2, books: 3, offsetY: -70), 2, "未到阈值不换")
        XCTAssertEqual(target(current: 2, from: 2, books: 3, offsetY: -78), 1)
        XCTAssertEqual(target(current: 2, from: 2, books: 3, offsetY: -210), 0)
    }

    /// 这条就是「来回交替晃动」的回归测试：滞回带内结果必须跟当前槽位一致（有记忆），
    /// 于是指尖 ±1~2pt 抖动不会把同一对行来回翻转。
    func testHysteresisHoldsInsideDeadBand() {
        XCTAssertEqual(target(current: 0, from: 0, books: 3, offsetY: 70), 0)
        XCTAssertEqual(target(current: 1, from: 0, books: 3, offsetY: 70), 1, "已在下一槽位则留在原处")
        XCTAssertEqual(target(current: 0, from: 0, books: 3, offsetY: 60), 0)
        XCTAssertEqual(target(current: 1, from: 0, books: 3, offsetY: 60), 1)
        // 反向同理：换回来后要退过「中点 − 12」才继续退
        XCTAssertEqual(target(current: 1, from: 0, books: 3, offsetY: 50), 0)
        XCTAssertEqual(target(current: 2, from: 0, books: 3, offsetY: 190), 2)
        XCTAssertEqual(target(current: 2, from: 0, books: 3, offsetY: 180), 1)
    }

    /// 手指不动 ⇒ 判定不动（旧实现在这里会自激：布局一动，局部坐标系的 translation 就跟着跳）。
    func testStationaryFingerNeverFlipsOrder() {
        let frozen = target(current: 0, from: 0, books: 3, offsetY: 80)
        XCTAssertEqual(frozen, 1)
        for _ in 0..<200 {
            XCTAssertEqual(target(current: frozen, from: 0, books: 3, offsetY: 80), frozen)
        }
        // 换位后位移不被改写（旧实现每换一位就 dragOffsetY -= step，余量正好压在反向阈值上）
        XCTAssertEqual(target(current: 1, from: 0, books: 3, offsetY: 80), 1)
    }

    /// 跨广告：槽位高不同，阈值自动变成「广告高 / 2 + 书行高 / 2」= 165.5（中线 196.5 与 362 的中点）。
    func testThresholdAcrossAdUsesSlotMids() {
        XCTAssertEqual(target(current: 1, from: 1, books: 3, offsetY: 160, ad: true), 1)
        XCTAssertEqual(target(current: 1, from: 1, books: 3, offsetY: 180, ad: true), 2)
    }

    // MARK: - moved

    func testMovedDownAndUp() {
        XCTAssertEqual(HomeReorder.moved([1, 2, 3, 4], from: 0, to: 2), [2, 3, 1, 4])
        XCTAssertEqual(HomeReorder.moved([1, 2, 3, 4], from: 3, to: 1), [1, 4, 2, 3])
        XCTAssertEqual(HomeReorder.moved([1, 2, 3, 4], from: 2, to: 2), [1, 2, 3, 4])
        XCTAssertEqual(HomeReorder.moved([1, 2], from: 9, to: 0), [1, 2], "下标越界原样返回")
    }

    /// 连续换位等价于一次性移动到最终下标（拖动期每一步都从「当前顺序」移动）。
    func testSequentialMovesMatchSingleMove() {
        var order = [1, 2, 3, 4]
        let from = target(current: 0, from: 0, books: 4, offsetY: 78)
        order = HomeReorder.moved(order, from: 0, to: from)
        let next = target(current: from, from: 0, books: 4, offsetY: 210)
        order = HomeReorder.moved(order, from: from, to: next)
        XCTAssertEqual(order, HomeReorder.moved([1, 2, 3, 4], from: 0, to: next))
    }
}
