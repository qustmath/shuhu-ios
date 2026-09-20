import Foundation
import XCTest
@testable import Shuhu

/// 会员快照（AuthMember）测试：展示名优先级、会员状态口径、老版本快照兼容解码。
final class AuthMemberTests: XCTestCase {

    func testDisplayName_nicknameFirst() {
        XCTAssertEqual(
            AuthMember(id: 1, phone: "13800000001", nickname: "书虫").displayName,
            "书虫",
            "昵称优先（用户自取的名字）",
        )
        XCTAssertEqual(
            AuthMember(id: 1, phone: "13800000001", nickname: "").displayName,
            "13800000001",
            "无昵称回落手机号",
        )
        XCTAssertEqual(
            AuthMember(id: 1, phone: "", nickname: "").displayName,
            "微信用户",
            "空壳账号兜底",
        )
    }

    func testMembershipActive_matchesServerAdFreeRule() {
        // level=0：未开通
        XCTAssertFalse(AuthMember(id: 1, phone: "", nickname: "").membershipActive)
        // level>0 + 无到期时间：终身买断
        XCTAssertTrue(AuthMember(id: 1, phone: "", nickname: "", level: 1, expireAt: nil).membershipActive)
        // level>0 + 未来到期：生效中
        XCTAssertTrue(AuthMember(
            id: 1, phone: "", nickname: "",
            level: 1, expireAt: "2999-01-01T00:00:00+08:00",
        ).membershipActive)
        // level>0 + 已过期：失效
        XCTAssertFalse(AuthMember(
            id: 1, phone: "", nickname: "",
            level: 1, expireAt: "2000-01-01T00:00:00+08:00",
        ).membershipActive)
        // 非法时间串：保守失效
        XCTAssertFalse(AuthMember(
            id: 1, phone: "", nickname: "",
            level: 1, expireAt: "not-a-date",
        ).membershipActive)
    }

    func testMembershipLabel() {
        XCTAssertEqual(AuthMember(id: 1, phone: "", nickname: "").membershipLabel, "未开通")
        XCTAssertEqual(
            AuthMember(id: 1, phone: "", nickname: "", level: 1, expireAt: nil).membershipLabel,
            "永久会员",
        )
        XCTAssertEqual(
            AuthMember(id: 1, phone: "", nickname: "", level: 1, expireAt: "2999-09-20T12:00:00+08:00").membershipLabel,
            "有效期至 2999-09-20",
        )
    }

    func testCodable_decodesLegacySnapshotWithoutNewKeys() throws {
        // 老版本（无 avatar/level/expireAt 键）的 Keychain 快照仍可解码，登录态不丢
        let legacy = #"{"id":7,"phone":"13800000001","nickname":"旧用户"}"#.data(using: .utf8)!
        let member = try JSONDecoder().decode(AuthMember.self, from: legacy)
        XCTAssertEqual(member.id, 7)
        XCTAssertEqual(member.nickname, "旧用户")
        XCTAssertEqual(member.avatar, "")
        XCTAssertEqual(member.level, 0)
        XCTAssertNil(member.expireAt)
        XCTAssertFalse(member.membershipActive)
    }

    func testCodable_roundTripWithMembershipFields() throws {
        let original = AuthMember(
            id: 7, phone: "13800000001", nickname: "书虫",
            avatar: "/static/covers/a.jpg", level: 1, expireAt: "2999-09-20T00:00:00+08:00",
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AuthMember.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
