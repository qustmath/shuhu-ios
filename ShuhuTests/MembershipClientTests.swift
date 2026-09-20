import Foundation
import XCTest
@testable import Shuhu

/// 会员套餐客户端测试：套餐解析与价格文案、模拟支付、业务错误透传（网络层 URLProtocol 桩）。
final class MembershipClientTests: XCTestCase {

    private var client: MembershipClient!

    override func setUpWithError() throws {
        MockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let apiClient = ApiClient(baseURL: URL(string: "https://test.local")!, session: URLSession(configuration: config))
        client = MembershipClient(client: apiClient)
    }

    override func tearDown() {
        MockURLProtocol.reset()
    }

    func testPlans_parsesListAndFormatsPriceLabels() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/membership/plans")
            return TestResponses.ok(MemberPlansData(plans: [
                MemberPlanData(
                    id: 1, code: "yearly", name: "年度会员", priceCents: 6800, durationDays: 365,
                    unitLabel: "/ 年", tagLabel: "推荐", subLabel: "约 ¥5.7 / 月", sortWeight: 40,
                ),
                MemberPlanData(id: 4, code: "lifetime", name: "永久会员", priceCents: 12800, durationDays: 0, unitLabel: "/ 买断"),
                MemberPlanData(id: 3, code: "monthly", name: "月度会员", priceCents: 570, durationDays: 30, unitLabel: "/ 月"),
            ]))
        }

        let plans = try await client.plans()

        XCTAssertEqual(plans.count, 3)
        XCTAssertEqual(plans[0].priceLabel, "68", "整元不带小数点")
        XCTAssertEqual(plans[2].priceLabel, "5.70", "非整元两位小数")
        XCTAssertTrue(plans[1].isLifetime, "durationDays=0 终身买断")
        XCTAssertFalse(plans[0].isLifetime)
        XCTAssertEqual(plans[0].tagLabel, "推荐")
    }

    func testPlans_businessError_throwsServerMessage() async throws {
        MockURLProtocol.handler = { _ in
            TestResponses.businessError(code: 401, message: "登录失效，请重新登录")
        }

        do {
            _ = try await client.plans()
            XCTFail("业务错误应抛出")
        } catch let error as ApiError {
            XCTAssertEqual(error.message, "登录失效，请重新登录")
        }
    }

    func testPurchase_successReturnsMembershipState() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/membership/mock-purchase")
            return TestResponses.ok(MembershipPurchaseData(level: 1, expireAt: nil))
        }

        let data = try await client.purchase(planId: 4)

        XCTAssertEqual(data.level, 1)
        XCTAssertNil(data.expireAt, "终身买断无到期时间")
    }

    func testPurchase_planUnavailable_throwsServerMessage() async throws {
        MockURLProtocol.handler = { _ in
            TestResponses.businessError(code: 400, message: "套餐不存在或已下架")
        }

        do {
            _ = try await client.purchase(planId: 99)
            XCTFail("业务错误应抛出")
        } catch let error as ApiError {
            XCTAssertEqual(error.message, "套餐不存在或已下架")
        }
    }
}
