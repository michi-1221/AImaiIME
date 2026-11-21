import XCTest
@testable import AIMECore

/// 変換キーの書式を解析する（解析できなければテストを失敗にする）。
func ck(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> ConvertKey {
    try XCTUnwrap(ConvertKey.parse(text), "変換キー \(text) を解析できない", file: file, line: line)
}
