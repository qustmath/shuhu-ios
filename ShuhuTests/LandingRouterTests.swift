import Foundation
import XCTest
@testable import Shuhu

/// 落地路由纯函数测试：镜像 Android `LandingRouterTest` 关键分支。
final class LandingRouterTests: XCTestCase {

    func testURLOpens_httpsOnly() {
        XCTAssertEqual(
            LandingRouter.resolve(landingType: "url", landingTarget: "https://example.com"),
            .openURL("https://example.com"),
        )
        XCTAssertEqual(
            LandingRouter.resolve(landingType: "url", landingTarget: "http://example.com"),
            .noOp,
            "http 不安全，降级无操作",
        )
        XCTAssertEqual(
            LandingRouter.resolve(landingType: "url", landingTarget: "javascript:alert(1)"),
            .noOp,
        )
    }

    func testInternalRoute_membershipPurchaseIsRegistered() {
        XCTAssertEqual(
            LandingRouter.resolve(landingType: "internal", landingTarget: "membership.purchase"),
            .internalRoute("membership.purchase"),
            "会员购买页已上线，路由表已登记",
        )
    }

    func testInternalRoute_unknownTargetDegradesToNoOp() {
        XCTAssertEqual(
            LandingRouter.resolve(landingType: "internal", landingTarget: "some.future.page"),
            .noOp,
            "未登记的内部目标安全降级",
        )
    }

    func testNone_isNoOp() {
        XCTAssertEqual(
            LandingRouter.resolve(landingType: "none", landingTarget: ""),
            .noOp,
            "无操作素材：不可点击，非异常输入",
        )
    }

    func testUnknownLandingType_isNoOp() {
        XCTAssertEqual(LandingRouter.resolve(landingType: "video", landingTarget: "https://x.com"), .noOp)
    }
}
