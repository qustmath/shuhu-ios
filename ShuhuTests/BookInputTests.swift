import Foundation
import XCTest
@testable import Shuhu

/// 书籍表单校验测试：镜像 Android `BookInputTest`。
final class BookInputTests: XCTestCase {

    func testValidInput() {
        XCTAssertNil(validateBookInput(title: "Go语言第一课", totalPages: 293))
    }

    func testBlankTitle_rejected() {
        XCTAssertEqual(validateBookInput(title: "  ", totalPages: 100), .titleRequired)
        XCTAssertEqual(validateBookInput(title: "", totalPages: 100), .titleRequired)
        XCTAssertEqual(BookFieldError.titleRequired.message, "请填写书名")
    }

    func testInvalidTotalPages_rejected() {
        XCTAssertEqual(validateBookInput(title: "书", totalPages: nil), .totalPagesInvalid)
        XCTAssertEqual(validateBookInput(title: "书", totalPages: 0), .totalPagesInvalid)
        XCTAssertEqual(validateBookInput(title: "书", totalPages: -3), .totalPagesInvalid)
        XCTAssertEqual(BookFieldError.totalPagesInvalid.message, "页数需为大于 0 的整数")
    }
}
