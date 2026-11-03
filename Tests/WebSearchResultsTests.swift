import XCTest
@testable import LocalAIStudio

final class WebSearchResultsTests: XCTestCase {
    func testExtractsRedirectDestinationAndSnippet() throws {
        let html = """
        <div class="result"><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa">Example</a>
        <span class="result__snippet">A useful snippet</span></div>
        """
        let result = try WebSearchResults.parse(Data(html.utf8))
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.sources[0].url.absoluteString, "https://example.com/a")
        XCTAssertEqual(result.sources[0].excerpt, "A useful snippet")
    }

    func testChallengeOrChangedLayoutCannotBecomeEvidence() {
        for html in ["<form id='challenge-form'></form>", "<html>Changed layout</html>", "<div class='no-results'></div>"] {
            XCTAssertThrowsError(try WebSearchResults.parse(Data(html.utf8)))
        }
    }

    func testLocalResultsAreRejectedAndDuplicatesRemoved() throws {
        let html = ["https://localhost/", "https://example.com/a", "https://example.com/a"].map {
            "<div class='result'><a class='result__a' href='\($0)'>Title</a></div>"
        }.joined()
        let result = try WebSearchResults.parse(Data(html.utf8))
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.sources[0].url.host, "example.com")
    }
}
