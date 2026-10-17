import XCTest

@testable import PeelCore

final class JSONDocumentTests: XCTestCase {
  func testFormattingNullDoesNotEraseTheDocument() throws {
    XCTAssertEqual(try JSONDocument.format("null", compact: false), "null")
  }
  func testFormatterPreservesLargeNumbersAndPropertyOrder() throws {
    let input = "{\"z\":9007199254740993,\"2\":-0,\"a\":1.20e+3}"
    XCTAssertEqual(
      try JSONDocument.format(input),
      "{\n  \"z\": 9007199254740993,\n  \"2\": -0,\n  \"a\": 1.20e+3\n}")
  }
  func testNestedFormattingAndCompactRoundTrip() throws {
    let input = "{\"items\":[{},[],true,false,null,\"a\\n中文😀\"]}"
    XCTAssertEqual(try JSONDocument.format(JSONDocument.format(input), compact: true), input)
    let summary = try JSONDocument.summary(input)
    XCTAssertEqual(summary.keyCount, 1)
    XCTAssertEqual(summary.rootType, "Object")
  }
  func testRejectsCommentsTrailingCommasAndMalformedNumbers() {
    for text in [
      "{/*comment*/}", "[1,]", "{\"a\":1,}", "01", "1.", "1e", "NaN", "{\"a\":\"\\q\"}", "\"a\n\"",
    ] {
      XCTAssertThrowsError(try JSONDocument.summary(text), text)
    }
  }
  func testErrorLocationUsesUTF8ForEditorAndUTF16ForColumn() {
    XCTAssertThrowsError(try JSONDocument.summary("{\"😀\":1 x}")) { error in
      let issue = error as? JSONIssue
      XCTAssertEqual(issue?.byteOffset, 10)
      XCTAssertEqual(issue?.column, 9)
      XCTAssertEqual(issue?.line, 1)
    }
  }
  func testPastedStringWrappedAndEscapedObjectsAreUnwrapped() {
    XCTAssertEqual(JSONDocument.pasted("\"{\\\"a\\\":1}\""), "{\n  \"a\": 1\n}")
    XCTAssertEqual(JSONDocument.pasted("{\\\"a\\\":1}"), "{\n  \"a\": 1\n}")
    XCTAssertEqual(JSONDocument.pasted("hello"), "hello")
    XCTAssertEqual(JSONDocument.pasted("\"hello\""), "\"hello\"")
  }
  func testDeepInputFailsWithAnIssueInsteadOfOverflowingStack() {
    let input = String(repeating: "[", count: 600) + "0" + String(repeating: "]", count: 600)
    XCTAssertThrowsError(try JSONDocument.summary(input))
  }
}
