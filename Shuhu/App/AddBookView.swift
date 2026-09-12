import SwiftUI

/// 添加书籍表单：标题/作者/总页数必填；起止日期可选（计划）。
/// 日期校验与 Android 同源（validateBookDates：两个都填或都不填、结束不早于开始）。
struct AddBookView: View {
    /// 保存动作由调用方注入（表单只负责产出 NewBook）。
    let onSave: (_ draft: NewBook) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var author = ""
    @State private var totalPagesText = ""
    @State private var hasPlan = false
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var dateError: BookDateError?

    var body: some View {
        NavigationStack {
            Form {
                Section("书籍信息") {
                    TextField("书名", text: $title)
                    TextField("作者", text: $author)
                    TextField("总页数", text: $totalPagesText)
                        .keyboardType(.numberPad)
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
            .navigationTitle("添加书籍")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(!inputValid)
                }
            }
        }
        .presentationDetents([.large])
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
        do {
            try await onSave(NewBook(
                title: title.trimmingCharacters(in: .whitespaces),
                author: author.trimmingCharacters(in: .whitespaces),
                totalPages: parsedTotalPages ?? 0,
                startDate: start,
                endDate: end,
            ))
            dismiss()
        } catch {
            dateError = nil
        }
    }

    private func message(of error: BookDateError) -> String {
        switch error {
        case .singleDateOnly: "计划需要同时设置开始与结束日期"
        case .endBeforeStart: "结束日期不能早于开始日期"
        }
    }
}

/// `Date`（本地时区）→ `CalendarDay`（用户视角日历日）。
private extension CalendarDay {
    init(date: Date, timeZone: TimeZone = .current) {
        self = CalendarDay.today(now: date, timeZone: timeZone)
    }
}
