import SwiftUI

/// 书架主页：在读列表在上、可折叠的「已读完」分区在下（当前页 ≥ 总页数自动归入）。
/// 领域展示规则：有计划且未到期才显示「今天目标 N 页」（ADR-0002：到期后目标完全消失）；
/// 多轮书显示「第 N 轮」标记；右上角进入「我」页。
struct HomeView: View {
    private let repository: any LibraryRepository
    private let auth: AuthRepository
    private let sync: SyncController

    @State private var books: [Book] = []
    @State private var currentPages: [Int64: Int] = [:] // bookId → 当前页
    @State private var showAddBook = false
    @State private var loadError: String?
    @SceneStorage("home.finishedExpanded") private var finishedExpanded = false

    init(repository: any LibraryRepository, auth: AuthRepository, sync: SyncController) {
        self.repository = repository
        self.auth = auth
        self.sync = sync
    }

    private var readingBooks: [Book] {
        books.filter { book in
            !ReadingRules.isFinished(
                currentPage: currentPages[book.id] ?? 0,
                totalPages: book.totalPages,
            )
        }
    }

    private var finishedBooks: [Book] {
        books.filter { book in
            ReadingRules.isFinished(
                currentPage: currentPages[book.id] ?? 0,
                totalPages: book.totalPages,
            )
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    // iOS 16 无 ContentUnavailableView：自绘空状态
                    VStack(spacing: 12) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("还没有书籍")
                            .font(.headline)
                        Text("点击右下角 + 添加第一本书吧")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    bookList
                }
            }
            .navigationTitle("书乎")
            .navigationDestination(for: Book.self) { book in
                BookDetailView(repository: repository, bookID: book.id)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        ProfileView(repository: repository, auth: auth, sync: sync)
                    } label: {
                        Image(systemName: "person.circle")
                    }
                }
            }
            // 新增书籍的悬浮按钮（FAB）：不用 bottomBar——它会画一条底部背景横条，
            // 且从详情页返回后工具栏项会漂移到左侧
            .overlay(alignment: .bottomTrailing) {
                Button {
                    showAddBook = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                        .background(Color(UIColor.systemGray), in: Circle())
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                }
                .padding(.trailing, 20)
                .padding(.bottom, 28)
            }
            .sheet(isPresented: $showAddBook) {
                BookFormView(repository: repository) {
                    await reload()
                }
            }
            .task { await reload() }
            .alert("出错了", isPresented: .init(get: { loadError != nil }, set: { if !$0 { loadError = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(loadError ?? "")
            }
        }
    }

    private var bookList: some View {
        List {
            if !readingBooks.isEmpty {
                Section("在读") {
                    ForEach(readingBooks) { book in
                        NavigationLink(value: book) {
                            BookRow(
                                book: book,
                                currentPage: currentPages[book.id] ?? 0,
                                today: CalendarDay.today(),
                            )
                        }
                    }
                    .onDelete { offsets in
                        Task { await delete(readingBooks, at: offsets) }
                    }
                }
            }
            if !finishedBooks.isEmpty {
                Section {
                    Button {
                        finishedExpanded.toggle()
                    } label: {
                        HStack {
                            Text("已读完（\(finishedBooks.count)）")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(finishedExpanded ? "收起" : "展开")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if finishedExpanded {
                        ForEach(finishedBooks) { book in
                            NavigationLink(value: book) {
                                BookRow(
                                    book: book,
                                    currentPage: currentPages[book.id] ?? 0,
                                    today: CalendarDay.today(),
                                )
                            }
                        }
                        .onDelete { offsets in
                            Task { await delete(finishedBooks, at: offsets) }
                        }
                    }
                }
            }
        }
    }

    private func reload() async {
        do {
            let loaded = try await repository.books()
            books = loaded
            var pages: [Int64: Int] = [:]
            for book in loaded {
                pages[book.id] = (try? await repository.currentPage(bookId: book.id)) ?? 0
            }
            currentPages = pages
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func delete(_ source: [Book], at offsets: IndexSet) async {
        for index in offsets {
            try? await repository.deleteBook(id: source[index].id)
        }
        await reload()
    }
}

/// 书架行：封面 + 标题/作者（多轮标记）+ 当前进度 +（可选）今日目标。
private struct BookRow: View {
    let book: Book
    let currentPage: Int
    let today: CalendarDay

    var body: some View {
        HStack(spacing: 12) {
            CoverImageView(path: book.coverImagePath, width: 58, height: 78)
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !book.author.isEmpty {
                        Text(book.author)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if book.currentRound > 1 {
                        Text("第 \(book.currentRound) 轮")
                            .font(.caption)
                            .foregroundStyle(.purple)
                    }
                }
                if let target = ReadingPlan.dailyTarget(
                    totalPages: book.totalPages,
                    currentPage: currentPage,
                    startDate: book.startDate,
                    endDate: book.endDate,
                    today: today,
                ) {
                    Text(PlanLabels.dailyTargetLabel(target))
                        .font(.caption)
                        .foregroundStyle(.purple)
                }
                ProgressView(value: min(Double(currentPage), Double(max(book.totalPages, 1))), total: Double(max(book.totalPages, 1)))
                Text("\(currentPage) / \(book.totalPages) 页")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
