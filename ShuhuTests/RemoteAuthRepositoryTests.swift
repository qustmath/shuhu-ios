import Foundation
import XCTest
import Combine
@testable import Shuhu

/// 认证栈测试：登录/注册/登出会话管理 + 401 续期重试（网络层 URLProtocol 桩）。
final class RemoteAuthRepositoryTests: XCTestCase {

    private var auth: RemoteAuthRepository!
    private var tokenStore: TokenStore!

    override func setUpWithError() throws {
        MockURLProtocol.reset()
        let tokenStore = TokenStore(service: "shufu-test-\(UUID().uuidString)")
        self.tokenStore = tokenStore
        auth = RemoteAuthRepository(
            publicClient: mockClient(),
            memberClient: mockClient(),
            tokenStore: tokenStore,
        )
    }

    override func tearDown() {
        MockURLProtocol.reset()
        tokenStore.clear()
    }

    private func mockClient() -> ApiClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return ApiClient(baseURL: URL(string: "https://test.local")!, session: URLSession(configuration: config))
    }

    private func loginData(access: String, refresh: String) -> MemberLoginData {
        MemberLoginData(
            accessToken: access,
            refreshToken: refresh,
            expiresIn: 3600,
            member: MemberProfileData(
                id: 5, username: nil, phone: "13800000001", nickname: nil,
                avatar: nil, invitationCode: nil, level: nil, expireAt: nil, createdAt: nil,
            ),
        )
    }

    // ---- 登录 ----

    func testLogin_success_savesTokensAndPublishesSession() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/member/login")
            return TestResponses.ok(self.loginData(access: "acc-1", refresh: "ref-1"))
        }

        let member = try await auth.login(phone: "13800000001", password: "secret")

        XCTAssertEqual(member.id, 5)
        XCTAssertEqual(member.phone, "13800000001")
        XCTAssertEqual(auth.session.value?.id, 5)
        XCTAssertEqual(auth.currentAccessToken(), "acc-1")
        XCTAssertEqual(tokenStore.tokens()?.refreshToken, "ref-1")
    }

    func testLogin_businessError_throwsServerMessage() async throws {
        MockURLProtocol.handler = { _ in
            TestResponses.businessError(code: 400, message: "密码错误")
        }

        do {
            _ = try await auth.login(phone: "13800000001", password: "wrong")
            XCTFail("业务错误应抛出")
        } catch let error as ApiError {
            XCTAssertEqual(error.message, "密码错误", "服务端中文提示直接展示")
            XCTAssertEqual(error.code, 400)
        }
    }

    // ---- 401 续期与重试 ----

    func testAuthenticatedRequest_401RefreshesAndRetriesOnce() async throws {
        // 先登录拿令牌
        MockURLProtocol.handler = { _ in
            TestResponses.ok(self.loginData(access: "acc-1", refresh: "ref-1"))
        }
        _ = try await auth.login(phone: "13800000001", password: "secret")

        var meCalls = 0
        MockURLProtocol.handler = { [self] request in
            switch request.url?.path {
            case "/api/v1/member/me":
                meCalls += 1
                if meCalls == 1 {
                    return TestResponses.businessError(code: 401, message: "登录失效，请重新登录")
                }
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer acc-2", "重试请求携带新令牌")
                return TestResponses.ok(MemberProfileData(
                    id: 5, username: nil, phone: "13800000001", nickname: "昵称",
                    avatar: nil, invitationCode: nil, level: nil, expireAt: nil, createdAt: nil,
                ))
            case "/api/v1/member/refresh-token":
                return TestResponses.ok(loginData(access: "acc-2", refresh: "ref-2"))
            default:
                return TestResponses.okEmpty()
            }
        }

        let profile = try await auth.refreshProfile()

        XCTAssertEqual(profile.nickname, "昵称")
        XCTAssertEqual(meCalls, 2, "401 后续期一次并重试一次")
        XCTAssertEqual(auth.currentAccessToken(), "acc-2", "refresh 旋转：新令牌已生效")
        XCTAssertEqual(tokenStore.tokens()?.refreshToken, "ref-2")
    }

    func testRefreshRejection_clearsSessionQuietly() async throws {
        MockURLProtocol.handler = { _ in
            TestResponses.ok(self.loginData(access: "acc-1", refresh: "ref-1"))
        }
        _ = try await auth.login(phone: "13800000001", password: "secret")

        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/v1/member/me":
                return TestResponses.businessError(code: 401, message: "登录失效，请重新登录")
            case "/api/v1/member/refresh-token":
                return TestResponses.businessError(code: 400, message: "登录已过期")
            default:
                return TestResponses.okEmpty()
            }
        }

        do {
            _ = try await auth.refreshProfile()
            XCTFail("refresh 也失效应抛出")
        } catch {
            // 预期路径
        }
        XCTAssertNil(auth.session.value, "refresh 被拒 → 安静回到未登录")
        XCTAssertNil(tokenStore.tokens(), "本地令牌一并清空")
    }

    // ---- 登出 ----

    func testLogout_revokesAndClearsSession() async throws {
        MockURLProtocol.handler = { _ in
            TestResponses.ok(self.loginData(access: "acc-1", refresh: "ref-1"))
        }
        _ = try await auth.login(phone: "13800000001", password: "secret")

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/member/logout")
            return TestResponses.okEmpty()
        }
        await auth.logout()

        XCTAssertNil(auth.session.value)
        XCTAssertNil(auth.currentAccessToken())
        XCTAssertNil(tokenStore.tokens())
    }
}
