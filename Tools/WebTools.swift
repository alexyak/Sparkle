import Foundation
import PDFKit

// MARK: - Web tools

/// Searches the web via DuckDuckGo's HTML endpoint (no API key required).
struct WebSearchTool: Tool {
    var name = "web_search"
    var isParallelSafe: Bool { true }
    var description = "Search the web and return the top results with titles, URLs, and snippets. Use for current events, facts, or anything not in your training data."
    var parameters: [String: AnyCodableValue] = [
        "type": .string("object"),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("Search query")
            ]),
            "num_results": .object([
                "type": .string("integer"),
                "description": .string("Number of results to return (1–10, default 8)")
            ]),
            "site": .object([
                "type": .string("string"),
                "description": .string("Restrict results to this domain, e.g. \"bestbuy.com\"")
            ]),
            "recency": .object([
                "type": .string("string"),
                "enum": .array(["day", "week", "month", "year"].map { .string($0) }),
                "description": .string("Only results from the last day/week/month/year")
            ])
        ]),
        "required": .array([.string("query")])
    ]

    func execute(arguments: String) async -> String {
        struct Args: Decodable {
            let query: String
            let num_results: Int?
            let site: String?
            let recency: String?
        }
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return "Error: invalid arguments"
        }
        var query = args.query
        if let site = args.site?.trimmingCharacters(in: .whitespaces), !site.isEmpty {
            query += " site:\(site)"
        }
        var urlString = "https://html.duckduckgo.com/html/?q="
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return "Error: invalid arguments"
        }
        urlString += encoded
        // DuckDuckGo's date filter: d / w / m / y.
        if let recency = args.recency,
           let code = ["day": "d", "week": "w", "month": "m", "year": "y"][recency] {
            urlString += "&df=\(code)"
        }
        guard let url = URL(string: urlString) else {
            return "Error: invalid arguments"
        }
        let limit = min(max(args.num_results ?? 8, 1), 10)
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else {
                return "Error: could not decode search results"
            }
            return SearchHTMLParser.parse(html, limit: limit, query: args.query)
        } catch {
            return "Error: search request failed — \(error.localizedDescription)"
        }
    }
}

/// Fetches a URL and returns readable text content.
struct WebFetchTool: Tool {
    var name = "web_fetch"
    var isParallelSafe: Bool { true }
    var description = "Fetch a web page or PDF by URL and return its readable text content. Use after web_search to read a promising result."
    var parameters: [String: AnyCodableValue] = [
        "type": .string("object"),
        "properties": .object([
            "url": .object([
                "type": .string("string"),
                "description": .string("Full URL to fetch (must include http:// or https://)")
            ]),
            "max_chars": .object([
                "type": .string("integer"),
                "description": .string("Max characters of text to return (500–40000, default 12000)")
            ]),
            "offset": .object([
                "type": .string("integer"),
                "description": .string("Character offset to start from, for reading later parts of a long page")
            ]),
            "find": .object([
                "type": .string("string"),
                "description": .string("Optional keyword: start the returned text at its first occurrence (e.g. \"price\"), skipping earlier content")
            ]),
            "selector": .object([
                "type": .string("string"),
                "description": .string("Optional: return only this part of the page. A tag name (\"main\", \"article\"), \"#id\" or \".class\". Applied before text extraction.")
            ])
        ]),
        "required": .array([.string("url")])
    ]

    func execute(arguments: String) async -> String {
        struct Args: Decodable {
            let url: String
            let max_chars: Int?
            let offset: Int?
            let find: String?
            let selector: String?
        }
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data),
              let url = URL(string: args.url),
              url.scheme == "http" || url.scheme == "https" else {
            return "Error: invalid arguments — provide a full http(s) URL"
        }
        // Reddit serves HTML to browsers behind bot checks, but documents its
        // public .json endpoints for programmatic use with a descriptive
        // User-Agent. Use that instead of impersonating a browser.
        let redditURL = Self.redditJSONURL(for: url)
        var request = URLRequest(url: redditURL ?? url)
        request.setValue(redditURL != nil
                         ? "ios:com.dgxchat.app:v1.0 (personal assistant app)"
                         : "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X)",
                         forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let maxChars = min(max(args.max_chars ?? 12_000, 500), 40_000)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return "Error: unexpected response"
            }
            guard (200..<400).contains(http.statusCode) else {
                if redditURL != nil, http.statusCode == 403 || http.statusCode == 429 {
                    let retry = http.value(forHTTPHeaderField: "Retry-After").map { " Retry after \($0)s." } ?? ""
                    return "Error: Reddit refused the request (\(http.statusCode)) — it is rate limiting or blocking this network.\(retry) Don't retry immediately; try a web_search result from another source instead."
                }
                return "Error: server returned \(http.statusCode)"
            }
            if redditURL != nil,
               let obj = try? JSONSerialization.jsonObject(with: data),
               let text = RedditFormatter.format(obj), !text.isEmpty {
                return Self.window(text, offset: args.offset, find: args.find, maxChars: maxChars)
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            if contentType.contains("application/json") {
                // Pretty-print JSON responses.
                if let obj = try? JSONSerialization.jsonObject(with: data),
                   let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
                   let text = String(data: pretty, encoding: .utf8) {
                    return Self.window(text, offset: args.offset, find: args.find, maxChars: maxChars)
                }
            }
            // PDFs are binary: extract their text layer with PDFKit. Also sniff the
            // "%PDF" magic bytes, since some servers send a generic content type.
            if contentType.contains("application/pdf") || data.starts(with: Data("%PDF".utf8)) {
                guard let document = PDFDocument(data: data) else {
                    return "Error: could not open PDF"
                }
                let text = (document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    return "PDF fetched (\(document.pageCount) pages) but it has no extractable text (likely a scanned image)."
                }
                return Self.window(text, offset: args.offset, find: args.find, maxChars: maxChars)
            }
            guard let raw = String(data: data, encoding: .utf8) else {
                return "Error: binary or undecodable content (\(contentType))"
            }
            var source = raw
            if let selector = args.selector, !selector.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let element = HTMLTextExtractor.element(matching: selector, in: raw) else {
                    return "Error: selector '\(selector)' matched nothing. Use a tag name, #id or .class, or omit it. (Client-rendered pages may not contain the element at all.)"
                }
                source = element
            }
            let text = HTMLTextExtractor.text(from: source)
            if text.isEmpty {
                return "Page fetched but no readable text found."
            }
            var output = Self.window(text, offset: args.offset, find: args.find, maxChars: maxChars)
            // List the page's real image URLs (first read only) so the model can
            // embed them instead of guessing addresses.
            if (args.offset ?? 0) == 0 {
                let images = HTMLTextExtractor.images(in: source,
                                                      metaFrom: args.selector == nil ? raw : nil,
                                                      base: http.url ?? url)
                if !images.isEmpty {
                    output += "\n\nImages on this page (show one with ![description](url) on its own line):\n"
                    output += images.map { "- \($0.url.absoluteString)" + ($0.alt.isEmpty ? "" : " — \($0.alt)") }
                        .joined(separator: "\n")
                }
            }
            return output
        } catch {
            return "Error: fetch failed — \(error.localizedDescription)"
        }
    }

    /// Returns the `.json` form of a reddit.com page URL, or nil for other hosts
    /// (and for redd.it short links, which redirect to the full page anyway).
    private static func redditJSONURL(for url: URL) -> URL? {
        guard let host = url.host?.lowercased(),
              host == "reddit.com" || host.hasSuffix(".reddit.com"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix(".json") { path += ".json" }
        components.path = path.hasPrefix("/") ? path : "/" + path
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "raw_json" }) {
            items.append(URLQueryItem(name: "raw_json", value: "1"))
        }
        components.queryItems = items
        return components.url
    }

    /// Slices `text` to the requested window and appends a footer telling the
    /// model how much is left and which offset continues the read.
    private static func window(_ text: String, offset: Int?, find: String?, maxChars: Int) -> String {
        var start = max(offset ?? 0, 0)
        if offset == nil, let find, !find.isEmpty,
           let hit = text.range(of: find, options: .caseInsensitive) {
            start = text.distance(from: text.startIndex, to: hit.lowerBound)
        }
        guard start < text.count else {
            return "Error: offset \(start) is past the end of the page (\(text.count) characters)."
        }
        let from = text.index(text.startIndex, offsetBy: start)
        let slice = String(text[from...].prefix(maxChars))
        let end = start + slice.count
        var footer = "\n\n[characters \(start)–\(end) of \(text.count)"
        footer += end < text.count ? "; pass offset=\(end) to continue]" : "; end of page]"
        return slice + footer
    }
}

// MARK: - Reddit

/// Flattens Reddit's listing JSON (subreddit listings, post + comment trees)
/// into readable text with indentation for reply depth.
enum RedditFormatter {
    static func format(_ root: Any) -> String? {
        var lines: [String] = []
        if let pair = root as? [Any] {
            // Post page: [post listing, comment listing].
            for listing in pair { append(listing: listing, depth: 0, into: &lines) }
        } else {
            append(listing: root, depth: 0, into: &lines)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func append(listing: Any, depth: Int, into lines: inout [String]) {
        guard let dict = listing as? [String: Any],
              let data = dict["data"] as? [String: Any],
              let children = data["children"] as? [[String: Any]] else { return }
        for child in children {
            guard let kind = child["kind"] as? String,
                  let d = child["data"] as? [String: Any] else { continue }
            let indent = String(repeating: "  ", count: depth)
            switch kind {
            case "t3": // post
                let title = d["title"] as? String ?? ""
                let author = d["author"] as? String ?? "[deleted]"
                let sub = d["subreddit_name_prefixed"] as? String ?? ""
                let score = d["score"] as? Int ?? 0
                let comments = d["num_comments"] as? Int ?? 0
                lines.append("\(indent)## \(title)")
                lines.append("\(indent)\(sub) · u/\(author) · \(score) points · \(comments) comments")
                if let body = d["selftext"] as? String, !body.isEmpty { lines.append(indent + body) }
                else if let link = d["url"] as? String { lines.append("\(indent)Link: \(link)") }
                lines.append("")
            case "t1": // comment
                let author = d["author"] as? String ?? "[deleted]"
                let score = d["score"] as? Int ?? 0
                let body = (d["body"] as? String ?? "").replacingOccurrences(of: "\n", with: "\n" + indent + "  ")
                lines.append("\(indent)- u/\(author) (\(score)): \(body)")
                if let replies = d["replies"], !(replies is String) {
                    append(listing: replies, depth: depth + 1, into: &lines)
                }
            default: // "more" stubs etc.
                continue
            }
        }
    }
}

// MARK: - HTML helpers

/// Extracts readable text from HTML, dropping scripts/styles/tags.
enum HTMLTextExtractor {
    static func text(from html: String) -> String {
        var text = html
        // Drop script/style/head blocks.
        text = removingBlock(text, "script")
        text = removingBlock(text, "style")
        text = removingBlock(text, "head")
        text = removingBlock(text, "noscript")
        text = removingBlock(text, "svg")
        // Site chrome: navigation, headers/footers, sidebars, forms.
        for tag in ["nav", "header", "footer", "aside", "form"] {
            text = removingBlock(text, tag)
        }
        // Convert block-ish tags to newlines.
        for tag in ["p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "section", "article"] {
            text = text.replacingOccurrences(of: "<\(tag)", with: "\n<\(tag)", options: .caseInsensitive)
        }
        // Strip remaining tags.
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: .caseInsensitive) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        // Decode common entities.
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–", "&rsquo;": "'", "&lsquo;": "'", "&rdquo;": "\"", "&ldquo;": "\"", "&hellip;": "…"]
        for (entity, char) in entities {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        // Collapse whitespace.
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    /// Content images on a page: the `og:image` (when `metaFrom` is given) first,
    /// then `<img>` sources, resolved against `base`. Lazy-load attributes win over
    /// placeholder `src` values. Skips data URIs, SVGs, tiny images and obvious
    /// site chrome (icons, logos, sprites, tracking pixels).
    static func images(in html: String, metaFrom meta: String? = nil, base: URL,
                       limit: Int = 12) -> [(url: URL, alt: String)] {
        var found: [(url: URL, alt: String)] = []
        var seen = Set<String>()

        func add(_ rawValue: String?, alt: String = "") {
            guard found.count < limit, let rawValue else { return }
            let value = rawValue.replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.lowercased().hasPrefix("data:"),
                  let url = URL(string: value, relativeTo: base)?.absoluteURL,
                  url.scheme == "http" || url.scheme == "https" else { return }
            let lowered = url.absoluteString.lowercased()
            let path = url.path.lowercased()
            let chrome = ["icon", "logo", "sprite", "pixel", "spacer", "blank", "badge",
                          "/static/images/", "/api/rest_v1/media/math"]
            guard !path.hasSuffix(".svg"), !chrome.contains(where: { lowered.contains($0) }),
                  seen.insert(url.absoluteString).inserted else { return }
            found.append((url, alt.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        func attribute(_ name: String, in tag: String) -> String? {
            let pattern = "(?<![\\w-])\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
            for group in 1...2 {
                if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) }
            }
            return nil
        }

        func tags(_ name: String, in text: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: "<\(name)\\b[^>]*>", options: .caseInsensitive) else { return [] }
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range, in: text).map { String(text[$0]) }
            }
        }

        if let meta {
            for tag in tags("meta", in: meta) {
                let key = (attribute("property", in: tag) ?? attribute("name", in: tag) ?? "").lowercased()
                if key == "og:image" || key == "og:image:url" { add(attribute("content", in: tag)) }
            }
        }
        for tag in tags("img", in: html) {
            // Declared sizes under 50px are icons or spacers.
            let width = attribute("width", in: tag).flatMap { Int($0) }
            let height = attribute("height", in: tag).flatMap { Int($0) }
            if let width, width < 50 { continue }
            if let height, height < 50 { continue }
            let source = attribute("data-src", in: tag) ?? attribute("data-original", in: tag) ?? attribute("src", in: tag)
            add(source, alt: attribute("alt", in: tag) ?? "")
        }
        return found
    }

    /// Returns the outer HTML of the first element matching a simple selector
    /// (`tag`, `#id` or `.class`), balancing nested elements of the same tag.
    static func element(matching selector: String, in html: String) -> String? {
        let sel = selector.trimmingCharacters(in: .whitespaces)
        guard !sel.isEmpty else { return nil }
        let tagName = "[a-zA-Z][a-zA-Z0-9]*"
        let pattern: String
        if sel.hasPrefix("#") {
            let id = NSRegularExpression.escapedPattern(for: String(sel.dropFirst()))
            pattern = "<(\(tagName))\\b[^>]*\\bid\\s*=\\s*[\"']\(id)[\"'][^>]*>"
        } else if sel.hasPrefix(".") {
            let cls = NSRegularExpression.escapedPattern(for: String(sel.dropFirst()))
            pattern = "<(\(tagName))\\b[^>]*\\bclass\\s*=\\s*[\"'][^\"']*\\b\(cls)\\b[^\"']*[\"'][^>]*>"
        } else {
            pattern = "<(\(NSRegularExpression.escapedPattern(for: sel)))\\b[^>]*>"
        }
        let fullRange = NSRange(html.startIndex..., in: html)
        guard let open = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let first = open.firstMatch(in: html, range: fullRange),
              let nameRange = Range(first.range(at: 1), in: html),
              let startRange = Range(first.range, in: html) else { return nil }
        let name = NSRegularExpression.escapedPattern(for: String(html[nameRange]))

        // Walk open/close tags of the same name until the first one closes.
        guard let scan = try? NSRegularExpression(pattern: "<(/?)\(name)\\b[^>]*>", options: .caseInsensitive) else { return nil }
        let tail = NSRange(startRange.upperBound..., in: html)
        var depth = 1
        for match in scan.matches(in: html, range: tail) {
            guard let whole = Range(match.range, in: html) else { continue }
            if match.range(at: 1).length > 0 {
                depth -= 1
            } else if !html[whole].hasSuffix("/>") {
                depth += 1
            }
            if depth == 0 { return String(html[startRange.lowerBound..<whole.upperBound]) }
        }
        // Never closed (sloppy HTML): take everything after the opening tag.
        return String(html[startRange.lowerBound...])
    }

    private static func removingBlock(_ text: String, _ tag: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "<\(tag)[^>]*>.*?</\(tag)>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
}

/// Parses DuckDuckGo HTML search results into a compact list.
enum SearchHTMLParser {
    /// Output starts with a `status:` line — `ok`, `weak_results` (few hits, or
    /// most don't mention the query terms) or `no_results` — so the caller can
    /// tell an empty search from a poor one.
    static func parse(_ html: String, limit: Int = 8, query: String = "") -> String {
        var results: [(url: String, title: String, snippet: String)] = []
        // Result links: <a rel="nofollow" class="result__a" href="...">title</a>
        guard let linkRegex = try? NSRegularExpression(
            pattern: "class=\"result__a\"[^>]*href=\"([^\"]*)\"[^>]*>(.*?)</a>",
            options: [.dotMatchesLineSeparators]) else {
            return "No results found."
        }
        let range = NSRange(html.startIndex..., in: html)
        let matches = linkRegex.matches(in: html, range: range)
        for match in matches.prefix(limit) {
            guard let urlRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else { continue }
            var url = String(html[urlRange])
            // DuckDuckGo wraps URLs in a redirect: //duckduckgo.com/l/?uddg=<encoded>
            if let components = URLComponents(string: "https:" + url),
               let encoded = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
               let decoded = encoded.removingPercentEncoding,
               let resolved = URL(string: decoded) {
                url = resolved.absoluteString
            }
            let title = stripTags(String(html[titleRange]))
            results.append((url: url, title: title, snippet: ""))
        }
        // Snippets: <a class="result__snippet" ...>text</a>
        var snippets: [String] = []
        if let snippetRegex = try? NSRegularExpression(
            pattern: "class=\"result__snippet\"[^>]*>(.*?)</a>",
            options: [.dotMatchesLineSeparators]) {
            for match in snippetRegex.matches(in: html, range: range) {
                if let r = Range(match.range(at: 1), in: html) {
                    snippets.append(stripTags(String(html[r])))
                }
            }
        }
        if results.isEmpty {
            return "status: no_results\nNo results found. Try fewer or broader keywords, or drop the site/recency filter."
        }
        let body = results.enumerated().map { index, result in
            let snippet = index < snippets.count ? "\n  \(snippets[index])" : ""
            return "\(index + 1). \(result.title)\n  \(result.url)\(snippet)"
        }.joined(separator: "\n\n")

        // Weak: fewer than 3 hits, or under a third mention any query term.
        // `site:` operators are not content terms.
        let terms = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && $0 != "site" }
        var relevant = 0
        for (index, result) in results.enumerated() {
            let snippet = index < snippets.count ? snippets[index] : ""
            let haystack = (result.title + " " + snippet).lowercased()
            if terms.contains(where: { haystack.contains($0) }) { relevant += 1 }
        }
        let isWeak = results.count < 3 || (!terms.isEmpty && relevant * 3 < results.count)
        let status = isWeak
            ? "status: weak_results (\(results.count) hits, \(relevant) mention the query terms) — consider rephrasing"
            : "status: ok (\(results.count) results)"
        return status + "\n\n" + body
    }

    private static func stripTags(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
