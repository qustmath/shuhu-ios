import Foundation
import XCTest
import Combine
@testable import Shuhu

/// 同步引擎行为测试（ADR-0007 客户端主从）：网络层用 URLProtocol 桩，
/// 逐条镜像 Android `SyncEngineTest` 的关键分支（首同步全量上行、待推出队、
/// 拉取 LWW、游标推进、封面自愈、换账号裁决挂起）。
final class SyncEngineTests: XCTestCase {

    private var repository: GRDBLibraryRepository!
    private var coversDir: URL!
    private var store: SyncStore!
    private var session: CurrentValueSubject<AuthMember?, Never>!
    private var engine: SyncEngine!

    override func setUpWithError() throws {
        MockURLProtocol.reset()
        coversDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shuhu-sync-\(UUID().uuidString)", isDirectory: true)
        repository = GRDBLibraryRepository(writer: try Database.open(), coversDirectory: coversDir)
        store = SyncStore(defaults: UserDefaults(suiteName: "sync-tests-\(UUID().uuidString)")!)
        session = CurrentValueSubject<AuthMember?, Never>(nil)
        engine = SyncEngine(
            repository: repository,
            api: SyncApi(client: mockClient()),
            apiBaseURL: "https://test.local",
            session: session,
            store: store,
            // 防抖拉长到测试之外：写操作测试不触发自动同步，只验证队列登记
            debounceNanoseconds: 3_600_000_000_000,
        )
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: coversDir)
    }

    private func mockClient() -> ApiClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return ApiClient(baseURL: URL(string: "https://test.local")!, session: URLSession(configuration: config))
    }

    private func member(id: Int64 = 7) -> AuthMember {
        AuthMember(id: id, phone: "13800000001", nickname: "")
    }

    private func day(_ d: Int) -> CalendarDay { CalendarDay(year: 2026, month: 9, day: d) }

    // ---- 首次同步：本地全量上行 + 游标落盘 ----

    func testFirstSync_pushesAllLocalRows_pullsAndSavesCursor() async throws {
        let book = try await repository.addBook(NewBook(title: "本地书", author: "", totalPages: 100))
        let record = try await repository.addRecord(NewRecord(bookId: book.id, date: day(13), pageReached: 10))

        var pushBodies: [SyncPushRequest] = []
        MockURLProtocol.handler = { [self] request in
            switch request.url?.path {
            case "/api/v1/sync/push":
                if let body = request.bodyData,
                   let parsed = try? JSONDecoder().decode(SyncPushRequest.self, from: body) {
                    pushBodies.append(parsed)
                }
                return TestResponses.ok(SyncPushData(cursor: "c1", results: [
                    SyncPushResult(guid: book.guid, entity: "book", accepted: true, reason: nil),
                    SyncPushResult(guid: record.guid, entity: "record", accepted: true, reason: nil),
                ]))
            case "/api/v1/sync/pull":
                return TestResponses.ok(SyncPullData(cursor: "c2", hasMore: false, books: [], records: []))
            default:
                return TestResponses.okEmpty()
            }
        }

        session.send(member())
        let ok = await engine.syncNow()

        XCTAssertTrue(ok)
        XCTAssertEqual(pushBodies.count, 1)
        XCTAssertEqual(pushBodies[0].books.map(\.guid), [book.guid], "首同步（无游标）本地全量上行")
        XCTAssertEqual(pushBodies[0].records.map(\.guid), [record.guid])
        XCTAssertEqual(store.cursor(), "c2", "拉取返回的游标落盘（push 游标不采纳）")
        XCTAssertTrue(store.pendingBookGuids().isEmpty, "推送接收后出队")
        XCTAssertTrue(store.pendingRecordGuids().isEmpty)
        XCTAssertEqual(store.lastSyncAccountId(), member().id)
        XCTAssertGreaterThan(store.lastSyncAt(), 0)
    }

    // ---- 二次同步：只推待推队列，拉取按本机游标 ----

    func testSecondSync_pushesOnlyPending_andPullsWithSavedCursor() async throws {
        let book = try await repository.addBook(NewBook(title: "本地书", author: "", totalPages: 100))
        var pushBodies: [SyncPushRequest] = []
        var pullCursors: [String?] = []
        MockURLProtocol.handler = { [self] request in
            switch request.url?.path {
            case "/api/v1/sync/push":
                if let body = request.bodyData,
                   let parsed = try? JSONDecoder().decode(SyncPushRequest.self, from: body) {
                    pushBodies.append(parsed)
                }
                return TestResponses.ok(SyncPushData(cursor: "p-cursor", results: [
                    SyncPushResult(guid: book.guid, entity: "book", accepted: true, reason: nil),
                ]))
            case "/api/v1/sync/pull":
                pullCursors.append(cursorParam(of: request))
                return TestResponses.ok(SyncPullData(cursor: "pull-\(pullCursors.count)", hasMore: false, books: [], records: []))
            default:
                return TestResponses.okEmpty()
            }
        }
        session.send(member())
        _ = await engine.syncNow()

        let second = try await repository.addRecord(NewRecord(bookId: book.id, date: day(14), pageReached: 20))
        engine.markRecordsChanged([second.guid])
        _ = await engine.syncNow()

        XCTAssertEqual(pushBodies.count, 2, "第二轮无书籍待推")
        XCTAssertTrue(pushBodies[1].books.isEmpty)
        XCTAssertEqual(pushBodies[1].records.map(\.guid), [second.guid], "只推本轮登记的变更")
        XCTAssertEqual(pullCursors, [nil, "pull-1"], "拉取只按本机已应用游标推进（不用 push 游标）")
    }

    // ---- 拉取 LWW：远端较新应用、本地较新保留 ----

    func testPull_appliesRemoteNewer_keepsLocalNewer() async throws {
        let book = try await repository.addBook(NewBook(title: "本地书", author: "", totalPages: 100))
        let now = book.updatedAt
        let remoteNewer = SyncBookChange(
            guid: book.guid, title: "云端改名", author: "", totalPages: 100,
            currentRound: 1, sortOrder: 1, updatedAt: now + 60_000, deletedAt: nil,
        )
        let remoteOlder = SyncBookChange(
            guid: book.guid, title: "旧改名", author: "", totalPages: 100,
            currentRound: 1, sortOrder: 1, updatedAt: now + 30_000, deletedAt: nil,
        )
        var pullBooks: [SyncBookChange] = [remoteNewer]
        MockURLProtocol.handler = { [self] request in
            switch request.url?.path {
            case "/api/v1/sync/push":
                return TestResponses.ok(SyncPushData(cursor: "p", results: []))
            case "/api/v1/sync/pull":
                let books = pullBooks
                pullBooks = []
                return TestResponses.ok(SyncPullData(cursor: "c-\(Int.random(in: 0...1_000_000))", hasMore: false, books: books, records: []))
            default:
                return TestResponses.okEmpty()
            }
        }
        session.send(member())
        _ = await engine.syncNow()

        var local = try await repository.bookByGuid(guid: book.guid)
        XCTAssertEqual(local?.title, "云端改名", "远端严格较新 → 原样应用")
        XCTAssertEqual(local?.updatedAt, now + 60_000, "updatedAt 按远端值（LWW 依据）")

        pullBooks = [remoteOlder]
        _ = await engine.syncNow()
        local = try await repository.bookByGuid(guid: book.guid)
        XCTAssertEqual(local?.title, "云端改名", "本地较新 → 忽略远端旧行")
    }

    // ---- 换账号裁决（票 08）----

    func testStart_detectsAccountSwitch_andFetchesCloudSummary() async throws {
        store.saveLastSync(accountId: 1, atMillis: 1_000)
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/v1/sync/stats" {
                return TestResponses.ok(SyncStatsData(liveBooks: 3, liveRecords: 9))
            }
            XCTFail("换账号待裁决期间不应发生同步请求")
            return TestResponses.okEmpty()
        }
        engine.start()
        session.send(member(id: 2))

        try await waitUntil("账号切换挂起") {
            self.engine.pendingSwitchAccount.value != nil
                && self.engine.pendingSwitchCloudSummary.value != nil
        }
        XCTAssertEqual(engine.pendingSwitchAccount.value?.id, 2)
        XCTAssertEqual(engine.pendingSwitchCloudSummary.value?.liveBooks, 3, "弹窗展示云端概览（防裸删）")
    }

    func testSync_suspendedWhileAccountSwitchPending_untilResolved() async throws {
        store.saveLastSync(accountId: 1, atMillis: 1_000)
        engine.pendingSwitchAccount.send(member(id: 2)) // 挂起态（检测逻辑另测）

        var networkCalls = 0
        MockURLProtocol.handler = { _ in
            networkCalls += 1
            return TestResponses.okEmpty()
        }
        let blocked = await engine.syncNow()
        XCTAssertFalse(blocked, "账号未裁决 → 同步挂起")
        XCTAssertEqual(networkCalls, 0, "挂起期间不发生网络同步")

        // 裁决：并入 → 重置同步状态后走首登合并（本地全量上行）
        var pushedGuids: [String] = []
        let book = try await repository.addBook(NewBook(title: "本地书", author: "", totalPages: 10))
        MockURLProtocol.handler = { [self] request in
            switch request.url?.path {
            case "/api/v1/sync/push":
                if let body = request.bodyData,
                   let parsed = try? JSONDecoder().decode(SyncPushRequest.self, from: body) {
                    pushedGuids += parsed.books.map(\.guid)
                }
                return TestResponses.ok(SyncPushData(cursor: "c1", results: []))
            case "/api/v1/sync/pull":
                return TestResponses.ok(SyncPullData(cursor: "c2", hasMore: false, books: [], records: []))
            default:
                return TestResponses.okEmpty()
            }
        }
        await engine.resolveAccountSwitch(mergeIntoNewAccount: true)

        XCTAssertTrue(pushedGuids.contains(book.guid), "并入 = 本地全量上行")
        XCTAssertEqual(store.lastSyncAccountId(), 2, "裁决后按新账号记账")
        XCTAssertNil(engine.pendingSwitchAccount.value)
    }

    func testResolveSwitch_clearWipesLocalLibrary_beforeRebuildingFromCloud() async throws {
        store.saveLastSync(accountId: 1, atMillis: 1_000)
        engine.pendingSwitchAccount.send(member(id: 2))

        _ = try await repository.addBook(NewBook(title: "将被清空", author: "", totalPages: 10))
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/v1/sync/push":
                return TestResponses.ok(SyncPushData(cursor: "c1", results: []))
            case "/api/v1/sync/pull":
                return TestResponses.ok(SyncPullData(cursor: "c2", hasMore: false, books: [], records: []))
            default:
                return TestResponses.okEmpty()
            }
        }
        await engine.resolveAccountSwitch(mergeIntoNewAccount: false)

        let books = try await repository.books()
        let tombstones = try await repository.tombstonedBooks()
        XCTAssertTrue(books.isEmpty, "清空分支：本地物理清空")
        XCTAssertTrue(tombstones.isEmpty, "硬删除不打墓碑（墓碑会误删云端数据）")
        XCTAssertEqual(store.cursor(), "c2", "清空后按云端全量重建（本轮 pull 为空）")
        XCTAssertEqual(store.lastSyncAccountId(), 2)
    }

    // ---- 装饰器：写路径登记待推 ----

    func testSyncAwareRepository_marksWritesPending_andDeleteBookCascades() async throws {
        let decorated = SyncAwareLibraryRepository(inner: repository, engine: engine)
        let book = try await decorated.addBook(NewBook(title: "书", author: "", totalPages: 10))
        let record = try await decorated.addRecord(NewRecord(bookId: book.id, date: day(13), pageReached: 5))

        XCTAssertTrue(store.pendingBookGuids().contains(book.guid))
        XCTAssertTrue(store.pendingRecordGuids().contains(record.guid))

        try await decorated.deleteBook(id: book.id)
        XCTAssertTrue(store.pendingBookGuids().contains(book.guid), "删书 = 书墓碑待推")
        XCTAssertTrue(store.pendingRecordGuids().contains(record.guid), "记录随书一并墓碑待推")
    }

    // ---- 封面同步（票 09）----

    func testCoverUpload_replacesLocalPathWithServerReference() async throws {
        let bytes = Data([0xFF, 0xD8, 0xFF])
        let localPath = try await repository.saveCoverImage(bytes: bytes, fileExtension: "jpg")
        let book = try await repository.addBook(
            NewBook(title: "带封面", author: "", totalPages: 10, coverImagePath: localPath),
        )
        engine.markBooksChanged([book.guid])

        var pushedBooks: [SyncBookChange] = []
        MockURLProtocol.handler = { [self] request in
            switch request.url?.path {
            case "/api/v1/sync/covers":
                return TestResponses.ok(SyncCoverUploadData(path: "/static/covers/abc.jpg"))
            case "/api/v1/sync/push":
                if let body = request.bodyData,
                   let parsed = try? JSONDecoder().decode(SyncPushRequest.self, from: body) {
                    pushedBooks += parsed.books
                }
                return TestResponses.ok(SyncPushData(cursor: "c1", results: [
                    SyncPushResult(guid: book.guid, entity: "book", accepted: true, reason: nil),
                ]))
            case "/api/v1/sync/pull":
                return TestResponses.ok(SyncPullData(cursor: "c2", hasMore: false, books: [], records: []))
            default:
                return TestResponses.okEmpty()
            }
        }
        session.send(member())
        _ = await engine.syncNow()

        let local = try await repository.bookByGuid(guid: book.guid)
        XCTAssertEqual(local?.coverImagePath, "https://test.local/static/covers/abc.jpg", "本地引用改写为完整 URL")
        XCTAssertEqual(pushedBooks.first?.coverImagePath, "/static/covers/abc.jpg", "推送时剥回相对路径")
        XCTAssertFalse(FileManager.default.fileExists(atPath: localPath), "上传后本地原文件删除，只留最新一份")
        XCTAssertTrue(store.pendingBookGuids().isEmpty, "换引用后不再反复推")
    }

    // ---- 未登录 ----

    func testSyncNow_withoutSession_returnsFalseAndDoesNoNetwork() async throws {
        MockURLProtocol.handler = { _ in
            XCTFail("未登录不应发起任何同步请求")
            return TestResponses.okEmpty()
        }
        let ok = await engine.syncNow()
        XCTAssertFalse(ok)
    }

    // ---- 工具 ----

    /// 轮询等待异步观察循环生效（引擎 start 后的 session 处理在后台任务中）。
    private func waitUntil(
        _ label: String,
        timeoutSeconds: UInt64 = 60,
        condition: @escaping () -> Bool,
    ) async throws {
        for _ in 0..<(timeoutSeconds * 50) {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("等待超时：\(label)")
    }

    private func cursorParam(of request: URLRequest) -> String? {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        return components.queryItems?.first { $0.name == "cursor" }?.value
    }
}
