import XCTest

@testable import PeelCore

final class ExpressionCompletionTests: XCTestCase {
  private let document = """
    {"name":"peel","items":[{"id":1,"title":"a","user-id":3,"tags":["x"]}],
     "meta":{"total":2,"page":1,"ok":true},"count":5,"1st":0}
    """
  private func complete(_ text: String, root: String = "data", javascript: Bool = true) -> [String] {
    guard let site = ExpressionCompletion.site(in: text, root: root),
      let value = ExpressionCompletion.parse(document)
    else { return [] }
    return ExpressionCompletion.candidates(for: site, in: value, javascript: javascript)
  }

  func testRootObjectKeysAreSuggestedAfterDot() {
    XCTAssertEqual(complete("data."), ["count", "items", "meta", "name"])
  }
  func testPrefixFiltersCaseInsensitively() {
    XCTAssertEqual(complete("data.N"), ["name"])
    XCTAssertEqual(complete("data.m"), ["meta"])
  }
  func testNestedPathsAndArrayIndexes() {
    XCTAssertEqual(complete("data.meta."), ["ok", "page", "total"])
    XCTAssertEqual(complete("data.items[0]."), ["id", "tags", "title"])
    XCTAssertEqual(complete("data[\"items\"][0].ti"), ["title"])
    XCTAssertEqual(complete("data.items?.[0]."), [])
  }
  func testKeysThatAreNotIdentifiersAreSkipped() {
    XCTAssertFalse(complete("data.items[0].").contains("user-id"))
    XCTAssertFalse(complete("data.").contains("1st"))
  }
  func testBuiltInMembersByType() {
    XCTAssertTrue(complete("data.items.").contains("map"))
    XCTAssertFalse(complete("data.items.").contains("sort"))
    XCTAssertTrue(complete("data.name.").contains("toUpperCase"))
    XCTAssertTrue(complete("data.count.").contains("toFixed"))
    XCTAssertEqual(complete("data.meta.ok."), [])
    XCTAssertEqual(complete("data.items.", javascript: false), [])
  }
  func testExpressionContextAroundTheChain() {
    XCTAssertEqual(complete("data.items.map(x => data.meta."), ["ok", "page", "total"])
    XCTAssertEqual(complete("return data\n  .meta\n  ."), ["ok", "page", "total"])
    XCTAssertEqual(complete("data.meta?."), ["ok", "page", "total"])
  }
  func testNonCompletionPositionsReturnNil() {
    XCTAssertNil(ExpressionCompletion.site(in: "other.", root: "data"))
    XCTAssertNil(ExpressionCompletion.site(in: "mydata.", root: "data"))
    XCTAssertNil(ExpressionCompletion.site(in: "x.data.", root: "data"))
    XCTAssertNil(ExpressionCompletion.site(in: "data.items.sort(x => x.", root: "data"))
    XCTAssertNil(ExpressionCompletion.site(in: "data.items.reduce((acc, x) => acc.", root: "data"))
    XCTAssertNil(ExpressionCompletion.site(in: "x.", root: "data"))
    XCTAssertNil(ExpressionCompletion.site(in: "d", root: "data"))
    XCTAssertNil(ExpressionCompletion.site(in: "data[a].", root: "data"))
    XCTAssertNil(ExpressionCompletion.site(in: "1.5.", root: "data"))
  }
  func testMissingOrMistypedPathsGiveNothing() {
    XCTAssertEqual(complete("data.nope."), [])
    XCTAssertEqual(complete("data.items[9]."), [])
    XCTAssertEqual(complete("data.name.first."), [])
  }
  func testJSONPathRoot() {
    XCTAssertEqual(complete("$.meta.", root: "$", javascript: false), ["ok", "page", "total"])
    XCTAssertEqual(complete("$.items[0].ti", root: "$", javascript: false), ["title"])
    XCTAssertEqual(complete("$..meta.", root: "$", javascript: false), [])
  }
  func testSitePrefixIsExposedForTheEditor() {
    XCTAssertEqual(ExpressionCompletion.site(in: "data.items.fi", root: "data")?.prefix, "fi")
    XCTAssertEqual(ExpressionCompletion.site(in: "data.", root: "data")?.prefix, "")
  }
  func testOversizedDocumentsAreNotParsed() {
    let padding = String(repeating: "a", count: ExpressionCompletion.maxDocumentBytes)
    XCTAssertNil(ExpressionCompletion.parse("\"\(padding)\""))
    XCTAssertNil(ExpressionCompletion.parse("{broken"))
  }

  func testCallbackParametersResolveToArrayElements() {
    let keys = ["id", "tags", "title"]
    XCTAssertEqual(complete("data.items.map(x => x."), keys)
    XCTAssertEqual(complete("data.items.filter((x, i) => x.ti"), ["title"])
    XCTAssertEqual(complete("data.items.find(function_ => 1) && data.items.some(it => it."), keys)
    XCTAssertEqual(complete("data.items.reduce((acc, x) => x."), keys)
    XCTAssertEqual(complete("data.items.toSorted((a, b) => b."), keys)
    XCTAssertEqual(complete("data.items?.map(x => x."), keys)
  }
  func testCallbackParametersNest() {
    XCTAssertTrue(complete("data.items.map(x => x.tags.map(t => t.")
      .contains("toUpperCase"))
    XCTAssertEqual(complete("data.items.map(x => x.tags.map(t => x."), ["id", "tags", "title"])
    XCTAssertEqual(complete("data.items.map(x => data.meta."), ["ok", "page", "total"])
  }
  func testCallbackParameterOutOfScopeIsUnknown() {
    XCTAssertEqual(complete("data.items.map(x => 1); x."), [])
    XCTAssertEqual(complete("data.items.map(x => x.id).filter(y => y.").contains("toFixed"), true)
  }
  func testArrayElementsAreMerged() {
    let site = ExpressionCompletion.site(in: "data.rows.map(r => r.", root: "data")!
    let rows: Any = [["a": 1], ["b": 2], ["a": 3, "c": 4]]
    XCTAssertEqual(
      ExpressionCompletion.candidates(for: site, in: ["rows": rows], javascript: true),
      ["a", "b", "c"])
  }
  func testSubscriptOffersEveryKeyQuoted() {
    XCTAssertEqual(
      complete("data.items[0]["), ["\"id\"", "\"tags\"", "\"title\"", "\"user-id\""])
    XCTAssertEqual(ExpressionCompletion.site(in: "data[", root: "data")?.kind, .bracketKey)
    XCTAssertEqual(complete("data.items["), [])
  }
  func testQuotedKeysAreOfferedRawAndFiltered() {
    XCTAssertEqual(complete("data.items[0][\"user"), ["user-id"])
    XCTAssertEqual(complete("data.items[0]['"), ["id", "tags", "title", "user-id"])
    let site = ExpressionCompletion.site(in: "data.items[0][\"user-", root: "data")
    XCTAssertEqual(site?.kind, .quotedKey(quote: "\""))
    XCTAssertEqual(site?.prefix, "user-")
    XCTAssertNil(ExpressionCompletion.site(in: "foo(\"x", root: "data").map { $0.kind == .root ? nil : $0 } ?? nil)
  }
  func testRootNameIsCompletedInJavaScriptOnly() {
    XCTAssertEqual(complete("da"), ["data"])
    XCTAssertEqual(complete("return DA"), ["data"])
    XCTAssertEqual(complete("data"), [])
    XCTAssertEqual(complete("da", javascript: false), [])
    XCTAssertEqual(complete("xy"), [])
  }

  func testChainsFollowArrayMethods() {
    let keys = ["id", "tags", "title"]
    XCTAssertEqual(complete("data.items.filter(x => x.id).slice(0, 2)[0]."), keys)
    XCTAssertEqual(complete("data.items.find(x => x.id)."), keys)
    XCTAssertEqual(complete("data.items.at(0)."), keys)
    XCTAssertEqual(complete("data.items.filter(x => x.id).map(y => y.ti"), ["title"])
    XCTAssertTrue(complete("data.items.filter(x => x.id).").contains("map"))
    XCTAssertEqual(complete("data.items.map(x => x.id)[0]."), complete("data.count."))
  }
  func testMapWithPathBodyChangesElementType() {
    XCTAssertTrue(complete("data.items.map(x => x.title).").contains("map"))
    XCTAssertTrue(complete("data.items.map(x => x.title).filter(t => t.").contains("toUpperCase"))
    XCTAssertTrue(complete("data.items.map(x => x.id).filter(n => n.").contains("toFixed"))
    XCTAssertEqual(complete("data.items.map(x => x.tags).map(t => t.").count > 0, true)
    XCTAssertEqual(complete("data.items.map(x => x.title.length)[0]."), complete("data.count."))
  }
  func testMapWithOtherBodyIsAnUnknownArray() {
    XCTAssertTrue(complete("data.items.map(x => ({ a: x.id })).").contains("filter"))
    XCTAssertEqual(complete("data.items.map(x => ({ a: x.id })).map(y => y."), [])
    XCTAssertEqual(complete("data.items.map(x => x.id + 1)[0]."), [])
  }
  func testStringAndNumberMethodResults() {
    XCTAssertTrue(complete("data.name.toUpperCase().").contains("trim"))
    XCTAssertTrue(complete("data.name.split(\"a\").").contains("map"))
    XCTAssertTrue(complete("data.count.toFixed(2).").contains("padStart"))
    XCTAssertEqual(complete("data.name.includes(\"a\")."), [])
    XCTAssertTrue(complete("data.name.length.").contains("toFixed"))
    XCTAssertTrue(complete("data.items.length.").contains("toFixed"))
  }
  func testUnknownOrBareCallsGiveNothing() {
    XCTAssertEqual(complete("data.items.reduce((a, b) => a).x."), [])
    XCTAssertEqual(complete("data.items.nope()."), [])
    XCTAssertNil(ExpressionCompletion.site(in: "foo(1).", root: "data"))
    XCTAssertNil(ExpressionCompletion.site(in: "(data.items).", root: "data"))
  }
  func testDestructuredParameters() {
    XCTAssertTrue(complete("data.items.map(({ id, title }) => title.").contains("toUpperCase"))
    XCTAssertTrue(complete("data.items.map(({ id, title: t }, i) => t.").contains("trim"))
    XCTAssertTrue(complete("data.items.map(({ id }) => id.").contains("toFixed"))
    XCTAssertEqual(complete("data.items.map(({ tags }) => tags.").contains("filter"), true)
    XCTAssertEqual(complete("data.items.map(({ id }) => title."), [])
    XCTAssertEqual(complete("data.items.map(({ id }, { title }) => title."), [])
  }
}
