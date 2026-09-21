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

    // ---- 拖动排序（拖动期布局冻结，只做视觉位移；松手才落库）----
    /// 拖动期冻结的布局顺序（= 拖动开始时的 reading）：换位不改布局，只改各行的 offset。
    @State private var frozenOrder: [HomeBookUi]?
    /// 被拖书籍 id。
    @State private var draggingId: Int64?
    /// 手指位移（shelf 坐标，相对冻结槽位）。绝对量、不做补偿累减——换位判定是它的纯函数。
    @State private var dragOffsetY: CGFloat = 0
    /// 当前视觉顺序（松手提交这一个）。
    @State private var dragOrder: [HomeBookUi]?
    @State private var lastDragTranslation: CGFloat = 0
    @State private var localOrder: [HomeBookUi]?
    @State private var adRowHeight: CGFloat = 0

    /// 拖动测量用的命名坐标空间（定义在 ScrollView 上）：视口坐标系，不随行的槽位移动，
    /// 故 `DragGesture.translation` 不会被换位/动画/重锚定污染（旧实现在行的局部坐标系里量，被污染后自激振荡）。
    private static let shelfSpace = "shelf"

    /// 书行高度：封面 90 + 纵向 padding 20×2 + 下发丝线 1（与 Android 实测一致）。
    private static let bookRowHeight: CGFloat = 131

    /// 换位阈值的滞回量（pt）：越过「相邻两槽位中线 + 本值」才换过去，要换回来得越过「中线 − 本值」。
    ///
    /// 少了它就没有死区，指尖在玻璃上不可避免的抖动（±1~2pt）会把同一对行来回翻转——
    /// 现象就是「拖动排序时上下跳动」（实测录屏：手指停在 y≈700 不动，2.2 秒内翻 14 次）。
    /// 12pt ≈ 0.09 行，感知不到，但远大于指尖抖动幅度。
    private static let swapThresholdHysteresis: CGFloat = 12

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

    /// 列表渲染顺序的唯一数据源：拖动期用冻结顺序（布局不动，换位只靠 offset），
    /// 落库回灌前用本地顺序，其余用仓库实时值。
    private var displayReading: [HomeBookUi] {
        if draggingId != nil, let frozenOrder { return frozenOrder }
        return localOrder ?? reading
    }

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
                            bookRow(item)
                        }
                    }
                    Spacer().frame(height: 24)
                }

                Spacer().frame(height: 110) // 底部留出 FAB 空间
            }
        }
        .coordinateSpace(name: Self.shelfSpace)
        .scrollIndicators(.hidden)
        // 起拖后冻结滚动：长按已经在原地按住 0.35s，此时没有滚动在飞，关掉最干净。
        // 平时不关——行的拖动识别只做 simultaneousGesture，滚动照旧优先（旧实现用 .gesture 抢走了整屏滚动）。
        .scrollDisabled(draggingId != nil)
    }

    private func bookRow(_ item: HomeBookUi) -> some View {
        BookRow(
            item: item,
            onTap: { navPath.append(.book(item.book)) },
        )
        .offset(y: visualOffset(item))
        .zIndex(draggingId == item.book.id ? 1 : 0)
        // 被拖行必须严格跟手：拖动期它的位移不参与任何动画（换位动画只给让位的行）。
        // 松手那一帧 draggingId 已清，这里的覆写不再命中，落位动画正常生效。
        .transaction { tx in
            if draggingId == item.book.id { tx.animation = nil }
        }
        // simultaneousGesture（而非 gesture）：子视图的拖动识别不再抢走 ScrollView 的滚动，
        // 整屏都能正常上下滑（旧实现用 .gesture，于是只有广告那块能滑）。起拖后由 scrollDisabled 冻结滚动。
        // 已读完分区照样挂着识别器：`beginDrag` 只认 reading 里的书，长按已读完行不会起拖。
        .simultaneousGesture(dragGesture(for: item), including: .all)
    }

    // ---- 拖动排序（长按书籍行上下拖动，松手持久化到仓库）----

    private func dragGesture(for item: HomeBookUi) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.shelfSpace)))
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
        guard draggingId == nil, frozenOrder == nil else { return }
        guard reading.contains(where: { $0.book.id == item.book.id }) else { return }
        // 冻结布局：拖动期只改 offset，不动列表顺序（列表顺序一动，LazyVStack 会重锚定、坐标系会跳）
        frozenOrder = reading
        dragOrder = reading
        draggingId = item.book.id
        dragOffsetY = 0
        lastDragTranslation = 0
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // ---- 拖动度量：槽位几何 + 视觉位移（拖动期布局冻结，故这份几何全程不变）----

    /// 广告当前是否占一个槽位（被关掉/没素材/列表为空时不占）。
    private var adPresent: Bool { inlineAd != nil && !adClosed && !displayReading.isEmpty }

    /// 广告行高：实测优先（含行内 padding），未测到按素材宽高比估算。
    private var adHeight: CGFloat {
        adRowHeight > 0 ? adRowHeight : (UIScreen.main.bounds.width - 44) * (480 / 1344) + 34
    }

    /// 槽位中线（显示序）：书行 131pt，广告用实测高。
    private var slotMids: [CGFloat] {
        HomeReorder.slotMids(
            bookCount: displayReading.count,
            bookRowHeight: Self.bookRowHeight,
            adHeight: adHeight,
            hasAd: adPresent,
        )
    }

    private func slotMid(bookIndex: Int, bookCount: Int) -> CGFloat {
        let slot = HomeReorder.slotOfBook(bookIndex, bookCount: bookCount, hasAd: adPresent)
        return slot < slotMids.count ? slotMids[slot] : 0
    }

    /// 行的视觉位移：布局冻结不动，靠 offset 把行摆到它在「当前视觉顺序」里的槽位。
    /// 被拖行的位移就是手指位移本身（不做任何补偿），故同一手指位置必得同一顺序，不可能自激换位。
    private func visualOffset(_ item: HomeBookUi) -> CGFloat {
        guard let draggingId, let frozen = frozenOrder, let order = dragOrder else { return 0 }
        if item.book.id == draggingId { return dragOffsetY }
        guard let oldIndex = frozen.firstIndex(where: { $0.book.id == item.book.id }),
              let newIndex = order.firstIndex(where: { $0.book.id == item.book.id })
        else { return 0 }
        return slotMid(bookIndex: newIndex, bookCount: order.count)
            - slotMid(bookIndex: oldIndex, bookCount: frozen.count)
    }

    /// 换位 = 改「哪个槽位放哪本书」，槽位本身不动（广告固定占第 3 个显示位，跨它时步长自动变大）。
    /// 阈值与滞回见 [`HomeReorder.targetBookIndex`] / [`swapThresholdHysteresis`]。
    private func updateDrag(_ item: HomeBookUi, translation: CGFloat) {
        guard let frozen = frozenOrder, let order = dragOrder,
              draggingId == item.book.id,
              let bookIndex = frozen.firstIndex(where: { $0.book.id == item.book.id }),
              let currentIndex = order.firstIndex(where: { $0.book.id == item.book.id })
        else { return }
        dragOffsetY += translation - lastDragTranslation
        lastDragTranslation = translation

        let target = HomeReorder.targetBookIndex(
            current: currentIndex,
            fromBookIndex: bookIndex,
            bookCount: frozen.count,
            mids: slotMids,
            hasAd: adPresent,
            offsetY: dragOffsetY,
            hysteresis: Self.swapThresholdHysteresis,
        )
        guard target != currentIndex else { return }
        // 让位动画：只有换位这一帧的槽位变化动画化；被拖行的位移始终即时（bookRow 的 transaction 覆写）
        withAnimation(.easeInOut(duration: 0.18)) {
            dragOrder = HomeReorder.moved(order, from: currentIndex, to: target)
        }
    }

    private func endDrag() {
        guard let order = dragOrder, draggingId != nil else {
            resetDrag()
            return
        }
        // 松手落位：布局切到视觉顺序 + 位移归零，两者同帧、同曲线动画，且位移量正好等于槽位差——
        // 于是让位过的行原地不动，被拖行从手指位置平滑滑进目标槽位。
        withAnimation(.easeOut(duration: 0.18)) {
            draggingId = nil
            dragOffsetY = 0
            frozenOrder = nil
            dragOrder = nil
            localOrder = order
        }
        lastDragTranslation = 0
        Task {
            try? await repository.updateBookSortOrder(order.map(\.book.id) + finished.map(\.book.id))
            await reloadBooks()
            // 落库回灌完成后交回仓库顺序（避免闪回旧顺序）
            localOrder = nil
        }
    }

    private func resetDrag() {
        draggingId = nil
        dragOffsetY = 0
        lastDragTranslation = 0
        frozenOrder = nil
        dragOrder = nil
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
