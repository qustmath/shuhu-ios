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

    // ---- 真实支付（pay 模块，先单后买）----

    func testCreateOrder_postsAppleChannelAndParsesToken() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/membership/purchase")
            let body = try XCTUnwrap(request.bodyData)
            let req = try JSONDecoder().decode(CreateOrderRequest.self, from: body)
            XCTAssertEqual(req.channel, "apple_iap", "iOS 固定苹果内购渠道")
            XCTAssertEqual(req.planId, 4)
            return TestResponses.ok(MembershipOrderData(
                payNo: "PAY1", channel: "apple_iap", status: "created", amount: 12800,
                invoke: nil, appAccountToken: "A1B2C3D4-0000-0000-0000-000000000001",
                productId: "shuhu.member.lifetime",
            ))
        }

        let order = try await client.createOrder(planId: 4)

        XCTAssertEqual(order.payNo, "PAY1")
        XCTAssertEqual(order.appAccountToken, "A1B2C3D4-0000-0000-0000-000000000001")
        XCTAssertEqual(order.productId, "shuhu.member.lifetime")
        XCTAssertEqual(order.amount, 12800)
    }

    func testVerify_postsTransactionIdAndReturnsStatus() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/mods/pay/apple/verify")
            let body = try XCTUnwrap(request.bodyData)
            let req = try JSONDecoder().decode(AppleVerifyRequest.self, from: body)
            XCTAssertEqual(req.payNo, "PAY1")
            XCTAssertEqual(req.transactionId, "2000000012345678")
            XCTAssertNil(req.jws, "推荐传交易号而非 JWS")
            return TestResponses.ok(AppleVerifyData(payNo: "PAY1", status: "success"))
        }

        let status = try await client.verify(payNo: "PAY1", transactionId: "2000000012345678")

        XCTAssertEqual(status, "success")
    }

    func testVerify_transactionNotFound_throwsServerMessage() async throws {
        MockURLProtocol.handler = { _ in
            TestResponses.businessError(code: 404, message: "交易不存在，请确认购买后重试")
        }

        do {
            _ = try await client.verify(payNo: "PAY1", transactionId: "2000000012345678")
            XCTFail("业务错误应抛出")
        } catch let error as ApiError {
            XCTAssertEqual(error.message, "交易不存在，请确认购买后重试")
        }
    }

    func testRestore_parsesTransactionsAndManualReview() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/mods/pay/apple/restore")
            let body = try XCTUnwrap(request.bodyData)
            let req = try JSONDecoder().decode(AppleRestoreRequest.self, from: body)
            XCTAssertEqual(req.appAccountToken, "A1B2C3D4-0000-0000-0000-000000000001")
            XCTAssertNil(req.originalTransactionId)
            return TestResponses.ok(AppleRestoreData(
                transactions: [
                    RestoreTransactionData(
                        payNo: "PAY1", status: "success", productId: "shuhu.member.lifetime",
                        amount: 12800, currency: "CNY", transactionId: "2000000012345678", paidAt: "2026-10-24T12:00:00Z",
                    ),
                    RestoreTransactionData(
                        payNo: "PAY2", status: "refunded", productId: "shuhu.member.yearly",
                        amount: 6800, currency: "CNY", transactionId: "2000000012345679", paidAt: nil,
                    ),
                ],
                needsManualReview: nil,
            ))
        }

        let data = try await client.restore(appAccountToken: "A1B2C3D4-0000-0000-0000-000000000001")

        XCTAssertEqual(data.transactions?.count, 2)
        XCTAssertEqual(data.transactions?.first?.status, "success")
        XCTAssertEqual(data.transactions?.last?.status, "refunded", "refunded 单不得重新发放")
        XCTAssertNil(data.needsManualReview)
    }

    func testRestore_needsManualReviewWhenUnmatched() async throws {
        MockURLProtocol.handler = { _ in
            TestResponses.ok(AppleRestoreData(transactions: nil, needsManualReview: true))
        }

        let data = try await client.restore(appAccountToken: "A1B2C3D4-0000-0000-0000-000000000001")

        XCTAssertEqual(data.needsManualReview, true, "归属不匹配时服务端只回人工核验标记")
        XCTAssertNil(data.transactions, "不泄露任何交易字段")
    }
}
