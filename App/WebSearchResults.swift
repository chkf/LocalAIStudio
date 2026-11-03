import Foundation
import SwiftSoup

/// Parse only organic search results; never treat a challenge or a changed page layout as evidence.
enum WebSearchResults {
    static func parse(_ data: Data) throws -> WebToolResult {
        let doc = try SwiftSoup.parseHTML(data, "https://html.duckduckgo.com/")
        if try !doc.select("#challenge-form, #anomaly-modal, .anomaly-modal").isEmpty() {
            throw WebToolError.invalid("搜索网站要求验证，请稍后重试或直接提供网页链接。")
        }
        var sources: [WebSource] = []
        for result in try doc.select(".result").array() {
            guard let anchor = try result.select("a.result__a").first() else { continue }
            let href = try anchor.attr("href")
            guard let link = URL(string: href, relativeTo: URL(string: "https://html.duckduckgo.com/"))?.absoluteURL else { continue }
            var destination = link.absoluteString
            if ["duckduckgo.com", "html.duckduckgo.com"].contains(link.host?.lowercased() ?? ""), ["/l", "/l/"].contains(link.path) {
                guard let target = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "uddg" })?.value else { continue }
                destination = target
            }
            guard let url = try? WebURLPolicy.url(destination), !sources.contains(where: { $0.url == url }) else { continue }
            let title = try anchor.text()
            let snippet = try result.select(".result__snippet").text()
            sources.append(WebSource(title: String(title.prefix(160)), url: url, excerpt: String(snippet.prefix(400))))
            if sources.count == 5 { break }
        }
        guard !sources.isEmpty else {
            let noResults = try !doc.select(".no-results, .no-results__message").isEmpty()
            throw WebToolError.invalid(noResults ? "没有找到相关网页，请换一组关键词。" : "未能获取搜索结果，搜索网站可能限制了访问或页面已变化。可以稍后重试或直接提供链接。")
        }
        return WebToolResult(tool: "web_search", sources: sources, error: nil)
    }
}
