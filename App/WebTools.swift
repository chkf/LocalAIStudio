import Darwin
import Foundation
import SwiftSoup

private final class NoWebRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor WebTools {
    func execute(_ call: WebToolCall) async throws -> WebToolResult {
        do {
            switch call.tool {
            case .web_search: return try await search(call.query!)
            case .read_webpage: return try await read(call.url!)
            case .answer: return WebToolResult(tool: "answer", sources: [], error: nil)
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch {
            return WebToolResult(tool: call.tool.rawValue, sources: [], error: error.localizedDescription)
        }
    }

    private func search(_ query: String) async throws -> WebToolResult {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let (data, _) = try await fetch(URLRequest(url: components.url!), redirects: true)
        return try WebSearchResults.parse(data)
    }

    private func read(_ rawURL: String) async throws -> WebToolResult {
        let request = URLRequest(url: try WebURLPolicy.url(rawURL))
        let (data, response) = try await fetch(request, redirects: true)
        guard let finalURL = response.url else { throw WebToolError.invalid("网页地址不可用。") }
        let type = response.mimeType?.lowercased() ?? ""
        guard ["text/html", "application/xhtml+xml", "text/plain"].contains(type) else {
            throw WebToolError.invalid("目前只读取 HTML 和纯文本网页；PDF、图片和其他文件尚不支持。")
        }
        let html = String(decoding: data, as: UTF8.self)
        let title: String
        let body: String
        if type == "text/plain" {
            title = finalURL.host ?? "网页"
            body = html
        } else {
            let doc = try SwiftSoup.parseHTML(data, finalURL.absoluteString)
            title = try doc.title()
            try doc.select("script,style,noscript,iframe,nav,footer,header,form,svg").remove()
            let content = try doc.select("article,main,[role=main]").first() ?? doc.body()
            body = try content?.text() ?? ""
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebToolError.invalid("网页没有可提取的正文，可能需要登录或 JavaScript。")
        }
        return WebToolResult(tool: "read_webpage", sources: [WebSource(
            title: String((title.isEmpty ? finalURL.host ?? "网页" : title).prefix(160)),
            url: finalURL, excerpt: String(body.prefix(2_500)))], error: nil)
    }

    /// No cookies, browser login, credential storage or JavaScript. Redirects are checked individually.
    private func fetch(_ initial: URLRequest, redirects: Bool) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        let session = URLSession(configuration: config, delegate: NoWebRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = initial
        request.setValue("AIStudio/0.5 (web reader)", forHTTPHeaderField: "User-Agent")
        for _ in 0..<5 {
            try Task.checkCancellation()
            let url = try WebURLPolicy.url(request.url?.absoluteString ?? "")
            try Self.checkPublicHost(url.host!)
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw WebToolError.invalid("网页响应无效。") }
            if (300...399).contains(http.statusCode), redirects,
               let location = http.value(forHTTPHeaderField: "Location"),
               let next = URL(string: location, relativeTo: url)?.absoluteURL {
                _ = try WebURLPolicy.url(next.absoluteString)
                // Discard the response and cancel its body before following a redirect.
                bytes.task.cancel()
                request = URLRequest(url: next)
                continue
            }
            guard (200...299).contains(http.statusCode) else {
                throw WebToolError.invalid("网络服务返回 HTTP \(http.statusCode)。搜索服务可能暂时限制访问，请稍后重试或直接提供网页链接。")
            }
            let limit = 1_024 * 1_024
            guard http.expectedContentLength <= Int64(limit) else { throw WebToolError.invalid("网页超过 1 MiB 读取限制。") }
            var data = Data()
            for try await byte in bytes {
                if data.count % 4096 == 0 { try Task.checkCancellation() }
                guard data.count < limit else { throw WebToolError.invalid("网页超过 1 MiB 读取限制。") }
                data.append(byte)
            }
            return (data, http)
        }
        throw WebToolError.invalid("网页重定向次数过多。")
    }

    private static func checkPublicHost(_ host: String) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else {
            throw WebToolError.invalid("无法解析网页域名。")
        }
        defer { freeaddrinfo(first) }
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let entry = current {
            let address = entry.pointee
            var allowed = false
            if address.ai_family == AF_INET, let pointer = address.ai_addr {
                let ipv4 = UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr_in.self).pointee
                let value = UInt32(bigEndian: ipv4.sin_addr.s_addr)
                allowed = WebURLPolicy.isPublicIPv4(value)
            } else if address.ai_family == AF_INET6, let pointer = address.ai_addr {
                var ipv6 = UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                allowed = withUnsafeBytes(of: &ipv6) { WebURLPolicy.isPublicIPv6(Array($0)) }
            }
            guard allowed else { throw WebToolError.invalid("网页域名指向本机或非公开网络，已拒绝访问。") }
            current = address.ai_next
        }
    }
}
