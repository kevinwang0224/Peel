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
