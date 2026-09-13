import Foundation
import XCTest
@testable import Shuhu

/// URLSession 桩：按请求路径分发预置响应（同步引擎与认证栈的网络层测试用）。
final class MockURLProtocol: URLProtocol {

    private static let lock = NSLock()
    private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); defer { lock.unlock() }; _handler = newValue }
    }

    static func reset() {
        handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension URLRequest {
    /// URLSession 走 URLProtocol 时 httpBody 被转为流：统一读出请求体。
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

enum TestResponses {
    private struct TestEnvelope<T: Encodable>: Encodable {
        let code: Int
        let message: String
        let data: T
    }

    static func ok<T: Encodable>(_ data: T) -> (HTTPURLResponse, Data) {
        let payload = try! JSONEncoder().encode(TestEnvelope(code: 0, message: "", data: data))
        return response(with: payload)
    }

    static func okEmpty() -> (HTTPURLResponse, Data) {
        ok(EmptyData())
    }

    static func businessError(code: Int, message: String) -> (HTTPURLResponse, Data) {
        // 与服务端一致：业务失败同时体现为 HTTP 状态码（401/413/…）+ 中文信封 body
        let payload = try! JSONEncoder().encode(TestEnvelope<EmptyData?>(code: code, message: message, data: nil))
        let response = HTTPURLResponse(
            url: URL(string: "https://test.local")!,
            statusCode: code,
            httpVersion: nil,
            headerFields: nil,
        )!
        return (response, payload)
    }

    private static func response(with payload: Data) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: URL(string: "https://test.local")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
    }
}
