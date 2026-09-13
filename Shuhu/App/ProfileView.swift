import SwiftUI

/// 「我」页（设置）：应用名与版本 + 两项统计 + 法律条款入口（Android `ProfileScreen` 镜像）。
/// 账号与同步区随同步引擎一并加入。
struct ProfileView: View {
    private let repository: any LibraryRepository

    @State private var finishedBooks = 0
    @State private var totalPagesRead: Int64 = 0
    @State private var loadError: String?

    @Environment(\.openURL) private var openURL

    init(repository: any LibraryRepository) {
        self.repository = repository
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("书乎")
                        .font(.headline)
                    Text("v\(appVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                statRow(label: "已读完", value: "\(finishedBooks)", unit: "本")
                statRow(label: "累计阅读", value: "\(totalPagesRead)", unit: "页")
            }
            Section {
                legalRow("用户协议", urlString: LegalPages.terms)
                legalRow("隐私政策", urlString: LegalPages.privacy)
            }
            Section {
                Text("所有数据仅保存在这台设备上")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .alert("出错了", isPresented: .init(get: { loadError != nil }, set: { if !$0 { loadError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(loadError ?? "")
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private func statRow(label: String, value: String, unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.body.bold())
                .foregroundStyle(.purple)
            Text(unit)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func legalRow(_ label: String, urlString: String) -> some View {
        Button {
            if let url = URL(string: urlString) {
                openURL(url)
            }
        } label: {
            HStack {
                Text(label)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func reload() async {
        do {
            let books = try await repository.books()
            let records = try await repository.allRecords()
            finishedBooks = ReadingStats.finishedBookCount(books: books, records: records)
            totalPagesRead = ReadingStats.totalPagesRead(records: records)
        } catch {
            loadError = error.localizedDescription
        }
    }
}
