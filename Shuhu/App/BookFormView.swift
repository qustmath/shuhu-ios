import SwiftUI
import PhotosUI

/// 书籍表单（odui 发丝线表单行，标签左/输入右，对齐 Android `BookFormScreen`）：
/// book 为 nil = 添加；非 nil = 编辑（右上可删）。书名衬线大字（像题在扉页上），
/// 页数与日期等宽右对齐，结束日期自动带计划时长。
/// 封面：相册（PhotosPicker）或拍照二选一，字节暂存草稿，保存时才落盘；
/// 更换/移除成功后清理不再引用的旧文件，避免垃圾文件堆积。
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
    @State private var startDate: CalendarDay?
    @State private var endDate: CalendarDay?
    @State private var error: String?

    @State private var coverDraft: CoverDraft?
    @State private var coverRemoved = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showDeleteConfirm = false
    @State private var pickingStartDate = false
    @State private var pickingEndDate = false
    @State private var pickedDate = Date()
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

    private var isEditMode: Bool { book != nil }
    private var formTitle: String { isEditMode ? "编辑阅读计划" : "添加书籍" }

    /// 是否有封面可显示：新选的草稿优先，其次原封面（未被移除）。
    private var hasCover: Bool {
        coverDraft != nil || (book?.coverImagePath != nil && !coverRemoved)
    }

    var body: some View {
        VStack(spacing: 0) {
            PaperTopBar(title: formTitle, onBack: { dismiss() }) {
                if isEditMode {
                    CircleHairlineButton(systemName: "trash", iconSize: 17) {
                        showDeleteConfirm = true
                    }
                }
            }

            ScrollView {
                VStack(spacing: 0) {
                    PaperPageHead(
                        kicker: isEditMode ? "EDIT BOOK" : "NEW BOOK",
                        title: formTitle,
                        titleSize: 30,
                    )
                    .padding(.bottom, -10)

                    HairlineRule()
                    BookFormRow(label: "书名", required: true, text: $title, hint: "请输入书名", serifTitle: true)
                    BookFormRow(label: "作者", text: $author, hint: "选填")
                    BookFormRow(label: "页数", required: true, text: $totalPagesText, hint: "请输入总页数", mono: true, keyboard: .numberPad)
                        .onChange(of: totalPagesText) { _, v in
                            let digits = String(v.filter(\.isNumber).prefix(6))
                            if digits != v { totalPagesText = digits }
                        }
                    DateRow(label: "开始日期", value: startDate) {
                        pickedDate = (startDate ?? CalendarDay.today()).toDate()
                        pickingStartDate = true
                    } onClear: {
                        startDate = nil
                    }
                    DateRow(
                        label: "结束日期",
                        value: endDate,
                        suffix: startDate != nil && endDate != nil
                            ? "（\(ReadingPlan.planDurationDays(start: startDate!, end: endDate!)) 天）"
                            : "",
                    ) {
                        pickedDate = (endDate ?? CalendarDay.today()).toDate()
                        pickingEndDate = true
                    } onClear: {
                        endDate = nil
                    }
                    CoverRow(
                        hasCover: hasCover,
                        draftImage: coverDraft.flatMap { UIImage(data: $0.bytes) },
                        fallbackPath: coverRemoved ? nil : book?.coverImagePath,
                        fallbackTitle: title,
                        onRemove: {
                            coverDraft = nil
                            coverRemoved = true
                        },
                        onPickCamera: { showCamera = true },
                        photoSelection: $photoItem,
                    )

                    // 只填一个日期的实时提示（两个都填或都不填才构成计划）
                    if (startDate == nil) != (endDate == nil) {
                        Text("如需设置阅读计划，请同时填写开始和结束日期")
                            .font(.system(size: 13))
                            .foregroundStyle(Paper.ochre)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 14)
                    }
                    if let error {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(Paper.ochre)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 4)
                    }
                }
            }
            .scrollIndicators(.hidden)

            HairlineRule()
            PaperPrimaryButton(text: "保 存", isEnabled: !saving) {
                Task { await save() }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .background(Paper.bg.ignoresSafeArea())
        .sheet(isPresented: $showCamera) {
            CameraPicker { bytes, ext in
                coverDraft = CoverDraft(bytes: bytes, fileExtension: ext)
                coverRemoved = false
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $pickingStartDate) {
            datePickerSheet { day in startDate = day; error = nil }
        }
        .sheet(isPresented: $pickingEndDate) {
            datePickerSheet { day in endDate = day; error = nil }
        }
        .onChange(of: photoItem) { _, item in
            Task { await loadPhoto(item) }
        }
        .alert("删除这本书？", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                Task { await deleteBook() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将同时删除它的全部阅读记录和封面，且不可恢复。")
        }
        .alert("保存失败", isPresented: .init(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
        .task { prefill() }
    }

    // ---- 日期选择弹层 ----

    private func datePickerSheet(onConfirm: @escaping (CalendarDay?) -> Void) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") {
                    pickingStartDate = false
                    pickingEndDate = false
                }
                .foregroundStyle(Paper.inkMuted)
                Spacer()
                Button("确定") {
                    onConfirm(CalendarDay(date: pickedDate))
                    pickingStartDate = false
                    pickingEndDate = false
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

    // ---- 表单 ----

    private func prefill() {
        guard let book else { return }
        title = book.title
        author = book.author
        totalPagesText = String(book.totalPages)
        startDate = book.startDate
        endDate = book.endDate
    }

    private var parsedTotalPages: Int? {
        Int(totalPagesText.trimmingCharacters(in: .whitespaces))
    }

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        if let data = try? await item.loadTransferable(type: Data.self) {
            coverDraft = CoverDraft(bytes: data, fileExtension: ext)
            coverRemoved = false
        }
        photoItem = nil
    }

    private func save() async {
        if let fieldError = validateBookInput(title: title, totalPages: parsedTotalPages) {
            error = fieldError.message
            return
        }
        switch validateBookDates(start: startDate, end: endDate) {
        case .singleDateOnly:
            error = "请同时填写开始和结束日期，或都不填"
            return
        case .endBeforeStart:
            error = "结束日期不能早于开始日期"
            return
        case nil:
            break
        }
        error = nil
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
                updated.startDate = startDate
                updated.endDate = endDate
                updated.coverImagePath = newCoverPath
                try await repository.updateBook(updated)
            } else {
                _ = try await repository.addBook(NewBook(
                    title: title.trimmingCharacters(in: .whitespaces),
                    author: author.trimmingCharacters(in: .whitespaces),
                    totalPages: parsedTotalPages ?? 1,
                    startDate: startDate,
                    endDate: endDate,
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

    private func deleteBook() async {
        guard let book else { return }
        do {
            try await repository.deleteBook(id: book.id)
            await onSaved()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

// MARK: - 表单行

/// 文本/数字表单行：标签左（必填赭红星号）、输入右对齐，下缘发丝线。
private struct BookFormRow: View {
    let label: String
    var required = false
    @Binding var text: String
    let hint: String
    var serifTitle = false
    var mono = false
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                HStack(spacing: 0) {
                    Text(label)
                        .font(.system(size: 14))
                        .foregroundStyle(Paper.inkMuted)
                    if required {
                        Text(" *")
                            .font(.system(size: 14))
                            .foregroundStyle(Paper.ochre)
                    }
                }
                TextField("", text: $text, prompt: Text(hint).font(.system(size: 15)).foregroundColor(Paper.inkMuted.opacity(0.7)))
                    .font(inputFont)
                    .foregroundStyle(Paper.ink)
                    .tint(Paper.ochre)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(keyboard)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            HairlineRule()
        }
    }

    private var inputFont: Font {
        if serifTitle { return .paperSerif(19, weight: .bold) }
        if mono { return .paperMono(16) }
        return .system(size: 17)
    }
}

/// 日期行：标签 + 等宽日期值（+计划时长）+ 清除，下缘发丝线。
private struct DateRow: View {
    let label: String
    let value: CalendarDay?
    var suffix = ""
    let onPick: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 14))
                    .foregroundStyle(Paper.inkMuted)
                Spacer()
                Button(action: onPick) {
                    if let value {
                        Text("\(suffix)\(DateFormats.planDate(value))")
                            .font(.paperMono(16))
                            .foregroundStyle(Paper.ink)
                    } else {
                        Text("请选择")
                            .font(.system(size: 15))
                            .foregroundStyle(Paper.inkMuted)
                    }
                }
                .buttonStyle(.plain)
                if value != nil {
                    Button(action: onClear) {
                        Text("✕")
                            .font(.system(size: 14))
                            .foregroundStyle(Paper.inkMuted)
                            .padding(.leading, 12)
                            .padding(.trailing, 2)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 28)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            HairlineRule()
        }
    }
}

/// 封面行：封面本体（移除角标）+ 提示 + 相册/拍照双格操作条，下缘发丝线。
private struct CoverRow: View {
    let hasCover: Bool
    let draftImage: UIImage?
    let fallbackPath: String?
    let fallbackTitle: String
    let onRemove: () -> Void
    let onPickCamera: () -> Void
    @Binding var photoSelection: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Text("封面图")
                    .font(.system(size: 14))
                    .foregroundStyle(Paper.inkMuted)
                    .padding(.top, 4)
                HStack(alignment: .bottom, spacing: 18) {
                    ZStack(alignment: .topTrailing) {
                        if hasCover {
                            coverPreview
                            // 移除：封面右上外侧徽章（探出图片一半，不压图）
                            Button(action: onRemove) {
                                Text("✕")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white)
                                    .frame(width: 24, height: 24)
                                    .background(Paper.inkMuted.opacity(0.62), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .offset(x: 12, y: -12)
                        } else {
                            // 占位
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Paper.inkMuted.opacity(0.45), lineWidth: 1)
                                .frame(width: 84, height: 122)
                                .overlay(
                                    Text("无封面")
                                        .font(.system(size: 12))
                                        .tracking(1)
                                        .foregroundStyle(Paper.inkMuted),
                                )
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("建议竖版书封，相册选取或现场拍照均可")
                            .font(.system(size: 12))
                            .lineSpacing(6)
                            .foregroundStyle(Paper.inkMuted)
                        // 双格操作条：发丝线外框 + 中缝分隔
                        HStack(spacing: 0) {
                            PhotosPicker(selection: $photoSelection, matching: .images) {
                                CoverAction(label: "相册", systemName: "photo.on.rectangle")
                            }
                            Rectangle().fill(Paper.hairline).frame(width: 1, height: 48)
                            Button(action: onPickCamera) {
                                CoverAction(label: "拍照", systemName: "camera")
                            }
                            .buttonStyle(.plain)
                        }
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Paper.hairline, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            HairlineRule()
        }
    }

    @ViewBuilder
    private var coverPreview: some View {
        if let draftImage {
            Image(uiImage: draftImage)
                .resizable()
                .scaledToFill()
                .frame(width: 84, height: 122)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            CoverImageView(path: fallbackPath, title: fallbackTitle, width: 84, height: 122)
        }
    }
}

private struct CoverAction: View {
    let label: String
    let systemName: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 17))
                .foregroundStyle(Paper.ink)
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(Paper.ink)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .contentShape(Rectangle())
    }
}
