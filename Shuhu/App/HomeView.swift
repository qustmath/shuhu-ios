import SwiftUI

/// 书架主页：书籍卡片（进度 + 今日目标）+ 右下角新增。
/// 领域展示规则：有计划且未到期才显示「今天目标 N 页」（ADR-0002：到期后目标完全消失）。
struct HomeView: View {
    private let repository: any LibraryRepository

    @State private var books: [Book] = []
    @State private var currentPages: [Int64: Int] = [:] // bookId → 当前页
    @State private var showAddBook = false
    @State private var loadError: String?

    init(repository: any LibraryRepository) {
        self.repository = repository
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
                    List {
                        ForEach(books) { book in
                            NavigationLink(value: book) {
                                BookRow(
                                    book: book,
                                    currentPage: currentPages[book.id] ?? 0,
                                    today: CalendarDay.today(),
                                )
                            }
                        }
                        .onDelete { offsets in
                            Task { await delete(at: offsets) }
                        }
                    }
                }
            }
            .navigationTitle("书乎")
            .navigationDestination(for: Book.self) { book in
                BookDetailView(repository: repository, bookID: book.id)
            }
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        Spacer()
                        Button {
                            showAddBook = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 44))
                        }
                    }
                }
            }
            .sheet(isPresented: $showAddBook) {
                AddBookView { draft in
                    _ = try await repository.addBook(draft)
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

    private func delete(at offsets: IndexSet) async {
        for index in offsets {
            try? await repository.deleteBook(id: books[index].id)
        }
        await reload()
    }
}

/// 书架行：标题/作者 + 当前进度 +（可选）今日目标。
private struct BookRow: View {
    let book: Book
    let currentPage: Int
    let today: CalendarDay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(book.title)
                .font(.headline)
            if !book.author.isEmpty {
                Text(book.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
        .padding(.vertical, 4)
    }
}
