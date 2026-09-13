import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// 书籍表单：新增与编辑共用（Android `BookFormScreen` 镜像）。
/// 封面：相册（PhotosPicker）或拍照二选一入口，字节暂存草稿，保存时才落盘；
/// 更换/移除成功后清理不再引用的旧文件，避免垃圾文件堆积。日期校验与 Android 同源。
struct BookFormView: View {
    private let repository: any LibraryRepository
    /// nil = 新增模式。
    private let book: Book?
    /// 保存成功回调（调用方刷新列表）。
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var author = ""
    @State private var totalPagesText = ""
    @State private var hasPlan = false
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var dateError: BookDateError?

    @State private var coverDraft: CoverDraft?
    @State private var coverRemoved = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var saving = false
    @State private var saveError: String?

    /// 选好但尚未落盘的封面草稿。
    struct CoverDraft: Equatable {
        let bytes: Data
        let fileExtension: String
    }

    init(repository: any LibraryRepository, book: Book? = nil, onSaved: @escaping () async -> Void) {
        self.repository = repository
        self.book = book
        self.onSaved = onSaved
    }

    /// 是否有封面可显示：新选的草稿优先，其次原封面（未被移除）。
    private var hasCover: Bool {
        coverDraft != nil || (book?.coverImagePath != nil && !coverRemoved)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("书籍信息") {
                    TextField("书名", text: $title)
                    TextField("作者", text: $author)
                    TextField("总页数", text: $totalPagesText)
                        .keyboardType(.numberPad)
                }
                Section("封面图") {
                    HStack(alignment: .top, spacing: 16) {
                        coverPreview
                        Spacer()
                        VStack(alignment: .trailing, spacing: 12) {
                            PhotosPicker(selection: $photoItem, matching: .images) {
                                Label("相册", systemImage: "photo.on.rectangle")
                            }
                            Button {
                                showCamera = true
                            } label: {
                                Label("拍照", systemImage: "camera")
                            }
                            if hasCover {
                                Button(role: .destructive) {
                                    coverDraft = nil
                                    coverRemoved = true
                                } label: {
                                    Label("移除", systemImage: "xmark.circle")
                                }
                            }
                        }
                        .font(.subheadline)
                    }
                    .padding(.vertical, 2)
                }
                Section {
                    Toggle("设置阅读计划", isOn: $hasPlan.animation())
                    if hasPlan {
                        DatePicker("开始日期", selection: $startDate, displayedComponents: .date)
                        DatePicker("结束日期", selection: $endDate, displayedComponents: .date)
                        if let dateError {
                            Text(message(of: dateError))
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle(book == nil ? "添加书籍" : "编辑书籍")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(!inputValid || saving)
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker { bytes, ext in
                    coverDraft = CoverDraft(bytes: bytes, fileExtension: ext)
                    coverRemoved = false
                }
                .ignoresSafeArea()
            }
            .onChange(of: photoItem) { newValue in
                Task { await loadPhoto(newValue) }
            }
            .alert("保存失败", isPresented: .init(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
            .task { prefill() }
        }
        .presentationDetents([.large])
    }

    // ---- 封面 ----

    @ViewBuilder
    private var coverPreview: some View {
        if let draft = coverDraft, let image = UIImage(data: draft.bytes) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 92, height: 124)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if let path = book?.coverImagePath, !coverRemoved {
            CoverImageView(path: path, width: 92, height: 124)
        } else {
            ZStack {
                Rectangle()
                    .fill(Color.purple.opacity(0.12))
                Text("无封面")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 92, height: 124)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        if let data = try? await item.loadTransferable(type: Data.self) {
            coverDraft = CoverDraft(bytes: data, fileExtension: ext)
            coverRemoved = false
        }
    }

    // ---- 表单 ----

    private func prefill() {
        guard let book else { return }
        title = book.title
        author = book.author
        totalPagesText = String(book.totalPages)
        hasPlan = book.startDate != nil && book.endDate != nil
        startDate = (book.startDate ?? CalendarDay.today()).toDate()
        endDate = (book.endDate ?? CalendarDay.today()).toDate()
    }

    private var parsedTotalPages: Int? {
        Int(totalPagesText.trimmingCharacters(in: .whitespaces))
    }

    private var inputValid: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty,
              let pages = parsedTotalPages, pages > 0
        else { return false }
        if hasPlan, validateBookDates(start: CalendarDay(date: startDate), end: CalendarDay(date: endDate)) != nil {
            return false
        }
        return true
    }

    private func save() async {
        let start = hasPlan ? CalendarDay(date: startDate) : nil
        let end = hasPlan ? CalendarDay(date: endDate) : nil
        if let error = validateBookDates(start: start, end: end) {
            dateError = error
            return
        }
        saving = true
        defer { saving = false }
        do {
            let oldPath = book?.coverImagePath
            var newCoverPath: String? = book?.coverImagePath
            if coverRemoved {
                newCoverPath = nil
            } else if let draft = coverDraft {
                // 新文件先落盘拿路径（失败则整单不保存，旧文件不受影响）
                newCoverPath = try await repository.saveCoverImage(bytes: draft.bytes, fileExtension: draft.fileExtension)
            }
            if let book {
                var updated = book
                updated.title = title.trimmingCharacters(in: .whitespaces)
                updated.author = author.trimmingCharacters(in: .whitespaces)
                updated.totalPages = parsedTotalPages ?? book.totalPages
                updated.startDate = start
                updated.endDate = end
                updated.coverImagePath = newCoverPath
                try await repository.updateBook(updated)
            } else {
                _ = try await repository.addBook(NewBook(
                    title: title.trimmingCharacters(in: .whitespaces),
                    author: author.trimmingCharacters(in: .whitespaces),
                    totalPages: parsedTotalPages ?? 0,
                    startDate: start,
                    endDate: end,
                    coverImagePath: newCoverPath,
                ))
            }
            // 旧封面不再被引用时清理（新文件已写、路径已换之后）
            if let oldPath, oldPath != newCoverPath {
                try await repository.deleteCoverFile(path: oldPath)
            }
            await onSaved()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func message(of error: BookDateError) -> String {
        switch error {
        case .singleDateOnly: "计划需要同时设置开始与结束日期"
        case .endBeforeStart: "结束日期不能早于开始日期"
        }
    }
}

/// `Date`（本地时区）→ `CalendarDay`（用户视角日历日）；反向用于 DatePicker 回填。
private extension CalendarDay {
    init(date: Date, timeZone: TimeZone = .current) {
        self = CalendarDay.today(now: date, timeZone: timeZone)
    }

    func toDate(timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }
}
