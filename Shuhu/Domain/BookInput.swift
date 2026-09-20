import Foundation

/// 书籍表单校验错误（与 Android `BookFieldError` 对应）。
public enum BookFieldError: Equatable, Sendable {
    case titleRequired
    case totalPagesInvalid

    public var message: String {
        switch self {
        case .titleRequired: "请填写书名"
        case .totalPagesInvalid: "页数需为大于 0 的整数"
        }
    }
}

/// 校验书籍表单输入；返回 nil 表示合法（与 Android `validateBookInput` 同规则）。
public func validateBookInput(title: String, totalPages: Int?) -> BookFieldError? {
    if title.trimmingCharacters(in: .whitespaces).isEmpty { return .titleRequired }
    guard let totalPages, totalPages >= 1 else { return .totalPagesInvalid }
    return nil
}
