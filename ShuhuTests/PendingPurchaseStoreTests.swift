import XCTest
@testable import Shuhu

/// 未完成支付单持久化（先单后买契约 §2.1-2/5）：落盘、按 token 找单、验证成功移除。
final class PendingPurchaseStoreTests: XCTestCase {

    private static let suiteName = "test.pendingPurchases"
    private var defaults: UserDefaults!
    private var store: PendingPurchaseStore!

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: Self.suiteName)
        defaults.removePersistentDomain(forName: Self.suiteName)
        store = PendingPurchaseStore(defaults: defaults)
    }

    private func pending(_ payNo: String, token: String) -> PendingPurchase {
        PendingPurchase(payNo: payNo, appAccountToken: token, productId: "shuhu.member.yearly", createdAt: .now)
    }

    func testSaveAndListRoundtrip() {
        store.save(pending("PAY1", token: "A1B2C3D4-0000-0000-0000-000000000001"))
        store.save(pending("PAY2", token: "A1B2C3D4-0000-0000-0000-000000000002"))

        let all = store.list()
        XCTAssertEqual(all.map(\.payNo), ["PAY1", "PAY2"])
        XCTAssertEqual(all.first?.productId, "shuhu.member.yearly")
    }

    func testSaveSamePayNoReplaces() {
        store.save(pending("PAY1", token: "A1B2C3D4-0000-0000-0000-000000000001"))
        store.save(pending("PAY1", token: "A1B2C3D4-0000-0000-0000-000000000009"))

        XCTAssertEqual(store.list().count, 1)
        XCTAssertEqual(store.list().first?.appAccountToken, "A1B2C3D4-0000-0000-0000-000000000009")
    }

    func testPendingByTokenCaseInsensitive() {
        store.save(pending("PAY1", token: "A1B2C3D4-0000-0000-0000-000000000001"))

        // StoreKit 回传的 UUID 字符串大小写可能不同
        let found = store.pending(appAccountToken: "a1b2c3d4-0000-0000-0000-000000000001")
        XCTAssertEqual(found?.payNo, "PAY1")
        XCTAssertNil(store.pending(appAccountToken: "A1B2C3D4-0000-0000-0000-00000000000F"))
    }

    func testRemoveByPayNo() {
        store.save(pending("PAY1", token: "A1B2C3D4-0000-0000-0000-000000000001"))
        store.save(pending("PAY2", token: "A1B2C3D4-0000-0000-0000-000000000002"))

        store.remove(payNo: "PAY1")

        XCTAssertEqual(store.list().map(\.payNo), ["PAY2"])
        store.remove(payNo: "PAY2")
        XCTAssertTrue(store.list().isEmpty)
    }

    func testEmptyListOnFreshInstall() {
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertNil(store.pending(appAccountToken: "anything"))
    }
}
