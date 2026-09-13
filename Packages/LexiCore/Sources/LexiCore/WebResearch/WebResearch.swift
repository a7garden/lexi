import Foundation

// MARK: - 모델

/// 초안에 인용된 출처 하나.
public struct CitedSource: Sendable, Equatable {
    public var title: String
    public var url: URL?
    public var excerpt: String?

    public init(title: String, url: URL? = nil, excerpt: String? = nil) {
        self.title = title
        self.url = url
        self.excerpt = excerpt
    }
}

/// 웹 리서치로 만든 구조화 초안. `sources`가 비어 있으면 앱이 "출처 없는 AI 초안"으로 구분한다.
public struct DraftDefinition: Sendable, Equatable {
    public var oneLine: String
    public var easyExplanation: String
    public var examples: [String]
    public var sources: [CitedSource]

    public init(oneLine: String, easyExplanation: String, examples: [String], sources: [CitedSource]) {
        self.oneLine = oneLine
        self.easyExplanation = easyExplanation
        self.examples = examples
        self.sources = sources
    }
}

/// 검색 결과 한 건.
public struct SearchHit: Sendable, Equatable {
    public var title: String
    public var url: URL

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }
}

// MARK: - 프로토콜

/// 웹 검색 추상화. DuckDuckGo 외 다른 엔진으로 교체할 수 있다.
public protocol SearchProvider: Sendable {
    func search(_ query: String, limit: Int) async throws -> [SearchHit]
}

/// 웹 페이지 본문 가져오기 추상화.
public protocol PageFetching: Sendable {
    func fetch(_ url: URL) async throws -> String
}

// MARK: - DuckDuckGo 검색

/// html.duckduckgo.com의 HTML 결과를 긁어오는 검색 제공자.
///
/// - 결과 앵커(`result__a`)의 href를 파싱한다.
/// - `//duckduckgo.com/l/?uddg=<퍼센트 인코딩된 URL>&...` 리다이렉트 링크는
///   uddg 파라미터를 디코딩해 실제 URL로 복원한다.
public struct DuckDuckGoSearch: SearchProvider {
    private static let endpoint = URL(string: "https://html.duckduckgo.com/html/")!
    /// 일반 브라우저로 보이도록 하는 User-Agent.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    private static let anchorRegex = makeRegex(
        "<a\\b[^>]*\\bclass\\s*=\\s*[\"'][^\"']*result__a[^\"']*[\"'][^>]*>([\\s\\S]*?)</a\\s*>"
    )
    private static let hrefRegex = makeRegex("href\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')")

    private let session: URLSession

    public init() {
        self.session = .shared
    }

    public init(session: URLSession) {
        self.session = session
    }

    public func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        guard limit > 0 else { return [] }
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let requestURL = components?.url else {
            throw LLMProviderError.unreachable("검색 URL을 만들 수 없습니다")
        }
        var request = URLRequest(url: requestURL)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMProviderError.unreachable("검색 요청 실패: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode.description ?? "응답 없음"
            throw LLMProviderError.unreachable("검색 실패 (HTTP \(status))")
        }
        let hits = Self.parseHits(from: String(decoding: data, as: UTF8.self))
        return Array(hits.prefix(limit))
    }

    /// HTML에서 `result__a` 앵커의 제목·URL을 문서 순서대로 추출한다.
    static func parseHits(from html: String) -> [SearchHit] {
        var hits: [SearchHit] = []
        let wholeRange = NSRange(html.startIndex..., in: html)
        for match in anchorRegex.matches(in: html, options: [], range: wholeRange) {
            guard let anchorRange = Range(match.range, in: html) else { continue }
            let anchorHTML = String(html[anchorRange])
            guard let href = firstHref(in: anchorHTML).flatMap(resultURL(fromHref:)) else { continue }
            let title = Range(match.range(at: 1), in: html).map { range in
                WebResearchParsing.extractText(fromHTML: String(html[range]), maxChars: 300)
            } ?? ""
            hits.append(SearchHit(title: title, url: href))
        }
        return hits
    }

    /// 결과 href를 실제 대상 URL로 복원한다. 리다이렉트 링크는 uddg 파라미터를 퍼센트 디코딩한다.
    static func resultURL(fromHref rawHref: String) -> URL? {
        // HTML 속성에 인코딩된 &amp;를 먼저 되돌린다.
        let href = rawHref.replacingOccurrences(of: "&amp;", with: "&")
        if let components = URLComponents(string: href),
           let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return webURL(uddg)
        }
        return webURL(href)
    }

    private static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }

    private static func firstHref(in anchorHTML: String) -> String? {
        let range = NSRange(anchorHTML.startIndex..., in: anchorHTML)
        guard let match = hrefRegex.firstMatch(in: anchorHTML, options: [], range: range) else { return nil }
        if let doubleQuoted = Range(match.range(at: 1), in: anchorHTML) { return String(anchorHTML[doubleQuoted]) }
        if let singleQuoted = Range(match.range(at: 2), in: anchorHTML) { return String(anchorHTML[singleQuoted]) }
        return nil
    }

    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
}

// MARK: - 페이지 가져오기

/// URLSession으로 페이지 본문을 가져온다.
public struct PageFetcher: PageFetching {
    private let session: URLSession

    public init() {
        self.session = .shared
    }

    public init(session: URLSession) {
        self.session = session
    }

    public func fetch(_ url: URL) async throws -> String {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw LLMProviderError.unreachable("페이지를 가져올 수 없습니다: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode.description ?? "응답 없음"
            throw LLMProviderError.unreachable("페이지 요청 실패 (HTTP \(status))")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - 파싱

/// LLM 출력·HTML 파싱 순수 함수 모음.
public enum WebResearchParsing {
    /// LLM 응답 파서가 이해하는 JSON 원형.
    private struct RawSource: Decodable {
        var title: String?
        var url: String?
        var quote: String?
    }

    private struct RawDraft: Decodable {
        var oneLine: String
        var easyExplanation: String
        var examples: [String]?
        var sources: [RawSource]?
    }

    /// 노이즈 블록: HTML 주석 + script/style 전체.
    private static let scriptStyleRegex = regex(
        "<!--[\\s\\S]*?-->|<script\\b[\\s\\S]*?</script\\s*>|<style\\b[\\s\\S]*?</style\\s*>",
        caseInsensitive: true
    )
    private static let tagRegex = regex("</?[a-zA-Z][^>]*>")
    private static let whitespaceRegex = regex("\\s+")

    /// LLM 출력에서 구조화 초안을 복원한다.
    ///
    /// 코드펜스를 제거하고 첫 `{`부터 마지막 `}`까지를 JSON으로 디코딩한다.
    /// - url 파싱 실패는 `url: nil`로 유지한다.
    /// - oneLine/easyExplanation이 비어 있으면 `LLMProviderError.badResponse`를 던진다.
    public static func parseDraft(fromLLMOutput raw: String) throws -> DraftDefinition {
        let withoutFences = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
        guard let start = withoutFences.firstIndex(of: "{"),
              let end = withoutFences.lastIndex(of: "}"),
              start < end else {
            throw LLMProviderError.badResponse("응답에서 JSON 본문을 찾을 수 없습니다")
        }
        let json = String(withoutFences[start...end])
        let rawDraft: RawDraft
        do {
            rawDraft = try JSONDecoder().decode(RawDraft.self, from: Data(json.utf8))
        } catch {
            throw LLMProviderError.badResponse("JSON 디코딩 실패: \(error.localizedDescription)")
        }
        let oneLine = rawDraft.oneLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let easyExplanation = rawDraft.easyExplanation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty, !easyExplanation.isEmpty else {
            throw LLMProviderError.badResponse("oneLine/easyExplanation이 비어 있습니다")
        }
        let sources = (rawDraft.sources ?? []).map { source in
            CitedSource(
                title: source.title ?? "",
                url: source.url.flatMap { URL(string: $0) },
                excerpt: source.quote
            )
        }
        return DraftDefinition(
            oneLine: oneLine,
            easyExplanation: easyExplanation,
            examples: rawDraft.examples ?? [],
            sources: sources
        )
    }

    /// HTML을 읽을 수 있는 본문 텍스트로 정리한다.
    ///
    /// script/style 블록 제거 → 태그 제거 → 엔티티 최소 디코딩(&amp; &lt; &gt; &quot; &#39;) →
    /// 공백 정규화 → `maxChars` 절단.
    public static func extractText(fromHTML html: String, maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        var text = replacing(scriptStyleRegex, in: html, with: " ")
        text = replacing(tagRegex, in: text, with: " ")
        // &amp;는 마지막에 디코딩해 이중 디코딩(&amp;lt; → "<")을 막는다.
        text = text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
        return String(collapseWhitespace(text).prefix(maxChars))
    }

    /// 연속된 공백을 한 칸으로 모으고 앞뒤를 정리한다.
    static func collapseWhitespace(_ text: String) -> String {
        replacing(whitespaceRegex, in: text, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(_ regex: NSRegularExpression, in string: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: string, options: [], range: NSRange(string.startIndex..., in: string), withTemplate: template
        )
    }

    private static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }
}

// MARK: - 서비스

/// 검색 → 페이지 발췌 → LLM 구조화 초안 → 출처 화이트리스트 필터 파이프라인.
///
/// 흐름(설계 문서): `search(term, limit: 4)` → 상위 3개 페이지를 병렬로 가져와
/// `extractText(maxChars: 4000)`으로 본문 발췌 → LLM 프롬프트로 JSON 초안 생성 → `parseDraft` →
/// sources 중 실제로 가져온 URL만 남기고 excerpt는 페이지 본문 발췌로 정리.
/// 검색 결과가 0개면 자료 없이 LLM으로 생성하며 sources는 빈 배열이 된다(출처 없는 AI 초안).
public struct WebResearchService: Sendable {
    private typealias Material = (title: String, url: URL, text: String)

    /// 설명 언어만 바뀌는 템플릿. JSON 스키마는 언어와 무관하게 고정이라 파서가 그대로 동작한다.
    static func systemPrompt(explanationLanguage: EntryLanguage) -> String {
        """
        당신은 다국어 용어 사전 편집자입니다. 제공된 자료만 근거로 삼고, 자료에 없는 내용은 추측하지 않습니다.
        반드시 아래 JSON 스키마만 출력하세요. 코드펜스, 주석, JSON 외 텍스트는 절대 출력하지 않습니다.
        {"oneLine": "...", "easyExplanation": "...", "examples": ["..."], "sources": [{"title": "...", "url": "...", "quote": "..."}]}
        - 모든 내용의 언어: \(explanationLanguage.nativeName). 고유명사·기호는 원어 표기를 유지해도 됩니다.
        - oneLine: 한 줄 정의.
        - easyExplanation: 쉬운 설명(2~3문장).
        - examples: 실용적인 예시 1~3개.
        - sources: 근거로 삼은 자료의 제목(title), URL(url), 원문 인용(quote).
        """
    }

    private let search: any SearchProvider
    private let llm: any LLMProvider
    private let fetcher: any PageFetching

    public init(search: any SearchProvider, llm: any LLMProvider, fetcher: any PageFetching) {
        self.search = search
        self.llm = llm
        self.fetcher = fetcher
    }

    public func research(
        term: String,
        context: String?,
        termLanguage: EntryLanguage? = nil,
        explanationLanguage: EntryLanguage = .korean
    ) async throws -> DraftDefinition {
        let hits = try await search.search(term, limit: 4)
        let materials = await fetchMaterials(Array(hits.prefix(3)))
        let raw = try await llm.complete(
            system: Self.systemPrompt(explanationLanguage: explanationLanguage),
            user: Self.userPrompt(term: term, termLanguage: termLanguage, context: context, materials: materials)
        )
        var draft = try WebResearchParsing.parseDraft(fromLLMOutput: raw)
        draft.sources = Self.filteredSources(draft.sources, materials: materials)
        return draft
    }

    /// 페이지를 병렬로 가져오고 성공한 것만 본문 발췌로 정리한다(베스트 에포트).
    private func fetchMaterials(_ hits: [SearchHit]) async -> [Material] {
        guard !hits.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, String, URL, String?).self) { group in
            for (offset, hit) in hits.enumerated() {
                group.addTask {
                    let text = try? await self.fetcher.fetch(hit.url)
                    return (offset, hit.title, hit.url, text)
                }
            }
            var collected: [(Int, String, URL, String)] = []
            for await (offset, title, url, text) in group {
                guard let text, !text.isEmpty else { continue }
                let extracted = WebResearchParsing.extractText(fromHTML: text, maxChars: 4000)
                guard !extracted.isEmpty else { continue }
                collected.append((offset, title, url, extracted))
            }
            // 원본 검색 순서를 유지해 프롬프트 재현성을 높인다.
            return collected
                .sorted { $0.0 < $1.0 }
                .map { (title: $0.1, url: $0.2, text: $0.3) }
        }
    }

    /// 실제로 가져온 URL만 남긴다. excerpt는 본문에서 검증된 인용, 아니면 페이지 본문 앞부분 발췌로 정리된다.
    private static func filteredSources(_ sources: [CitedSource], materials: [Material]) -> [CitedSource] {
        let pagesByURL = Dictionary(materials.map { ($0.url, $0.text) }, uniquingKeysWith: { current, _ in current })
        return sources.compactMap { source in
            guard let url = source.url, let pageText = pagesByURL[url] else { return nil }
            var kept = source
            let quote = source.excerpt.map(WebResearchParsing.collapseWhitespace) ?? ""
            kept.excerpt = !quote.isEmpty && pageText.contains(quote)
                ? quote
                : String(pageText.prefix(200))
            return kept
        }
    }

    private static func userPrompt(
        term: String,
        termLanguage: EntryLanguage?,
        context: String?,
        materials: [Material]
    ) -> String {
        var lines = ["용어: \(term)"]
        if let termLanguage {
            lines.append("용어 언어: \(termLanguage.nativeName)")
        }
        if let context = context?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty {
            lines.append("맥락: \(context)")
        }
        if materials.isEmpty {
            lines.append("근거로 삼을 자료가 제공되지 않았습니다. 일반 지식으로 초안을 작성하고, sources는 반드시 빈 배열([])로 출력하세요.")
        } else {
            lines.append("아래 자료 발췌만을 근거로 초안을 작성하세요.")
            lines.append("")
            for (index, material) in materials.enumerated() {
                lines.append("[\(index + 1)] \(material.title) (\(material.url.absoluteString))")
                lines.append(material.text)
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }
}
