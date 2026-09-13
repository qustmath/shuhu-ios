import SwiftUI

/// 书籍详情：封面头部 + 「记一笔 / 重读」+ 记录时间线（分轮展示）。
/// 记录为「读到的累计页码」；可补记过去的日子；可编辑、左滑删除。
/// 已读完的书隐藏「记一笔」（页码合法区间为空），以「重读」替代：currentRound+1，进度归零，历史保留。
struct BookDetailView: View {
    private let repository: any LibraryRepository
    private let bookID: Int64

    @State private var book: Book?
    @State private var records: [ReadingRecord] = []
    @State private var currentPage: Int = 0
    @State private var showAddRecord = false
    @State private var showEditBook = false
    @State private var editingRecord: ReadingRecord?
    @State private var loadError: String?

    init(repository: any LibraryRepository, bookID: Int64) {
        self.repository = repository
        self.bookID = bookID
    }

    private var isFinished: Bool {
        guard let book else { return false }
        return ReadingRules.isFinished(currentPage: currentPage, totalPages: book.totalPages)
    }

    private var multiRound: Bool {
        guard let book else { return false }
        return ReadingRules.hasMultipleRounds(book: book, records: records)
    }

    /// 旧轮次 → 该轮记录（轮次降序，记录保持展示顺序）。
    private var olderRounds: [(round: Int, records: [ReadingRecord])] {
        guard let book else { return [] }
        let rounds = Set(records.map(\.round)).filter { $0 != book.currentRound }.sorted(by: >)
        return rounds.map { round in
            (round, ReadingRules.recordsOfRound(records: records, round: round))
        }
    }

    var body: some View {
        List {
            if let book {
                Section {
                    HStack(spacing: 14) {
                        CoverImageView(path: book.coverImagePath, width: 92, height: 124)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text("\(currentPage) / \(book.totalPages) 页")
                                    .font(.title3.bold())
                                if multiRound {
                                    Text("第 \(book.currentRound) 轮")
                                        .font(.caption)
                                        .foregroundStyle(.purple)
                                }
                            }
                            if let plan = planLine(book) {
                                Text(plan)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    actionButton(book)
                        .frame(maxWidth: .infinity)
                }
                recordsSection(book)
            }
        }
        .navigationTitle(book?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showEditBook = true
                } label: {
                    Image(systemName: "pencil")
                }
            }
        }
        .sheet(isPresented: $showAddRecord) {
            if let book {
                RecordFormView(repository: repository, book: book, currentPage: currentPage, record: nil) {
                    await reload()
                }
            }
        }
        .sheet(item: $editingRecord) { record in
            if let book {
                RecordFormView(repository: repository, book: book, currentPage: currentPage, record: record) {
                    await reload()
                }
            }
        }
        .sheet(isPresented: $showEditBook) {
            if let book {
                BookFormView(repository: repository, book: book) {
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

    /// 已读完 → 「重读」；否则 → 「记一笔」（与 Android 详情页行为一致）。
    @ViewBuilder
    private func actionButton(_ book: Book) -> some View {
        if isFinished {
            Button {
                Task { await reread(book) }
            } label: {
                Text("重读")
                    .font(.body.bold())
                    .foregroundStyle(.purple)
                    .frame(maxWidth: .infinity)
            }
        } else {
            Button {
                showAddRecord = true
            } label: {
                Text("记一笔")
                    .font(.body.bold())
                    .foregroundStyle(.purple)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func recordsSection(_ book: Book) -> some View {
        Section {
            let currentRoundRecords = ReadingRules.recordsOfRound(records: records, round: book.currentRound)
            if currentRoundRecords.isEmpty {
                Text("还没有记录，从今天开始记一笔吧")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(currentRoundRecords) { record in
                    RecordRow(record: record)
                        .contentShape(Rectangle())
                        .onTapGesture { editingRecord = record }
                }
                .onDelete { offsets in
                    Task { await deleteRecords(currentRoundRecords, at: offsets) }
                }
            }
            ForEach(olderRounds, id: \.round) { group in
                OldRoundRow(round: group.round, records: group.records) { record in
                    editingRecord = record
                } onDelete: { offsets in
                    Task { await deleteRecords(group.records, at: offsets) }
                }
            }
        } header: {
            HStack {
                Text("阅读记录")
                Spacer()
                if multiRound {
                    Text("第 \(book.currentRound) 轮")
                        .foregroundStyle(.purple)
                }
            }
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

    /// 重读：当前轮 +1 写回仓库；新轮无记录 → 当前进度归零、回到在读区，历史原样保留。
    private func reread(_ book: Book) async {
        var updated = book
        updated.currentRound += 1
        do {
            try await repository.updateBook(updated)
            await reload()
        } catch {
            loadError = error.localizedDescription
        }
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

    private func deleteRecords(_ source: [ReadingRecord], at offsets: IndexSet) async {
        for index in offsets {
            try? await repository.deleteRecord(id: source[index].id)
        }
        await reload()
    }
}

/// 单条记录行：页码 + 日期 +（可选）备注。
private struct RecordRow: View {
    let record: ReadingRecord

    var body: some View {
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
}

/// 旧轮次折叠行：「第 N 轮（M 条）」，展开查看该轮记录与备注（可编辑/删除）。
private struct OldRoundRow: View {
    let round: Int
    let records: [ReadingRecord]
    let onEdit: (ReadingRecord) -> Void
    let onDelete: (IndexSet) -> Void

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(records) { record in
                RecordRow(record: record)
                    .contentShape(Rectangle())
                    .onTapGesture { onEdit(record) }
            }
            .onDelete { offsets in
                onDelete(offsets)
            }
        } label: {
            Text("第 \(round) 轮（\(records.count) 条）")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// 记录表单：新增与编辑共用。日期（可补记）+ 读到页 + 备注。
/// 新增校验 (当前页, 总页数]；编辑校验 [1, 总页数]（允许改小，历史可能重排）。
struct RecordFormView: View {
    private let repository: any LibraryRepository
    private let book: Book
    /// 新增时用于页码校验的当前轮进度。
    private let currentPage: Int
    /// nil = 新增；非 nil = 编辑该记录（保留 id/createdAt/round/guid）。
    private let record: ReadingRecord?
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var pageText = ""
    @State private var remark = ""
    @State private var validationError: RecordValidationError?
    @State private var saveError: String?

    init(
        repository: any LibraryRepository,
        book: Book,
        currentPage: Int,
        record: ReadingRecord?,
        onSaved: @escaping () async -> Void,
    ) {
        self.repository = repository
        self.book = book
        self.currentPage = currentPage
        self.record = record
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("读到了第几页") {
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                    TextField("页码（累计）", text: $pageText)
                        .keyboardType(.numberPad)
                        .onChange(of: pageText) { _ in
                            validationError = validate()
                        }
                    if let validationError {
                        Text(message(of: validationError))
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Section("备注（可选）") {
                    TextField("当时的想法…", text: $remark, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle(record == nil ? "记一笔" : "编辑记录")
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
            .alert("保存失败", isPresented: .init(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
            .task { prefill() }
        }
        .presentationDetents([.medium, .large])
    }

    private var parsedPage: Int? {
        Int(pageText.trimmingCharacters(in: .whitespaces))
    }

    private var pageTextInvalid: Bool {
        guard let page = parsedPage else { return true }
        return page < 0 || validationError != nil
    }

    private func validate() -> RecordValidationError? {
        guard let page = parsedPage else { return nil }
        if record == nil {
            return ReadingRules.validateNewRecord(pageReached: page, currentPage: currentPage, totalPages: book.totalPages)
        }
        return ReadingRules.validateEditRecord(pageReached: page, totalPages: book.totalPages)
    }

    private func prefill() {
        guard let record else { return }
        date = record.date.toLocalDate()
        pageText = String(record.pageReached)
        remark = record.remark ?? ""
    }

    private func save() async {
        guard let page = parsedPage else { return }
        do {
            if let record {
                var updated = record
                updated.date = date.toCalendarDay()
                updated.pageReached = page
                updated.remark = remark.isEmpty ? nil : remark
                try await repository.updateRecord(updated)
            } else {
                _ = try await repository.addRecord(NewRecord(
                    bookId: book.id,
                    date: date.toCalendarDay(),
                    pageReached: page,
                    remark: remark.isEmpty ? nil : remark,
                ))
            }
            await onSaved()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func message(of error: RecordValidationError) -> String {
        switch error {
        case .belowOrEqualCurrentPage:
            record == nil ? "页码需大于当前页（\(currentPage)）" : "页码至少为 1"
        case .aboveTotalPages:
            "页码不能超过总页数（\(book.totalPages)）"
        }
    }
}

/// `Date`（本地时区）↔ `CalendarDay`（用户视角日历日）。
private extension Date {
    func toCalendarDay(timeZone: TimeZone = .current) -> CalendarDay {
        CalendarDay.today(now: self, timeZone: timeZone)
    }
}

private extension CalendarDay {
    func toLocalDate(timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }
}
