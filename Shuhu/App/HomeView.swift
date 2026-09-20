import SwiftUI

/// 全屏页路由（odui 无底部 Tab：主页唯一主屏，其余全屏页压栈）。
enum AppRoute: Hashable {
    case book(Book)
    case settings
    case about
}

/// 主页列表项：书籍 + 由记录推导的当前页 + 计划/逾期展示字段（对齐 Android `HomeBookUi`）。
struct HomeBookUi: Identifiable, Hashable {
    let book: Book
    let currentPage: Int
    let dailyTarget: Int?
    let daysLeft: Int?
    let multiRound: Bool
    /// 计划已到期时的超期天数（进行中/自由阅读为 nil）。
    let overdueDays: Int?

    var id: Int64 { book.id }

    var progressPercent: Double {
        ReadingRules.progressPercent(currentPage: currentPage, totalPages: book.totalPages)
    }

    /// 当前页 ≥ 总页数 → 已读完，自动归入主页「已读完」分区。
    var isFinished: Bool {
        ReadingRules.isFinished(currentPage: currentPage, totalPages: book.totalPages)
    }
}

/// 主页（odui editorial 纸墨，对齐 Android `HomeScreen`）：日期行 + logo 衬线标题、
/// 概览统计行、发丝线分隔的书籍行（无卡片）、第 2 本书后内联广告、已读完收起行、
/// 赭红 FAB、长按拖动排序（松手持久化到仓库）。
struct HomeView: View {
    private let repository: any LibraryRepository
    private let auth: any AuthRepository
    private let sync: SyncController
    private let adsClient: AdsClient
    private let membershipClient: MembershipClient
    private let toast: ToastCenter

    @State private var books: [Book] = []
    @State private var records: [ReadingRecord] = []
    @State private var booksLoaded = false
    @State private var adsLoaded = false
    @State private var loadError: String?

    @State private var inlineAd: AdCreativeData?
    @State private var adClosed = false
    @State private var reportedAdImpressions: Set<Int64> = []

    @State private var navPath: [AppRoute] = []
    @State private var showAddBook = false
    @State private var showMembership = false
    @SceneStorage("home.finishedExpanded") private var finishedExpanded = false

    // ---- 拖动排序 ----
    @State private var draggingId: Int64?
    @State private var dragOffsetY: CGFloat = 0
    @State private var lastDragTranslation: CGFloat = 0
    @State private var localOrder: [HomeBookUi]?
    @State private var adRowHeight: CGFloat = 0

    /// 书行高度：封面 90 + 纵向 padding 20×2 + 下发丝线 1（与 Android 实测一致）。
    private static let bookRowHeight: CGFloat = 131

    init(
        repository: any LibraryRepository,
        auth: any AuthRepository,
        sync: SyncController,
        adsClient: AdsClient,
        membershipClient: MembershipClient,
        toast: ToastCenter,
    ) {
        self.repository = repository
        self.auth = auth
        self.sync = sync
        self.adsClient = adsClient
        self.membershipClient = membershipClient
        self.toast = toast
    }

    // ---- 派生数据 ----

    private var today: CalendarDay { CalendarDay.today() }

    private var items: [HomeBookUi] {
        books.map { book in
            let bookRecords = records.filter { $0.bookId == book.id }
            let currentPage = ReadingRules.currentPage(records: bookRecords, round: book.currentRound)
            return HomeBookUi(
                book: book,
                currentPage: currentPage,
                // 计划到期后 dailyTarget 为 nil：目标与倒计时完全消失（ADR-0002）
                dailyTarget: ReadingPlan.dailyTarget(
                    totalPages: book.totalPages,
                    currentPage: currentPage,
                    startDate: book.startDate,
                    endDate: book.endDate,
                    today: today,
                ),
                daysLeft: ReadingPlan.hasPlan(book) && today <= book.endDate!
                    ? ReadingPlan.remainingDays(today: today, endDate: book.endDate!)
                    : nil,
                multiRound: ReadingRules.hasMultipleRounds(book: book, records: bookRecords),
                overdueDays: book.endDate.flatMap { end in
                    today > end ? end.days(until: today) : nil
                },
            )
        }
    }

    private var reading: [HomeBookUi] { items.filter { !$0.isFinished } }
    private var finished: [HomeBookUi] { items.filter { $0.isFinished } }

    /// 列表顺序的唯一数据源：默认用仓库实时值，只有拖动期（及落库回灌前）用本地顺序覆盖。
    private var displayReading: [HomeBookUi] { localOrder ?? reading }

    private var ready: Bool { booksLoaded && adsLoaded }

    private var stats: (readingCount: Int, monthPagesRead: Int64, finishedThisYear: Int) {
        (
            reading.count,
            ReadingStats.totalPagesReadBetween(
                records: records,
                from: monthStart(),
                to: today,
            ),
            ReadingStats.finishedCountSince(books: books, records: records, earliest: yearStart()),
        )
    }

    private func monthStart() -> CalendarDay {
        CalendarDay(year: today.year, month: today.month, day: 1)
    }

    private func yearStart() -> CalendarDay {
        CalendarDay(year: today.year, month: 1, day: 1)
    }

    // ---- 列表建模：广告是列表里一个普通的、不可拖动的项（第 2 本书后，不足 2 本在最后）----

    private enum HomeListItem: Identifiable {
        case book(HomeBookUi)
        case ad(AdCreativeData)

        var id: String {
            switch self {
            case .book(let item): return "book-\(item.book.id)"
            case .ad(let creative): return "ad-\(creative.id)"
            }
        }
    }

    private var displayList: [HomeListItem] {
        var list: [HomeListItem] = displayReading.map { .book($0) }
        if let ad = inlineAd, !adClosed, !displayReading.isEmpty {
            list.insert(.ad(ad), at: min(2, list.count))
        }
        return list
    }

    // ---- body ----

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack(alignment: .bottomTrailing) {
                Paper.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    HomeHeader(onOpenSettings: { navPath.append(.settings) })
                    ShelfStats(stats: stats)
                    content
                }
                fab
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .book(let book):
                    BookDetailView(
                        repository: repository,
                        adsClient: adsClient,
                        bookID: book.id,
                        onOpenMembership: { showMembership = true },
                    )
                    .toolbar(.hidden, for: .navigationBar)
                case .settings:
                    ProfileView(
                        repository: repository,
                        auth: auth,
                        sync: sync,
                        toast: toast,
                        onOpenMembership: { showMembership = true },
                        onOpenAbout: { navPath.append(.about) },
                    )
                    .toolbar(.hidden, for: .navigationBar)
                case .about:
                    AboutView()
                        .toolbar(.hidden, for: .navigationBar)
                }
            }
            .sheet(isPresented: $showAddBook) {
                BookFormView(repository: repository) {
                    await reloadBooks()
                }
            }
            .sheet(isPresented: $showMembership) {
                MembershipView(
                    client: membershipClient,
                    auth: auth,
                    toast: toast,
                    onPurchased: {
                        showMembership = false
                        toast.show("支付成功，会员已开通（模拟支付）")
                        // 购买成功跳设置页（从设置页进入的已在设置页，不重复压栈）
                        if navPath.last != .settings {
                            navPath.append(.settings)
                        }
                    },
                    onClose: { showMembership = false },
                )
                .presentationDragIndicator(.hidden)
            }
            .task {
                async let booksTask: () = reloadBooks()
                async let adTask: () = loadInlineAd()
                _ = await (booksTask, adTask)
            }
            .alert("出错了", isPresented: .init(get: { loadError != nil }, set: { if !$0 { loadError = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(loadError ?? "")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !ready {
            // 就绪门未放行：纸底占位，等书籍首发 + 广告拉取完成（列表一出现即终态）
            Spacer()
        } else if books.isEmpty {
            EmptyState()
        } else {
            shelfList
        }
    }

    private var shelfList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(displayList) { entry in
                    switch entry {
                    case .book(let item):
                        bookRow(item)
                    case .ad(let creative):
                        InlineAdCard(
                            creative: creative,
                            slot: AdSlots.homeListBottom,
                            adsClient: adsClient,
                            onClosed: { adClosed = true },
                            onOpenMembership: { showMembership = true },
                        )
                        .padding(.horizontal, 22)
                        .padding(.vertical, 16)
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear { adRowHeight = proxy.size.height }
                                    .onChange(of: proxy.size.height) { _, h in adRowHeight = h }
                            },
                        )
                        .onAppear {
                            // 进入视口即视为曝光，每会话每素材一次
                            if reportedAdImpressions.insert(creative.id).inserted {
                                adsClient.reportImpressions(slot: AdSlots.homeListBottom, ids: [creative.id])
                            }
                        }
                    }
                }

                if !finished.isEmpty {
                    Spacer().frame(height: 24)
                    FinishedSectionHeader(
                        count: finished.count,
                        expanded: finishedExpanded,
                        onToggle: { finishedExpanded.toggle() },
                    )
                    if finishedExpanded {
                        ForEach(finished) { item in
                            bookRow(item, draggable: false)
                        }
                    }
                    Spacer().frame(height: 24)
                }

                Spacer().frame(height: 110) // 底部留出 FAB 空间
            }
        }
        .coordinateSpace(name: "shelf")
        .scrollIndicators(.hidden)
    }

    private func bookRow(_ item: HomeBookUi, draggable: Bool = true) -> some View {
        BookRow(
            item: item,
            onTap: { navPath.append(.book(item.book)) },
        )
        .offset(y: draggingId == item.id ? dragOffsetY : 0)
        .zIndex(draggingId == item.id ? 1 : 0)
        // 被拖行的换位布局跳变不做动画：布局位置与 offset 同帧反向抵消，视觉才连续；
        // 其余行保持 withAnimation 滑入空位。
        .transaction { tx in
            if draggingId == item.id { tx.animation = nil }
        }
        .gesture(dragGesture(for: item), including: draggable ? .all : .subviews)
    }

    // ---- 拖动排序（长按书籍行上下拖动，松手持久化到仓库）----

    private func dragGesture(for item: HomeBookUi) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .first(true):
                    beginDrag(item)
                case .second(true, let drag?):
                    updateDrag(item, translation: drag.translation.height)
                default:
                    break
                }
            }
            .onEnded { _ in endDrag() }
    }

    private func beginDrag(_ item: HomeBookUi) {
        guard draggingId == nil else { return }
        draggingId = item.id
        localOrder = reading
        dragOffsetY = 0
        lastDragTranslation = 0
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// 各槽位的静止中线（拖动度量用）：书行 131pt；广告用实测高（未测到按宽高比估算）。
    private func displaySlotMids() -> [String: CGFloat] {
        var mids: [String: CGFloat] = [:]
        var top: CGFloat = 0
        let adHeight = adRowHeight > 0
            ? adRowHeight
            : (UIScreen.main.bounds.width - 44) * (480 / 1344) + 34
        for entry in displayList {
            let height: CGFloat
            switch entry {
            case .book: height = Self.bookRowHeight
            case .ad: height = adHeight
            }
            mids[entry.id] = top + height / 2
            top += height
        }
        return mids
    }

    /// 换位 = 两个槽位互换内容，步长按「目标槽位 − 被拖槽位」实测：
    /// 广告卡夹在第 2、3 本之间时上下步长不等（对齐 Android 算法）。
    private func updateDrag(_ item: HomeBookUi, translation: CGFloat) {
        guard draggingId == item.id, var order = localOrder,
              var index = order.firstIndex(where: { $0.id == item.id }) else { return }
        dragOffsetY += translation - lastDragTranslation
        lastDragTranslation = translation

        let mids = displaySlotMids()
        func slotMid(_ entry: HomeBookUi) -> CGFloat {
            mids["book-\(entry.id)"] ?? 0
        }

        var slot = slotMid(order[index])
        var swapped = false
        while index < order.count - 1 {
            let step = slotMid(order[index + 1]) - slot
            guard step > 0, dragOffsetY > step / 2 else { break }
            order.swapAt(index, index + 1)
            dragOffsetY -= step
            slot += step
            swapped = true
            index += 1
        }
        while index > 0 {
            let step = slot - slotMid(order[index - 1])
            guard step > 0, dragOffsetY < -step / 2 else { break }
            order.swapAt(index, index - 1)
            dragOffsetY += step
            slot -= step
            swapped = true
            index -= 1
        }
        if swapped {
            // 跟手换位：仅换位动画化，拖动位移保持即时
            withAnimation(.easeInOut(duration: 0.18)) {
                localOrder = order
            }
        }
    }

    private func endDrag() {
        guard draggingId != nil, let order = localOrder else {
            resetDrag()
            return
        }
        let orderedIds = order.map(\.book.id) + finished.map(\.book.id)
        // 松手平滑回位：draggingId 一清，被拖行的 .transaction 恢复，此动画生效
        withAnimation(.easeOut(duration: 0.15)) {
            draggingId = nil
            dragOffsetY = 0
        }
        Task {
            try? await repository.updateBookSortOrder(orderedIds)
            await reloadBooks()
            // 落库回灌完成后交回仓库顺序（避免闪回旧顺序）
            localOrder = nil
        }
    }

    private func resetDrag() {
        draggingId = nil
        dragOffsetY = 0
        lastDragTranslation = 0
    }

    // ---- 悬浮按钮（本屏唯一的赭红大色块）----

    private var fab: some View {
        Button {
            showAddBook = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Paper.ochre, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }
        .padding(20)
    }

    // ---- 加载 ----

    private func reloadBooks() async {
        do {
            books = try await repository.books()
            records = try await repository.allRecords()
        } catch {
            loadError = error.localizedDescription
        }
        booksLoaded = true
    }

    /// 列表内联广告素材：失败/无素材为 nil（广告不出现），不报错；完成即通知就绪门放行。
    private func loadInlineAd() async {
        inlineAd = await adsClient.activeCreatives(slot: AdSlots.homeListBottom).first
        adsLoaded = true
    }
}

// MARK: - 头部 / 统计 / 空态 / 分区头

/// 日期行 + logo 衬线标题 + 圆形发丝线设置按钮。
private struct HomeHeader: View {
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(DateFormats.todayLine(CalendarDay.today()))
                .font(.paperMono(11))
                .tracking(1.3)
                .foregroundStyle(Paper.inkMuted)
            HStack {
                LogoMark()
                    .frame(width: 34, height: 34)
                Text("书乎")
                    .font(.paperSerif(30, weight: .bold))
                    .foregroundStyle(Paper.ink)
                    .padding(.leading, 12)
                Spacer()
                CircleHairlineButton(systemName: "gearshape", iconSize: 19, action: onOpenSettings)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }
}

/// 概览统计行：上下发丝线夹住的等宽数字（在读 / 本月已读页 / 今年读完）。
private struct ShelfStats: View {
    let stats: (readingCount: Int, monthPagesRead: Int64, finishedThisYear: Int)

    var body: some View {
        VStack(spacing: 0) {
            HairlineRule()
            HStack {
                StatCell(value: "\(stats.readingCount)", label: "在读")
                Spacer()
                StatCell(value: "\(stats.monthPagesRead)", label: "本月已读页")
                Spacer()
                StatCell(value: "\(stats.finishedThisYear)", label: "今年读完")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            HairlineRule()
        }
    }
}

private struct StatCell: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.paperMono(17))
                .foregroundStyle(Paper.ink)
            Text(label)
                .font(.system(size: 11))
                .tracking(0.7)
                .foregroundStyle(Paper.inkMuted)
        }
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("还没有书籍")
                .font(.paperSerif(18, weight: .bold))
                .foregroundStyle(Paper.ink)
            Text("点击右下角 ＋ 添加第一本书吧")
                .font(.system(size: 15))
                .foregroundStyle(Paper.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 80)
    }
}

/// 可折叠的「已读完」收起行。
private struct FinishedSectionHeader: View {
    let count: Int
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HairlineRule()
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Text("已读完")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Paper.ink)
                    Text("\(count)")
                        .font(.paperMono(14))
                        .foregroundStyle(Paper.inkMuted)
                    Spacer()
                    Text(expanded ? "收起 −" : "展开 ＋")
                        .font(.paperMono(11))
                        .tracking(0.9)
                        .foregroundStyle(Paper.inkMuted)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HairlineRule()
        }
    }
}

// MARK: - 书籍行

/// 书架行（odui）：封面/书脊 62×90 + 书名衬线 + 作者/轮次 + 计划行 + 2pt 进度条与页码。
private struct BookRow: View {
    let item: HomeBookUi
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                CoverImageView(path: item.book.coverImagePath, title: item.book.title, width: 62, height: 90)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.book.title)
                        .font(.paperSerif(18, weight: .bold))
                        .lineLimit(1)
                        .foregroundStyle(Paper.ink)
                    Spacer().frame(height: 3)
                    HStack(spacing: 8) {
                        Text(item.book.author)
                            .font(.system(size: 13))
                            .foregroundStyle(Paper.inkMuted)
                            .lineLimit(1)
                        if item.multiRound {
                            RoundTag(text: "第 \(item.book.currentRound) 轮")
                        }
                    }
                    planRow
                    Spacer(minLength: 0)
                    progressRow
                }
                .frame(height: 90)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .background(Paper.bg)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            HairlineRule()
        }
    }

    /// 计划行：进行中 = 今天目标/剩余天数；逾期 = 超期与差页（赭红）+ 截止日期；自由阅读不显示。
    @ViewBuilder
    private var planRow: some View {
        let book = item.book
        if let overdueDays = item.overdueDays {
            planLine(
                left: DateFormats.overdueLine(
                    daysOver: overdueDays,
                    pagesLeft: max(book.totalPages - item.currentPage, 0),
                ),
                accent: true,
                right: "\(DateFormats.shortDate(book.endDate!)) 截止",
            )
        } else if let target = item.dailyTarget, let daysLeft = item.daysLeft {
            planLine(
                left: DateFormats.dailyTargetLabel(target),
                accent: false,
                right: DateFormats.daysLeft(daysLeft),
            )
        }
    }

    private func planLine(left: String, accent: Bool, right: String) -> some View {
        HStack(spacing: 8) {
            Text(left)
                .font(.system(size: 12))
                .foregroundStyle(accent ? Paper.ochre : Paper.inkMuted)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(right)
                .font(.system(size: 12))
                .foregroundStyle(Paper.inkMuted)
                .lineLimit(1)
        }
        .padding(.top, 4)
    }

    /// 进度 + 页码一行：页码宽度优先（不截断），进度条吃剩余空间。
    private var progressRow: some View {
        HStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Paper.hairline)
                    Rectangle()
                        .fill(Paper.ink)
                        .frame(width: geo.size.width * min(max(item.progressPercent, 0), 1))
                }
            }
            .frame(height: 2)
            Text("\(item.currentPage) / \(item.book.totalPages) 页")
                .font(.paperMono(12))
                .foregroundStyle(Paper.ink)
                .lineLimit(1)
                .fixedSize()
        }
    }
}
