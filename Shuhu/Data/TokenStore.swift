import Foundation
import Security

/// 令牌与会员快照的本地持久化（Keychain，杀进程保持登录态）。
/// 与 Android `TokenStore` 对应（DataStore → Keychain）。
public struct TokenStore: Sendable {

    public struct Tokens: Codable, Equatable, Sendable {
        public let accessToken: String
        public let refreshToken: String

        public init(accessToken: String, refreshToken: String) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
        }
    }

    private static let tokensKey = "tokens"
    private static let memberKey = "member"

    private let service: String

    public init(service: String = "ink.groovy.shuhu.auth") {
        self.service = service
    }

    public func tokens() -> Tokens? {
        read(key: Self.tokensKey)
    }

    public func member() -> AuthMember? {
        read(key: Self.memberKey)
    }

    public func save(tokens: Tokens, member: AuthMember) {
        write(tokens, key: Self.tokensKey)
        write(member, key: Self.memberKey)
    }

    public func saveProfile(_ member: AuthMember) {
        write(member, key: Self.memberKey)
    }

    public func clear() {
        delete(key: Self.tokensKey)
        delete(key: Self.memberKey)
    }

    // ---- Keychain 通用密码存取 ----

    private func write<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private func read<T: Decodable>(key: String) -> T? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = try? JSONDecoder().decode(T.self, from: data)
        else { return nil }
        return value
    }

    private func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
