import PhotosUI
import SwiftUI

/// 待上传的截图（选图时已压缩为 JPEG 字节；id 供列表增删定位）。
struct PendingFeedbackImage: Identifiable, Equatable {
    let id: Int64
    let jpeg: Data
}

/// 建议与反馈页（对齐 Android `FeedbackScreen`；feedback mod，ADR-0008）：
/// 类型单选 + 纯文本正文 + ≤3 张截图 + 可选联系方式，下方「我的反馈」展示官方回复。
/// 会员登录后可用（服务端 MemberAuth）；每次打开 sheet 均重新拉取历史（官方回复随时可能发生）。
struct FeedbackView: View {
    private let client: FeedbackClient
    private let toast: ToastCenter
    private let onClose: () -> Void

    @State private var type = FeedbackType.suggestion
    @State private var content = ""
    @State private var contact = ""
    @State private var pendingImages: [PendingFeedbackImage] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var submitting = false

    @State private var history: [FeedbackItemData]?
    @State private var historyFailed = false
    @State private var historyLoading = false
    @State private var nextImageID: Int64 = 1

    init(client: FeedbackClient, toast: ToastCenter, onClose: @escaping () -> Void) {
        self.client = client
        self.toast = toast
        self.onClose = onClose
    }

    private var canSubmit: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !submitting
    }

    var body: some View {
        VStack(spacing: 0) {
            PaperTopBar(title: "建议与反馈", onBack: onClose)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PaperPageHead(
                        kicker: "FEEDBACK",
                        title: "建议与反馈",
                        sub: "遇到问题，或想让书乎变得更好？写给我们。",
                    )

                    SectionKicker(text: "类型 · TYPE")
                        .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 8)
                    HStack(spacing: 10) {
                        ForEach(typeOptions, id: \.0) { value, label in
                            typeChip(label: label, selected: value == type) {
                                type = value
                            }
                        }
                    }
                    .padding(.horizontal, 22)

                    SectionKicker(text: "内容 · CONTENT")
                        .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 8)
                    contentField

                    contactRow

                    SectionKicker(text: "截图 · SCREENSHOTS（选填，最多 3 张）")
                        .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 8)
                    imageRow

                    SectionKicker(text: "我的反馈 · HISTORY")
                        .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 8)
                    historySection
                }
            }

            bottomBar
        }
        .background(Paper.bg.ignoresSafeArea())
        // sheet 层级高于根视图挂载的 ToastOverlay，页内提示需自挂一份
        .overlay { ToastOverlay(center: toast) }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPickedImages(items) }
            pickerItems = []
        }
        .task { await refreshHistory() }
    }

    private let typeOptions: [(String, String)] = [
        (FeedbackType.suggestion, "建议"),
        (FeedbackType.bug, "问题"),
        (FeedbackType.other, "其他"),
    ]

    // ---- 表单区 ----

    private func typeChip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(selected ? Paper.bg : Paper.inkMuted)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(
                    (selected ? Paper.ink : Color.clear),
                    in: RoundedRectangle(cornerRadius: 4),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(selected ? Paper.ink : Paper.hairline, lineWidth: 1),
                )
        }
        .buttonStyle(.plain)
    }

    private var contentField: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Paper.hairline, lineWidth: 1)
                if content.isEmpty {
                    Text("说说你的建议，或遇到的问题…")
                        .font(.system(size: 15))
                        .foregroundStyle(Paper.inkMuted.opacity(0.7))
                        .padding(12)
                }
                TextField("", text: $content, axis: .vertical)
                    .font(.system(size: 15))
                    .foregroundStyle(Paper.ink)
                    .lineLimit(4...8)
                    .padding(12)
                    .onChange(of: content) { _, value in
                        if value.count > FeedbackLimits.content {
                            content = String(value.prefix(FeedbackLimits.content))
                        }
                    }
            }
            .frame(minHeight: 128)
            Text("\(content.count)/1000")
                .font(.paperMono(11))
                .foregroundStyle(Paper.inkMuted)
        }
        .padding(.horizontal, 22)
    }

    private var contactRow: some View {
        VStack(spacing: 0) {
            HStack {
                Text("联系方式")
                    .font(.system(size: 14))
                    .foregroundStyle(Paper.inkMuted)
                    .frame(width: 76, alignment: .leading)
                TextField("选填：邮箱 / 微信，便于回访", text: $contact)
                    .font(.system(size: 15))
                    .foregroundStyle(Paper.ink)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: contact) { _, value in
                        if value.count > FeedbackLimits.contact {
                            contact = String(value.prefix(FeedbackLimits.contact))
                        }
                    }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 15)
            HairlineRule()
        }
    }

    private var imageRow: some View {
        HStack(spacing: 10) {
            ForEach(pendingImages) { image in
                thumbnail(image)
            }
            if pendingImages.count < FeedbackLimits.images {
                PhotosPicker(
                    selection: $pickerItems,
                    maxSelectionCount: FeedbackLimits.images,
                    matching: .images,
                ) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Paper.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Paper.hairline, lineWidth: 1),
                        )
                        .frame(width: 72, height: 72)
                        .overlay {
                            Text("＋").font(.system(size: 22)).foregroundStyle(Paper.inkMuted)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 22)
    }

    private func thumbnail(_ image: PendingFeedbackImage) -> some View {
        ZStack(alignment: .topTrailing) {
            if let uiImage = UIImage(data: image.jpeg) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Paper.hairline, lineWidth: 1),
                    )
            }
            Text("×")
                .font(.system(size: 13))
                .foregroundStyle(Paper.bg)
                .frame(width: 18, height: 18)
                .background(Paper.ink.opacity(0.75), in: Circle())
                .padding(2)
                .onTapGesture {
                    pendingImages.removeAll { $0.id == image.id }
                }
        }
    }

    // ---- 我的反馈 ----

    @ViewBuilder
    private var historySection: some View {
        if history == nil && !historyFailed {
            Text("加载中…")
                .font(.system(size: 13))
                .foregroundStyle(Paper.inkMuted)
                .padding(.horizontal, 22).padding(.vertical, 8)
        } else if history == nil {
            Button {
                Task { await refreshHistory() }
            } label: {
                Text("反馈记录加载失败，点击重试")
                    .font(.system(size: 13))
                    .foregroundStyle(Paper.ink)
                    .padding(.horizontal, 22).padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        } else if history?.isEmpty != false {
            Text("还没有反馈记录")
                .font(.system(size: 13))
                .foregroundStyle(Paper.inkMuted)
                .padding(.horizontal, 22).padding(.vertical, 8)
        } else if let history {
            VStack(spacing: 0) {
                ForEach(Array(history.enumerated()), id: \.element.id) { index, item in
                    historyItem(item)
                    if index < history.count - 1 {
                        HairlineRule().padding(.horizontal, 22)
                    }
                }
            }
            Spacer().frame(height: 18)
        }
    }

    private func historyItem(_ item: FeedbackItemData) -> some View {
        let replied = item.status == FeedbackStatus.replied
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(FeedbackType.label(of: item.type))
                    .font(.paperMono(11))
                    .tracking(1)
                    .foregroundStyle(Paper.inkMuted)
                Spacer().frame(width: 8)
                Text(FeedbackStatus.label(of: item.status))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(replied ? Paper.ochre : Paper.inkMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(replied ? Paper.ochre : Paper.hairline, lineWidth: 1),
                    )
                Spacer()
                Text(item.createdAt ?? "")
                    .font(.paperMono(11))
                    .foregroundStyle(Paper.inkMuted)
            }
            Text(item.content ?? "")
                .font(.system(size: 14))
                .foregroundStyle(Paper.ink)
                .padding(.top, 6)
            if let images = item.images, !images.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(images.prefix(3).enumerated()), id: \.offset) { _, url in
                        AsyncImage(url: URL(string: url)) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Paper.surface
                            }
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Paper.hairline, lineWidth: 1),
                        )
                    }
                }
                .padding(.top, 8)
            }
            if let reply = item.reply, !reply.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("官方回复")
                        .font(.paperMono(11))
                        .tracking(1)
                        .foregroundStyle(Paper.ochre)
                    Text(reply)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Paper.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Paper.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    // ---- 底部提交条 ----

    private var bottomBar: some View {
        VStack(spacing: 0) {
            HairlineRule()
            PaperPrimaryButton(
                text: submitting ? "提交中…" : "提交反馈",
                isEnabled: canSubmit,
            ) {
                Task { await submit() }
            }
            .padding(.top, 12)
            Text("反馈以纯文本保存，每账号每天最多 5 条 · 官方回复在「我的反馈」查看")
                .font(.system(size: 12))
                .foregroundStyle(Paper.inkMuted)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 8)
        .background(Paper.bg)
    }

    // ---- 动作 ----

    /// 选图 → 压缩为 JPEG（最长边 2048 / 质量 0.85，对齐 Android ImageBytes 口径；
    /// 相册原图可能是 HEIC，服务端只收 jpg/png/gif/webp，必须重编码）。
    private func loadPickedImages(_ items: [PhotosPickerItem]) async {
        let slots = max(0, FeedbackLimits.images - pendingImages.count)
        var fresh: [PendingFeedbackImage] = []
        for item in items.prefix(slots) {
            guard let raw = try? await item.loadTransferable(type: Data.self),
                  let jpeg = Self.downsampleToJpeg(raw) else { continue }
            fresh.append(PendingFeedbackImage(id: nextImageID, jpeg: jpeg))
            nextImageID += 1
        }
        if !fresh.isEmpty {
            pendingImages = Array((pendingImages + fresh).prefix(FeedbackLimits.images))
        }
    }

    private static func downsampleToJpeg(
        _ data: Data,
        maxDimension: CGFloat = 2048,
        quality: CGFloat = 0.85,
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: quality)
    }

    /// 刷新「我的反馈」：每次打开页面都要拉（官方回复随时可能发生）。
    /// 已有旧数据时静默刷新不闪加载态；只有首次拉取失败才置失败态并提示。
    private func refreshHistory() async {
        guard !historyLoading else { return }
        historyLoading = true
        historyFailed = false
        defer { historyLoading = false }
        do {
            let data = try await client.myList(page: 1)
            history = data.list ?? []
        } catch {
            if history == nil {
                historyFailed = true
                toast.show(error.localizedDescription)
            }
        }
    }

    /// 提交反馈：先传截图再随单提交；成功清空表单并刷新列表，失败保留表单便于重试。
    private func submit() async {
        guard canSubmit, !submitting else { return }
        submitting = true
        defer { submitting = false }
        do {
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            var urls: [String] = []
            for image in pendingImages {
                urls.append(try await client.upload(bytes: image.jpeg, fileExtension: "jpg"))
            }
            try await client.submit(type: type, content: text, contact: contact.trimmingCharacters(in: .whitespaces), images: urls)
            content = ""
            contact = ""
            pendingImages = []
            toast.show("提交成功，感谢你的反馈")
            await refreshHistory()
        } catch {
            toast.show(error.localizedDescription)
        }
    }
}

/// 服务端约束（feedback mod）：正文 ≤1000 字、联系方式 ≤100、截图 ≤3 张。
private enum FeedbackLimits {
    static let content = 1000
    static let contact = 100
    static let images = 3
}
