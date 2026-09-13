import Foundation
import XCTest
@testable import Shuhu

/// 广告客户端测试：拉取失败/空素材返回空列表（不阻塞 UI）；active 解码 creatives。
final class AdsClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
    }

    private func client() -> AdsClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let api = AdsApi(
            client: ApiClient(baseURL: URL(string: "https://test.local")!, session: URLSession(configuration: config)),
        )
        return AdsClient(api: api)
    }

    func testActiveCreatives_decodesCreatives() async {
        let creative = AdCreativeData(
            id: 1, title: "活动", imageUrl: "https://cdn.example.com/a.jpg",
            landingType: "url", landingTarget: "https://example.com", sortWeight: 0,
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/ads/active")
            XCTAssertEqual(request.url?.query, "slot=splash")
            return TestResponses.ok(AdActiveData(slot: "splash", creatives: [creative]))
        }

        let creatives = await client().activeCreatives(slot: AdSlots.splash)
        XCTAssertEqual(creatives, [creative])
    }

    func testActiveCreatives_networkFailureReturnsEmpty() async {
        MockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let creatives = await client().activeCreatives(slot: AdSlots.splash)
        XCTAssertTrue(creatives.isEmpty, "任何失败返回空列表，不阻塞 UI")
    }

    func testActiveCreatives_emptySlotReturnsEmpty() async {
        MockURLProtocol.handler = { _ in
            TestResponses.ok(AdActiveData(slot: "splash", creatives: []))
        }

        let creatives = await client().activeCreatives(slot: AdSlots.homeListBottom)
        XCTAssertTrue(creatives.isEmpty, "免广告由服务端空结果驱动")
    }

    func testReportClicks_isFireAndForget() async {
        var clickBodies: [AdReportRequest] = []
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/v1/ads/clicks",
               let body = request.bodyData,
               let parsed = try? JSONDecoder().decode(AdReportRequest.self, from: body) {
                clickBodies.append(parsed)
            }
            return TestResponses.okEmpty()
        }

        // 上报是 fire-and-forget：调用即返回，稍后异步完成
        client().reportClicks(slot: AdSlots.splash, ids: [9])
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(clickBodies.map(\.ids), [[9]])
    }
}
