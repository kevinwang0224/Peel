import XCTest

@testable import PeelCore

final class ExtractionRunnerTests: XCTestCase {
  private var executable: URL {
    if let path = ProcessInfo.processInfo.environment["PEEL_SCRIPT_PATH"] {
      return URL(fileURLWithPath: path)
    }
    return Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("PeelScript")
  }
  func testJavaScriptExpressionReturnsStructuredResult() async throws {
    let runner = ExtractionRunner(executable: executable)
    let result = try await runner.run(
      ExtractionRequest(
        mode: .javascript, query: "data.items.map(x => x.id)", text: "{\"items\":[{\"id\":7}]}"))
    XCTAssertEqual(result.text, "[\n  7\n]")
    XCTAssertTrue(result.structured)
  }
  func testJSONStringResultsAreFormattedInBothModes() async throws {
    let runner = ExtractionRunner(executable: executable)
    for (mode, query) in [
      (ExtractionMode.javascript, "data.payload"),
      (.javascript, "Promise.resolve(data.payload)"),
      (.jsonpath, "$.payload"),
    ] {
      for (payload, expected) in [
        (#"{"name":"中文😀","items":[true,null]}"#,
          "{\n  \"name\": \"中文😀\",\n  \"items\": [\n    true,\n    null\n  ]\n}"),
        (#"[{"id":7},2,"hello"]"#, "[\n  {\n    \"id\": 7\n  },\n  2,\n  \"hello\"\n]"),
        ("{}", "{}"), ("[]", "[]"),
        (" \r\n\t{\"id\":7}\t\n ", "{\n  \"id\": 7\n}"),
      ] {
        let text = String(decoding: try JSONEncoder().encode(["payload": payload]), as: UTF8.self)
        let result = try await runner.run(ExtractionRequest(mode: mode, query: query, text: text))
        XCTAssertEqual(result.status, "success", "\(query): \(payload)")
        XCTAssertEqual(result.text, expected, "\(query): \(payload)")
        XCTAssertTrue(result.structured, "\(query): \(payload)")
      }
    }
  }
  func testJSONStringFormattingPreservesLargeNumbersAndPropertyOrder() async throws {
    let runner = ExtractionRunner(executable: executable)
    let payload = #"{"z":9007199254740993,"2":-0,"a":1.20e+3}"#
    let text = String(decoding: try JSONEncoder().encode(["payload": payload]), as: UTF8.self)
    let result = try await runner.run(
      ExtractionRequest(mode: .javascript, query: "data.payload", text: text))
    XCTAssertEqual(result.status, "success")
    XCTAssertEqual(
      result.text, "{\n  \"z\": 9007199254740993,\n  \"2\": -0,\n  \"a\": 1.20e+3\n}")
    XCTAssertTrue(result.structured)
  }
  func testNestedJSONStringsCanBeParsedAndExtractedWithJavaScript() async throws {
    let runner = ExtractionRunner(executable: executable)
    let text = #"""
      {"value":"{\"msg\":\"[{\\\"clazzId\\\":7,\\\"courseId\\\":8}]\",\"eventId\":\"event-1\"}"}
      """#
    let result = try await runner.run(
      ExtractionRequest(
        mode: .javascript, query: "JSON.parse(JSON.parse(data.value).msg)[0].clazzId", text: text))
    XCTAssertEqual(result.status, "success")
    XCTAssertEqual(result.text, "7")
  }
  func testNestedJSONStringsCanBeNavigatedInBothModes() async throws {
    let runner = ExtractionRunner(executable: executable)
    let text = #"""
      {"value":"{\"msg\":\"[{\\\"clazzId\\\":151938495,\\\"courseId\\\":266087487}]\",\"eventId\":\"event-1\"}"}
      """#
    for (mode, query, expected) in [
      (ExtractionMode.javascript, "data.value.msg[0].clazzId", "151938495"),
      (.jsonpath, "$.value.msg[0].clazzId", "151938495"),
      (.javascript, "data.value.msg.map(x => x.courseId)", "[\n  266087487\n]"),
      (.jsonpath, "$.value.msg[?(@.courseId > 0)].clazzId", "151938495"),
      (.javascript, "Promise.resolve(data.value.msg[0].clazzId)", "151938495"),
      (.javascript, "data.value === data.value && data.value.msg === data.value.msg", "true"),
    ] {
      let result = try await runner.run(ExtractionRequest(mode: mode, query: query, text: text))
      XCTAssertEqual(result.status, "success", query)
      XCTAssertEqual(result.text, expected, query)
    }
  }
  func testJSONStringsInsideArrayCallbacksAreNavigable() async throws {
    let runner = ExtractionRunner(executable: executable)
    let text = #"{"rows":["{\"payload\":\"{\\\"id\\\":7}\"}","{\"payload\":\"{\\\"id\\\":9}\"}"]}"#
    let result = try await runner.run(
      ExtractionRequest(mode: .javascript, query: "data.rows.map(x => x.payload.id)", text: text))
    XCTAssertEqual(result.status, "success")
    XCTAssertEqual(result.text, "[\n  7,\n  9\n]")
  }
  func testAutomaticallyDecodedInputCannotBeMutated() async throws {
    let runner = ExtractionRunner(executable: executable)
    let text = #"{"value":"{\"items\":\"[{\\\"id\\\":7}]\"}"}"#
    for query in [
      "(data.value.items[0].id = 0)", "data.value.items.push({id: 0})",
      "Object.defineProperty(data.value, 'added', {value: 0})",
    ] {
      let result = try await runner.run(
        ExtractionRequest(mode: .javascript, query: query, text: text))
      XCTAssertEqual(result.status, "error", query)
      XCTAssertFalse(result.text.isEmpty, query)
    }
  }
  func testReturningTheDocumentKeepsEncodedStringsIntact() async throws {
    let runner = ExtractionRunner(executable: executable)
    let text = #"{"value":"{\"items\":\"[{\\\"id\\\":7}]\"}"}"#
    let result = try await runner.run(
      ExtractionRequest(mode: .javascript, query: "data", text: text))
    XCTAssertEqual(result.status, "success")
    XCTAssertEqual(result.text, try JSONDocument.format(text))
  }
  func testStringsWithoutJSONStructuresArePreservedInBothModes() async throws {
    let runner = ExtractionRunner(executable: executable)
    for mode in ExtractionMode.allCases {
      let query = mode == .javascript ? "data.payload" : "$.payload"
      for payload in [
        "hello", "  hello\n", "", " \t\n", "null", "true", "42", #""hello""#,
        #"{"id":1,}"#, "[1,]", #"{"id":01}"#, #"{/* comment */}"#,
        #"{"id":1} extra"#, #"{\"id\":1}"#,
      ] {
        let text = String(decoding: try JSONEncoder().encode(["payload": payload]), as: UTF8.self)
        let result = try await runner.run(ExtractionRequest(mode: mode, query: query, text: text))
        XCTAssertEqual(result.status, "success", "\(mode): \(payload)")
        XCTAssertEqual(result.text, payload, "\(mode): \(payload)")
        XCTAssertFalse(result.structured, "\(mode): \(payload)")
      }
    }
  }
  func testJSONShapedErrorsAreNotFormatted() async throws {
    let runner = ExtractionRunner(executable: executable)
    let result = try await runner.run(
      ExtractionRequest(
        mode: .javascript, query: #"Promise.reject(Error('{"problem":1}'))"#, text: "{}"))
    XCTAssertEqual(result.status, "error")
    XCTAssertEqual(result.text, #"{"problem":1}"#)
    XCTAssertFalse(result.structured)
  }
  func testInfiniteLoopTimesOutAndNextEvaluationRecovers() async throws {
    let runner = ExtractionRunner(executable: executable)
    do {
      _ = try await runner.run(
        ExtractionRequest(mode: .javascript, query: "(() => { while (true) {} })()", text: "{}"),
        timeout: 0.5)
      XCTFail("An infinite loop must terminate")
    } catch { XCTAssertEqual(error as? ExtractionError, .timedOut) }
    let result = try await runner.run(
      ExtractionRequest(mode: .javascript, query: "data.answer", text: "{\"answer\":42}"))
    XCTAssertEqual(result.text, "42")
  }
}

extension ExtractionRunnerTests {
  func testJSONPathFilterSingleAndEmptyResults() async throws {
    let runner = ExtractionRunner(executable: executable)
    let text = "{\"items\":[{\"id\":7},{\"id\":9}]}"
    let filtered = try await runner.run(
      ExtractionRequest(mode: .jsonpath, query: "$.items[?(@.id > 7)].id", text: text))
    XCTAssertEqual(filtered.text, "9")
    let empty = try await runner.run(
      ExtractionRequest(mode: .jsonpath, query: "$.missing", text: text))
    XCTAssertEqual(empty.status, "empty")
  }
  func testPureJavaScriptPromiseAndSpecialResults() async throws {
    let runner = ExtractionRunner(executable: executable)
    let promised = try await runner.run(
      ExtractionRequest(mode: .javascript, query: "Promise.resolve(data.n + 1)", text: "{\"n\":4}"))
    XCTAssertEqual(promised.text, "5")
    for (query, expected) in [
      ("null", "null"), ("12n", "12n"), ("Symbol('x')", "Symbol(x)"),
      ("function extract() {}", "[Function: extract]"),
    ] {
      let result = try await runner.run(
        ExtractionRequest(mode: .javascript, query: query, text: "{}"))
      XCTAssertEqual(result.text, expected)
    }
  }
  func testCancellingInfiniteScriptAllowsNextRequestToRun() async throws {
    let runner = ExtractionRunner(executable: executable)
    let task = Task {
      try await runner.run(
        ExtractionRequest(mode: .javascript, query: "(() => { while (true) {} })()", text: "{}"),
        timeout: 10)
    }
    try await Task.sleep(for: .milliseconds(150))
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Cancelled script returned a result")
    } catch { XCTAssertTrue(error is CancellationError) }
    let result = try await runner.run(
      ExtractionRequest(mode: .javascript, query: "data.n", text: "{\"n\":8}"))
    XCTAssertEqual(result.text, "8")
  }
  func testScriptCannotMutateInputAndExceptionsAreDisplayed() async throws {
    let runner = ExtractionRunner(executable: executable)
    let result = try await runner.run(
      ExtractionRequest(mode: .javascript, query: "(data.n = 0)", text: "{\"n\":8}"))
    XCTAssertEqual(result.status, "error")
    XCTAssertFalse(result.text.isEmpty)
  }
  func testSerializationFailuresAndNullRejectionReturnErrorsWithoutTimingOut() async throws {
    let runner = ExtractionRunner(executable: executable)
    for query in [
      "({ n: 1n })", "(() => { const a = {}; a.self = a; return a })()", "Promise.reject(null)",
    ] {
      let result = try await runner.run(
        ExtractionRequest(mode: .javascript, query: query, text: "{}"))
      XCTAssertEqual(result.status, "error")
      XCTAssertFalse(result.text.isEmpty)
    }
  }
}
