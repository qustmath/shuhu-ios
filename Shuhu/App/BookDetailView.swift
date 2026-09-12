import SwiftUI

/// 书籍详情：计划信息 + 记录时间线 + 记一笔。
/// 记录为「读到的累计页码」；可补记过去的日子；左滑删除单条记录。
struct BookDetailView: View {
    private let repository: any LibraryRepository
    private let bookID: Int64

    @State private var book: Book?
    @State private var records: [ReadingRecord] = []
    @State private var currentPage: Int = 0
    @State private var showAddRecord = false
    @State private var loadError: String?

    init(repository: any LibraryRepository, bookID: Int64) {
        self.repository = repository
        self.bookID = bookID
    }

    var body: some View {
        List {
            if let book {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(currentPage) / \(book.totalPages) 页")
                            .font(.title3.bold())
                        if let plan = planLine(book) {
                            Text(plan)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("阅读记录") {
                    if records.isEmpty {
                        Text("还没有记录，从今天开始记一笔吧")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(records) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("读到第 \(record.pageReached) 页")
                                        .font(.subheadline.bold())
                                    Spacer()
                                    Text(record.date.iso)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let remark = record.remark, !remark.isEmpty {
                                    Text(remark)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            Task { await deleteRecords(at: offsets) }
                        }
                    }
                }
            }
        }
        .navigationTitle(book?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("记一笔") { showAddRecord = true }
            }
        }
        .sheet(isPresented: $showAddRecord) {
            if let book {
                AddRecordView(book: book) { draft in
                    _ = try await repository.addRecord(draft)
                    await reload()
                }
            }
        }
        .task { await reload() }
        .alert("出错了", isPresented: .init(get: { loadError != nil }, set: { if !$0 { loadError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(loadError ?? "")
        }
    }

    /// 计划信息行：`(5天) 09月04日 · 剩 4 天`；自由阅读或已到期返回 nil（ADR-0002）。
    private func planLine(_ book: Book) -> String? {
        guard let start = book.startDate, let end = book.endDate else { return nil }
        let today = CalendarDay.today()
        guard today <= end else { return nil }
        let duration = ReadingPlan.planDurationDays(start: start, end: end)
        let left = ReadingPlan.remainingDays(today: today, endDate: end)
        return "\(PlanLabels.planDateWithDuration(durationDays: duration, end: end)) · \(PlanLabels.daysLeft(left))"
    }

    private func reload() async {
        do {
            book = try await repository.book(id: bookID)
            records = try await repository.records(bookId: bookID)
            currentPage = (try await repository.currentPage(bookId: bookID)) ?? 0
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func deleteRecords(at offsets: IndexSet) async {
        for index in offsets {
            try? await repository.deleteRecord(id: records[index].id)
        }
        await reload()
    }
}

/// 记一笔表单：日期（可补记）+ 读到页 + 备注。
struct AddRecordView: View {
    let book: Book
    let onSave: (_ draft: NewRecord) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var pageText = ""
    @State private var remark = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("读到了第几页") {
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                    TextField("页码（累计）", text: $pageText)
                        .keyboardType(.numberPad)
                }
                Section("备注（可选）") {
                    TextField("当时的想法…", text: $remark, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("记一笔")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(pageTextInvalid)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var pageTextInvalid: Bool {
        guard let page = Int(pageText.trimmingCharacters(in: .whitespaces)) else { return true }
        return page < 0
    }

    private func save() async {
        guard let page = Int(pageText.trimmingCharacters(in: .whitespaces)) else { return }
        do {
            try await onSave(NewRecord(
                bookId: book.id,
                date: CalendarDay.today(now: date),
                pageReached: page,
                remark: remark.isEmpty ? nil : remark,
            ))
            dismiss()
        } catch {
            // 保存失败保留表单，由调用方 alert 呈现
        }
    }
}
