import Foundation
import XCTest
@testable import Shuhu

/// 建议与反馈客户端测试：提交请求体形状、频控错误透传、列表解析（含官方回复/坏数据降级）、
/// 截图上传（multipart 路径与返回 URL）。网络层用 URLProtocol 桩。
final class FeedbackClientTests: XCTestCase {

    private var client: FeedbackClient!

    override func setUpWithError() throws {
        MockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let apiClient = ApiClient(baseURL: URL(string: "https://test.local")!, session: URLSession(configuration: config))
        client = FeedbackClient(client: apiClient)
    }

    override func tearDown() {
        MockURLProtocol.reset()
    }

    func testSubmit_postsBodyAndAcceptsEmptyData() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/mods/feedback")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(request.bodyData)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["type"] as? String, "bug")
            XCTAssertEqual(json["content"] as? String, "书架排序偶尔跳动")
            XCTAssertEqual(json["contact"] as? String, "a@b.com")
            XCTAssertEqual((json["images"] as? [String]) ?? [], [])
            return TestResponses.okEmpty()
        }

        try await client.submit(type: FeedbackType.bug, content: "书架排序偶尔跳动", contact: "a@b.com", images: [])
    }

    func testSubmit_rateLimited_throwsServerMessage() async throws {
        MockURLProtocol.handler = { _ in
            TestResponses.businessError(code: 429, message: "今日反馈提交已达上限")
        }

        do {
            try await client.submit(type: FeedbackType.suggestion, content: "第 6 条", contact: "", images: [])
            XCTFail("业务错误应抛出")
        } catch let error as ApiError {
            XCTAssertEqual(error.message, "今日反馈提交已达上限")
        }
    }

    func testMyList_parsesRepliedItemWithReply() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/mods/feedback")
            let query = request.url?.query ?? ""
            XCTAssertTrue(query.contains("page=1"))
            XCTAssertTrue(query.contains("pageSize=20"))
            return TestResponses.ok(FeedbackListData(list: [
                FeedbackItemData(
                    id: 2, type: "bug", content: "航NBB", contact: "", images: nil,
                    status: "replied", reply: "收到，已纳入规划", repliedAt: "2026-10-13 12:00:00",
                    createdAt: "2026-10-13 11:00:00",
                ),
                FeedbackItemData(id: 1, type: "suggestion", content: "希望支持深色模式", status: "pending"),
            ], total: 2))
        }

        let data = try await client.myList(page: 1)

        XCTAssertEqual(data.total, 2)
        let replied = try XCTUnwrap(data.list?.first { $0.status == FeedbackStatus.replied })
        XCTAssertEqual(replied.reply, "收到，已纳入规划")
        XCTAssertEqual(FeedbackStatus.label(of: replied.status), "已回复")
        XCTAssertEqual(FeedbackType.label(of: replied.type), "问题")
        XCTAssertEqual(data.list?.last?.images ?? [], [], "缺 images 字段降级为空列表")
        XCTAssertEqual(data.list?.last?.reply ?? "", "", "缺 reply 字段降级为空文案")
    }

    func testUpload_returnsUrl() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/mods/feedback/upload")
            let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="), "应为 multipart 上传")
            let body = try XCTUnwrap(request.bodyData)
            XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("name=\"file\""), "文件字段名必须为 file")
            return TestResponses.ok(FeedbackUploadData(url: "https://cdn.example.com/feedback/1.jpg"))
        }

        let url = try await client.upload(bytes: Data("fake-image".utf8), fileExtension: "jpg")

        XCTAssertEqual(url, "https://cdn.example.com/feedback/1.jpg")
    }

    func testUpload_missingUrl_throwsFallback() async throws {
        MockURLProtocol.handler = { _ in
            TestResponses.ok(FeedbackUploadData(url: ""))
        }

        do {
            _ = try await client.upload(bytes: Data("fake-image".utf8), fileExtension: "jpg")
            XCTFail("空 URL 应抛出")
        } catch let error as ApiError {
            XCTAssertEqual(error.message, "服务器错误，请稍后再试")
        }
    }
}
