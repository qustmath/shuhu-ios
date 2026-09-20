import SwiftUI

/// 书籍详情（odui editorial 纸墨，对齐 Android `BookDetailScreen`）：
/// 进度是主角——超大衬线页码 + 日期轴 + 逾期警示；阅读记录带「本次 +N 页」增量，
/// 第 2 条记录后内联广告；底部主操作「记录进度」（读完变「重读」）。
struct BookDetailView: View {
    private let repository: any LibraryRepository
    private let adsClient: AdsClient
    private let bookID: Int64
    private let onOpenMembership: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var book: Book?
    @State private var records: [ReadingRecord] = []
    @State private var loadError: String?
    @State private var showEditBook = false

    @State private var showRecordSheet = false
    @State private var editingRecord: ReadingRecord?

    @State private var inlineAd: AdCreativeData?
    @State private var adLoaded = false
    @State private var adClosed = false
    @State private var reportedAdImpressions: Set<Int64> = []

    @State private var expandedRounds: Set<Int> = []

    init(repository: any LibraryRepository, adsClient: AdsClient, bookID: Int64, onOpenMembership: @escaping () -> Void) {
        self.repository = repository
        self.adsClient = adsClient
        self.bookID = bookID
        self.onOpenMembership = onOpenMembership
    }

    private var today: CalendarDay { CalendarDay.today() }

    private var currentPage: Int {
        guard let book else { return 0 }
        return ReadingRules.currentPage(records: records, round: book.currentRound)
    }

    var body: some View {
        VStack(spacing: 0) {
            PaperTopBar(title: "阅读计划", onBack: { dismiss() }) {
                CircleHairlineButton(systemName: "pencil", iconSize: 17) {
                    showEditBook = true
                }
            }

            if let book {
                ScrollView {
                    VStack(spacing: 0) {
                        BookHead(book: book, multiRound: ReadingRules.hasMultipleRounds(book: book, records: records))
                        ProgressHero(book: book, currentPage: currentPage, today: today)
                        TodayTargetRow(book: book, currentPage: currentPage, today: today)
                        recordsSection(book: book)
                    }
                }
                .scrollIndicators(.hidden)

                bottomAction(book: book)
            }
        }
        .background(Paper.bg.ignoresSafeArea())
        .task { await reload() }
        .task { await loadInlineAd() }
        .sheet(isPresented: $showEditBook) {
            if let book {
                BookFormView(repository: repository, book: book) {
                    await reload()
                }
            }
        }
        .sheet(isPresented: $showRecordSheet, onDismiss: { editingRecord = nil }) {
            if let book {
                // 编辑模式才传删除动作；显式类型避免 nil/闭包三元推断歧义
                let deleteAction: (() async -> Void)? = editingRecord != nil ? { await self.deleteEditingRecord() } : nil
                RecordSheetView(
                    book: book,
                    currentPage: currentPage,
                    existing: editingRecord,
                    onDismiss: {
                        showRecordSheet = false
                        editingRecord = nil
                    },
                    onSave: { page, date, remark in
                        await saveRecord(page: page, date: date, remark: remark)
                    },
                    onDelete: deleteAction,
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
            }
        }
        .alert("出错了", isPresented: .init(get: { loadError != nil }, set: { if !$0 { loadError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(loadError ?? "")
        }
    }

    // ---- 底部主操作（上缘发丝线）----

    private func bottomAction(book: Book) -> some View {
        let isFinished = ReadingRules.isFinished(currentPage: currentPage, totalPages: book.totalPages)
        return VStack(spacing: 0) {
            HairlineRule()
            PaperPrimaryButton(text: isFinished ? "重 读" : "记录进度") {
                if isFinished {
                    Task { await reread() }
                } else {
                    editingRecord = nil
                    showRecordSheet = true
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .background(Paper.bg)
    }

    // ---- 阅读记录区 ----

    private func recordsSection(book: Book) -> some View {
        let roundRecords = ReadingRules.recordsOfRound(records: records, round: book.currentRound)
        let olderRounds = Set(records.map(\.round)).subtracting([book.currentRound]).sorted(by: >)
        return VStack(spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text("阅读记录")
                    .font(.paperSerif(22, weight: .bold))
                    .foregroundStyle(Paper.ink)
                Spacer()
                Text("共 \(roundRecords.count) 条")
                    .font(.paperMono(12))
                    .foregroundStyle(Paper.inkMuted)
            }
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .padding(.bottom, 4)

            if roundRecords.isEmpty {
                Text("还没有记录，点「记录进度」写下你读到了哪一页")
                    .font(.system(size: 14))
                    .foregroundStyle(Paper.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
            } else {
                let deltas = recordDeltas(roundRecords)
                ForEach(Array(roundRecords.enumerated()), id: \.element.id) { index, record in
                    RecordRow(
                        record: record,
                        deltaText: deltaLabel(deltas[record.id] ?? 0),
                        onClick: {
                            editingRecord = record
                            showRecordSheet = true
                        },
                    )
                    HairlineRule()
                    // 内联广告：第 2 条记录之后（记录数少，组合即视为曝光，每会话每素材一次）
                    if index == 1, let ad = inlineAd, !adClosed {
                        InlineAdCard(
                            creative: ad,
                            slot: AdSlots.detailRecordsInline,
                            adsClient: adsClient,
                            onClosed: { adClosed = true },
                            onOpenMembership: onOpenMembership,
                        )
                        .padding(.horizontal, 22)
                        .padding(.vertical, 16)
                        .onAppear {
                            if reportedAdImpressions.insert(ad.id).inserted {
                                adsClient.reportImpressions(slot: AdSlots.detailRecordsInline, ids: [ad.id])
                            }
                        }
                    }
                }
            }

            // 旧轮次：默认收起，可展开查看（记录与备注保留）
            ForEach(olderRounds, id: \.self) { round in
                let roundRecords = ReadingRules.recordsOfRound(records: records, round: round)
                let expanded = expandedRounds.contains(round)
                Button {
                    if expanded { expandedRounds.remove(round) } else { expandedRounds.insert(round) }
                } label: {
                    HStack(spacing: 6) {
                        Text("第 \(round) 轮")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Paper.ink)
                        Text("\(roundRecords.count)")
                            .font(.paperMono(14))
                            .foregroundStyle(Paper.inkMuted)
                        Spacer()
                        Text(expanded ? "收起 −" : "展开 ＋")
                            .font(.paperMono(11))
                            .tracking(0.9)
                            .foregroundStyle(Paper.inkMuted)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                HairlineRule()
                if expanded {
                    ForEach(roundRecords) { record in
                        RecordRow(
                            record: record,
                            deltaText: nil,
                            onClick: {
                                editingRecord = record
                                showRecordSheet = true
                            },
                        )
                        HairlineRule()
                    }
                }
            }
            Spacer().frame(height: 24)
        }
    }

    /// 「本次 +N 页」增量：按时间升序相邻差值；列表保持仓库顺序（新的在前）。
    private func recordDeltas(_ roundRecords: [ReadingRecord]) -> [Int64: Int] {
        var byId: [Int64: Int] = [:]
        let sorted = roundRecords.sorted { a, b in
            if a.date != b.date { return a.date < b.date }
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id < b.id
        }
        var previous = 0
        for record in sorted {
            byId[record.id] = record.pageReached - previous
            previous = record.pageReached
        }
        return byId
    }

    private func deltaLabel(_ delta: Int) -> String {
        delta == 0 ? "开始" : "+\(delta)"
    }

    // ---- 动作 ----

    private func reload() async {
        do {
            book = try await repository.book(id: bookID)
            records = try await repository.records(bookId: bookID)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadInlineAd() async {
        if adLoaded { return }
        adLoaded = true
        inlineAd = await adsClient.activeCreatives(slot: AdSlots.detailRecordsInline).first
    }

    /// 重读：轮次 +1，当前页随之归零，旧轮次记录全部保留。
    private func reread() async {
        guard var updated = book else { return }
        updated.currentRound += 1
        do {
            try await repository.updateBook(updated)
            await reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func saveRecord(page: Int, date: CalendarDay, remark: String?) async {
        do {
            if let target = editingRecord {
                var updated = target
                updated.pageReached = page
                updated.date = date
                updated.remark = remark?.isEmpty == false ? remark : nil
                try await repository.updateRecord(updated)
            } else {
                _ = try await repository.addRecord(
                    NewRecord(bookId: bookID, date: date, pageReached: page, remark: remark?.isEmpty == false ? remark : nil),
                )
            }
            showRecordSheet = false
            editingRecord = nil
            await reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func deleteEditingRecord() async {
        guard let target = editingRecord else { return }
        do {
            try await repository.deleteRecord(id: target.id)
            showRecordSheet = false
            editingRecord = nil
            await reload()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - 子组件

/// 书籍头：96×140 封面/书脊 + 衬线标题 + 作者 + 轮次标签。
private struct BookHead: View {
    let book: Book
    let multiRound: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 18) {
            CoverImageView(path: book.coverImagePath, title: book.title, width: 96, height: 140)
            VStack(alignment: .leading, spacing: 0) {
                Text(book.title)
                    .font(.paperSerif(26, weight: .bold))
                    .lineLimit(2)
                    .foregroundStyle(Paper.ink)
                Text(book.author)
                    .font(.system(size: 14))
                    .foregroundStyle(Paper.inkMuted)
                    .padding(.top, 6)
                if multiRound {
                    RoundTag(text: "第 \(book.currentRound) 轮")
                        .padding(.top, 10)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 20)
    }
}

/// 进度主视觉：kicker + 超大衬线页码 + 百分比 + 逾期警示 + 2pt 进度线 + 日期轴。
private struct ProgressHero: View {
    let book: Book
    let currentPage: Int
    let today: CalendarDay

    private var percent: Double {
        ReadingRules.progressPercent(currentPage: currentPage, totalPages: book.totalPages)
    }

    var body: some View {
        VStack(spacing: 0) {
            HairlineRule()
            VStack(alignment: .leading, spacing: 0) {
                Text("当前进度 · 读到第")
                    .font(.paperMono(11))
                    .tracking(1.3)
                    .foregroundStyle(Paper.inkMuted)
                HStack(alignment: .lastTextBaseline, spacing: 0) {
                    Text("\(currentPage)")
                        .font(.paperSerif(64, weight: .bold))
                        .foregroundStyle(Paper.ink)
                    Text("/ \(book.totalPages) 页")
                        .font(.system(size: 15))
                        .foregroundStyle(Paper.inkMuted)
                        .padding(.leading, 10)
                        .padding(.bottom, 8)
                    Spacer(minLength: 0)
                    Text("\(Int(percent * 100))%")
                        .font(.paperMono(22))
                        .foregroundStyle(Paper.ink)
                        .padding(.bottom, 4)
                }
                .padding(.top, 8)

                // 逾期警示（赭红，本屏 accent 之一）
                if ReadingPlan.hasPlan(book), let end = book.endDate, today > end {
                    Text(DateFormats.overdueLine(
                        daysOver: end.days(until: today),
                        pagesLeft: max(book.totalPages - currentPage, 0),
                    ))
                    .font(.system(size: 13))
                    .foregroundStyle(Paper.ochre)
                    .padding(.top, 10)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Paper.hairline)
                        Rectangle()
                            .fill(Paper.ink)
                            .frame(width: geo.size.width * min(max(percent, 0), 1))
                    }
                }
                .frame(height: 2)
                .padding(.top, 16)

                if ReadingPlan.hasPlan(book), let start = book.startDate, let end = book.endDate {
                    HStack {
                        Text("\(DateFormats.shortDate(start)) 开始")
                        Spacer()
                        Text("\(DateFormats.shortDate(end)) 截止（\(ReadingPlan.planDurationDays(start: start, end: end)) 天）")
                    }
                    .font(.paperMono(11))
                    .foregroundStyle(Paper.inkMuted)
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
        }
    }
}

/// 今日目标行（计划进行中才有）：发丝线夹住的一行「今日目标 / N 页」。
private struct TodayTargetRow: View {
    let book: Book
    let currentPage: Int
    let today: CalendarDay

    var body: some View {
        if let target = ReadingPlan.dailyTarget(
            totalPages: book.totalPages,
            currentPage: currentPage,
            startDate: book.startDate,
            endDate: book.endDate,
            today: today,
        ) {
            VStack(spacing: 0) {
                HairlineRule()
                HStack {
                    Text("今日目标")
                        .font(.system(size: 14))
                        .foregroundStyle(Paper.ink)
                    Spacer()
                    Text("\(target) 页")
                        .font(.paperMono(13))
                        .foregroundStyle(Paper.ink)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 13)
                HairlineRule()
            }
        }
    }
}

/// 记录行：页码 + 本次增量 + 时间同一行（时间靠右，与页码底部对齐）；有备注时第二行。
private struct RecordRow: View {
    let record: ReadingRecord
    /// 增量标签（nil = 不显示，旧轮次展开时）。
    let deltaText: String?
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text("\(record.pageReached) 页")
                        .font(.paperMono(16))
                        .foregroundStyle(Paper.ink)
                    if let deltaText {
                        Text(deltaText)
                            .font(.system(size: 12))
                            .foregroundStyle(Paper.inkMuted)
                            .padding(.bottom, 1)
                    }
                    Spacer(minLength: 0)
                    // 补记日期后：日期来自记录本身，时刻来自录入时间
                    Text(DateFormats.recordDateTime(date: record.date, createdAt: record.createdAt))
                        .font(.paperMono(12))
                        .foregroundStyle(Paper.inkMuted)
                }
                if let remark = record.remark, !remark.isEmpty {
                    Text(remark)
                        .font(.system(size: 13))
                        .lineSpacing(7)
                        .foregroundStyle(Paper.inkMuted)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 记录底部表单

/// 阅读记录底部表单（对齐 Android `RecordSheet`）：existing 为 nil = 添加
/// （页码滚轮从「已读最大页 +1」起，无记录为第 1 页）；非 nil = 编辑（范围 1~总页数，可删除）。
private struct RecordSheetView: View {
    let book: Book
    let currentPage: Int
    let existing: ReadingRecord?
    let onDismiss: () -> Void
    let onSave: (Int, CalendarDay, String?) async -> Void
    let onDelete: (() async -> Void)?

    @State private var selectedPage: Int
    @State private var recordDate: CalendarDay
    @State private var remark: String
    @State private var error: String?
    @State private var showDatePicker = false
    @State private var showDeleteConfirm = false
    @State private var pickedDate: Date

    init(
        book: Book,
        currentPage: Int,
        existing: ReadingRecord?,
        onDismiss: @escaping () -> Void,
        onSave: @escaping (Int, CalendarDay, String?) async -> Void,
        onDelete: (() async -> Void)?,
    ) {
        self.book = book
        self.currentPage = currentPage
        self.existing = existing
        self.onDismiss = onDismiss
        self.onSave = onSave
        self.onDelete = onDelete
        let initialPage = existing?.pageReached ?? min(currentPage + 1, book.totalPages)
        _selectedPage = State(initialValue: initialPage)
        let initialDate = existing?.date ?? CalendarDay.today()
        _recordDate = State(initialValue: initialDate)
        _remark = State(initialValue: existing?.remark ?? "")
        _pickedDate = State(initialValue: initialDate.toDate())
    }

    private var isEditMode: Bool { existing != nil }

    /// 添加：可选范围为 (当前页, 总页数]；编辑：[1, 总页数]。
    private var pageValues: [Int] {
        let start = isEditMode ? 1 : min(currentPage + 1, book.totalPages)
        let values = Array(start...book.totalPages)
        return values.isEmpty ? [book.totalPages] : values
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部把手
            RoundedRectangle(cornerRadius: 999)
                .fill(Paper.hairline)
                .frame(width: 36, height: 4)
                .padding(.top, 8)
                .padding(.bottom, 12)

            // 标题行：居中标题 + 右侧关闭
            ZStack {
                Text(isEditMode ? "编辑阅读记录" : "添加阅读记录")
                    .font(.paperSerif(19, weight: .bold))
                    .foregroundStyle(Paper.ink)
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Text("✕")
                            .font(.system(size: 13))
                            .foregroundStyle(Paper.ink)
                            .frame(width: 36, height: 36)
                            .overlay(Circle().stroke(Paper.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(book.title)
                .font(.paperSerif(17, weight: .bold))
                .foregroundStyle(Paper.ink)
                .padding(.top, 12)
            Text(book.author)
                .font(.system(size: 13))
                .foregroundStyle(Paper.inkMuted)

            // 页码滚动选择：读到 [滚轮] 页 …… 读完（同一行最右）
            HStack {
                Text("读到")
                    .font(.system(size: 15))
                    .foregroundStyle(Paper.ink)
                Spacer()
                IntWheelPicker(values: pageValues, value: $selectedPage)
                    .frame(width: 110)
                Text("页")
                    .font(.system(size: 13))
                    .foregroundStyle(Paper.inkMuted)
                    .padding(.leading, 4)
                Spacer()
                Button {
                    selectedPage = book.totalPages
                    error = nil
                } label: {
                    Text("读完")
                        .font(.system(size: 14))
                        .foregroundStyle(Paper.ochre)
                        .padding(8)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 16)

            // 补记日期：点击用日期选择器改为过去的日期
            HStack {
                Text("日期")
                    .font(.system(size: 15))
                    .foregroundStyle(Paper.ink)
                Spacer()
                Button {
                    pickedDate = recordDate.toDate()
                    showDatePicker = true
                } label: {
                    Text(DateFormats.planDate(recordDate))
                        .font(.paperMono(16))
                        .foregroundStyle(Paper.ink)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 8)

            if let error {
                Text(error)
                    .font(.system(size: 14))
                    .foregroundStyle(Paper.ochre)
                    .padding(.vertical, 4)
            }

            remarkField
                .padding(.top, 8)

            PaperPrimaryButton(text: "完 成") {
                Task { await submit() }
            }
            .padding(.top, 12)

            if isEditMode, onDelete != nil {
                Button {
                    showDeleteConfirm = true
                } label: {
                    Text("删除这条记录")
                        .font(.system(size: 14))
                        .foregroundStyle(Paper.inkMuted)
                        .frame(maxWidth: .infinity)
                        .padding(10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .background(Paper.bg.ignoresSafeArea())
        .onChange(of: selectedPage) { _, _ in error = nil }
        .sheet(isPresented: $showDatePicker) {
            datePickerSheet
        }
        .alert("删除这条阅读记录？", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                Task { await onDelete?() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复。")
        }
    }

    /// 可选的多行备注输入（想法/摘录），不限长度。
    private var remarkField: some View {
        ZStack(alignment: .topLeading) {
            if remark.isEmpty {
                Text("写下你的想法…")
                    .font(.system(size: 14))
                    .foregroundStyle(Paper.inkMuted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $remark)
                .font(.system(size: 14))
                .lineSpacing(8)
                .foregroundStyle(Paper.ink)
                .tint(Paper.ochre)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 88, maxHeight: 200)
        }
        .background(Paper.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
    }

    private var datePickerSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") { showDatePicker = false }
                    .foregroundStyle(Paper.inkMuted)
                Spacer()
                Button("确定") {
                    recordDate = CalendarDay(date: pickedDate)
                    error = nil
                    showDatePicker = false
                }
                .foregroundStyle(Paper.ochre)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            DatePicker("", selection: $pickedDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(Paper.ochre)
                .padding(.horizontal, 12)
            Spacer()
        }
        .background(Paper.bg.ignoresSafeArea())
        .presentationDetents([.medium])
    }

    /// 滚轮已限定可选范围，这里仅做防御性校验（领域规则为准）。
    private func submit() async {
        let validationError = isEditMode
            ? ReadingRules.validateEditRecord(pageReached: selectedPage, totalPages: book.totalPages)
            : ReadingRules.validateNewRecord(pageReached: selectedPage, currentPage: currentPage, totalPages: book.totalPages)
        if let validationError {
            switch validationError {
            case .aboveTotalPages:
                error = "页码需在 1~\(book.totalPages) 之间"
            case .belowOrEqualCurrentPage:
                error = isEditMode
                    ? "页码需在 1~\(book.totalPages) 之间"
                    : "页码需在 \(currentPage + 1)~\(book.totalPages) 之间"
            }
            return
        }
        await onSave(selectedPage, recordDate, remark)
    }
}
