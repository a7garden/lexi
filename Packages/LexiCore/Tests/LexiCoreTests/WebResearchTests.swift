import Testing
import Foundation
@testable import LexiCore

// MARK: - 테스트 전용 대역 (이 파일 안에서만 사용)

private enum Doubles {
    /// 항상 같은 결과를 돌려주는 검색기.
    struct StaticSearch: SearchProvider {
        let hits: [SearchHit]

        func search(_ query: String, limit: Int) async throws -> [SearchHit] {
            Array(hits.prefix(max(0, limit)))
        }
    }

    /// 미리 정의된 페이지만 돌려주는 페처. 없는 URL은 실패한다.
    struct KeyedFetcher: PageFetching {
        let pages: [URL: String]

        func fetch(_ url: URL) async throws -> String {
            guard let page = pages[url] else {
                throw LLMProviderError.unreachable("스텁에 없는 URL: \(url)")
            }
            return page
        }
    }

    /// 프롬프트를 기록하는 LLM 대역.
    final class RecordingLLM: LLMProvider, @unchecked Sendable {
        let identifier = "mock-llm"
        private let response: String
        private let lock = NSLock()
        private var system: String?
        private var user: String?
        private var calls = 0

        init(response: String) {
            self.response = response
        }

        func complete(system: String?, user: String) async throws -> String {
            lock.withLock {
                self.system = system
                self.user = user
                calls += 1
            }
            return response
        }

        var capturedSystem: String? {
            lock.lock()
            defer { lock.unlock() }
            return system
        }

        var capturedUser: String? {
            lock.lock()
            defer { lock.unlock() }
            return user
        }

        var capturedCalls: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }
}

/// URLProtocol 기반 로컬 스텁. 실제 네트워크는 일어나지 않는다.
private final class StubState: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data, [String: String])

    private let lock = NSLock()
    private var handler: Handler?
    private var requests: [URLRequest] = []

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
        requests = []
    }

    func setHandler(_ handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    func handlerValue() -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
    }

    var recordedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class StubURLProtocol: URLProtocol {
    static let state = StubState()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.record(request)
        guard let handler = Self.state.handlerValue() else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (statusCode, data, headers) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://stub.invalid")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeStubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

// MARK: - 파싱

@Suite struct WebResearchParsingTests {
    private static let json = """
    {"oneLine": "임베딩은 의미를 벡터로 표현한 것", "easyExplanation": "텍스트를 숫자 벡터로 바꿔 의미 거리를 계산할 수 있게 한다.", "examples": ["유사 문서 검색", "추천 시스템"], "sources": [{"title": "위키백과", "url": "https://ko.wikipedia.org/wiki/Embedding", "quote": "임베딩은 벡터 표현이다"}]}
    """

    @Test func 코드펜스로_감싸진_JSON을_파싱한다() throws {
        let raw = """
        답변입니다:
        ```json
        \(Self.json)
        ```
        """
        let draft = try WebResearchParsing.parseDraft(fromLLMOutput: raw)
        #expect(draft.oneLine == "임베딩은 의미를 벡터로 표현한 것")
        #expect(draft.easyExplanation.hasPrefix("텍스트를 숫자 벡터로"))
        #expect(draft.examples == ["유사 문서 검색", "추천 시스템"])
        #expect(
            draft.sources
                == [CitedSource(title: "위키백과", url: URL(string: "https://ko.wikipedia.org/wiki/Embedding"), excerpt: "임베딩은 벡터 표현이다")]
        )
    }

    @Test func 코드펜스가_없어도_파싱한다() throws {
        let draft = try WebResearchParsing.parseDraft(fromLLMOutput: Self.json)
        #expect(draft.oneLine == "임베딩은 의미를 벡터로 표현한 것")
        #expect(draft.examples.count == 2)
    }

    @Test func 앞뒤_잡텍스트가_있어도_중간의_JSON을_추출한다() throws {
        let raw = """
        물론입니다! 아래는 초안입니다.
        { "oneLine": "RAG 검색으로 답하기", "easyExplanation": "검색 결과를 붙여 생성한다.", "examples": [], "sources": [] }
        도움이 되길 바랍니다.
        """
        let draft = try WebResearchParsing.parseDraft(fromLLMOutput: raw)
        #expect(draft.oneLine == "RAG 검색으로 답하기")
        #expect(draft.sources.isEmpty)
    }

    @Test func URL이_파싱되지_않으면_nil로_유지한다() throws {
        let raw = """
        {"oneLine": "x", "easyExplanation": "y", "examples": [], "sources": [{"title": "깨진 링크", "url": "https://exa mple.com/a", "quote": "q"}]}
        """
        let draft = try WebResearchParsing.parseDraft(fromLLMOutput: raw)
        #expect(draft.sources.count == 1)
        #expect(draft.sources[0].url == nil)
        #expect(draft.sources[0].title == "깨진 링크")
        #expect(draft.sources[0].excerpt == "q")
    }

    @Test func oneLine이_비면_badResponse를_던진다() {
        let raw = #"{"oneLine": "  ", "easyExplanation": "y", "examples": [], "sources": []}"#
        do {
            _ = try WebResearchParsing.parseDraft(fromLLMOutput: raw)
            Issue.record("badResponse가 던져져야 한다")
        } catch {
            guard case LLMProviderError.badResponse = error else {
                Issue.record("예상 못한 오류: \(error)")
                return
            }
        }
    }

    @Test func JSON이_아니면_badResponse를_던진다() {
        do {
            _ = try WebResearchParsing.parseDraft(fromLLMOutput: "죄송합니다. 답을 찾지 못했습니다.")
            Issue.record("badResponse가 던져져야 한다")
        } catch {
            guard case LLMProviderError.badResponse = error else {
                Issue.record("예상 못한 오류: \(error)")
                return
            }
        }
    }

    @Test func 필수_키가_없어도_badResponse를_던진다() {
        do {
            _ = try WebResearchParsing.parseDraft(fromLLMOutput: #"{"oneLine": "x"}"#)
            Issue.record("badResponse가 던져져야 한다")
        } catch {
            guard case LLMProviderError.badResponse = error else {
                Issue.record("예상 못한 오류: \(error)")
                return
            }
        }
    }

    private static let html = """
    <html><head><title>Lexi 사전</title><style>body { color: red; }</style></head>
    <body><script>var x = "<div>&amp;</div>";</script><h1>임베딩</h1><p>벡터로 의미를 &amp; 표현합니다.</p><p>예: &quot;검색&quot; &#39;랭킹&#39; &lt;rank&gt;</p></body></html>
    """
    private static let plain = "Lexi 사전 임베딩 벡터로 의미를 & 표현합니다. 예: \"검색\" '랭킹' <rank>"

    @Test func 태그와_엔티티를_본문_텍스트로_정리한다() {
        #expect(WebResearchParsing.extractText(fromHTML: Self.html, maxChars: 10_000) == Self.plain)
    }

    @Test func 스크립트와_스타일_내용은_사라진다() {
        let text = WebResearchParsing.extractText(fromHTML: Self.html, maxChars: 10_000)
        #expect(!text.contains("color"))
        #expect(!text.contains("var x"))
        #expect(!text.contains("<div>"))
    }

    @Test func maxChars로_잘라낸다() {
        #expect(WebResearchParsing.extractText(fromHTML: Self.html, maxChars: 7) == String(Self.plain.prefix(7)))
        #expect(WebResearchParsing.extractText(fromHTML: Self.html, maxChars: 0) == "")
    }
}

// MARK: - 서비스 통합 (목 주입)

@Suite struct WebResearchServiceTests {
    @Test func 검색과_출처_화이트리스트로_초안을_만든다() async throws {
        let pageA = URL(string: "https://page-a.example.com/embedding")!
        let pageB = URL(string: "https://page-b.example.com/vector")!
        let pageAText = "임베딩은 벡터로 의미를 표현하는 방법이다. 검색 시스템에서 활용된다."
        let pageBText = "벡터 검색은 유사도를 계산해 문서를 찾는 기술이다."
        let llm = Doubles.RecordingLLM(response: """
        {"oneLine": "임베딩은 의미를 벡터로 표현한 것", "easyExplanation": "텍스트를 숫자 벡터로 바꿔 의미 거리를 계산할 수 있게 한다.", "examples": ["유사 문서 검색"], "sources": [{"title": "A", "url": "\(pageA.absoluteString)", "quote": "벡터로 의미를 표현"}, {"title": "B", "url": "\(pageB.absoluteString)", "quote": "페이지에 없는 인용"}, {"title": "외부", "url": "https://external.example.net/other", "quote": "아무 문장"}]}
        """)
        let service = WebResearchService(
            search: Doubles.StaticSearch(hits: [
                SearchHit(title: "A 문서", url: pageA),
                SearchHit(title: "B 문서", url: pageB),
            ]),
            llm: llm,
            fetcher: Doubles.KeyedFetcher(pages: [
                pageA: "<p>\(pageAText)</p>",
                pageB: pageBText,
            ])
        )

        let draft = try await service.research(term: "임베딩", context: "검색 엔진 공부")

        #expect(draft.oneLine == "임베딩은 의미를 벡터로 표현한 것")
        #expect(draft.examples == ["유사 문서 검색"])
        #expect(draft.sources.count == 2)  // 가져오지 않은 외부 URL은 걸러진다
        #expect(draft.sources[0].url == pageA)
        #expect(draft.sources[0].excerpt == "벡터로 의미를 표현")  // 본문에 실제로 있는 인용은 유지
        #expect(draft.sources[1].url == pageB)
        #expect(draft.sources[1].excerpt == pageBText)  // 본문에 없는 인용은 본문 발췌로 교체

        #expect(llm.capturedCalls == 1)
        #expect(llm.capturedSystem?.contains("\"sources\"") == true)
        let user = llm.capturedUser ?? ""
        #expect(user.contains("용어: 임베딩"))
        #expect(user.contains("맥락: 검색 엔진 공부"))
        #expect(user.contains(pageAText))  // 태그가 제거된 본문 발췌가 프롬프트에 들어간다
        #expect(user.contains(pageB.absoluteString))
    }

    @Test func 검색결과가_없으면_자료_없이_생성하고_출처는_비운다() async throws {
        let llm = Doubles.RecordingLLM(response: """
        {"oneLine": "RAG는 검색 증강 생성", "easyExplanation": "검색 결과를 근거로 답을 생성한다.", "examples": [], "sources": [{"title": "그럴듯한 출처", "url": "https://unfetched.example.com", "quote": "q"}]}
        """)
        let service = WebResearchService(
            search: Doubles.StaticSearch(hits: []),
            llm: llm,
            fetcher: Doubles.KeyedFetcher(pages: [:])  // 호출되면 실패 → 0건 경로에서는 페처를 쓰면 안 된다
        )

        let draft = try await service.research(term: "RAG", context: nil)

        #expect(draft.sources.isEmpty)  // LLM이 내놓은 출처도 전부 필터링
        #expect(llm.capturedCalls == 1)
        let user = llm.capturedUser ?? ""
        #expect(user.contains("용어: RAG"))
        #expect(user.contains("근거로 삼을 자료가 제공되지 않았습니다"))
        #expect(user.contains("맥락:") == false)
    }
    @Test func 설명_언어와_용어_언어를_프롬프트에_지시한다() async throws {
        let llm = Doubles.RecordingLLM(response: """
        {"oneLine": "An embedding represents meaning as a vector", "easyExplanation": "Text is mapped to numbers.", "examples": [], "sources": []}
        """)
        let service = WebResearchService(
            search: Doubles.StaticSearch(hits: []),
            llm: llm,
            fetcher: Doubles.KeyedFetcher(pages: [:])
        )

        _ = try await service.research(
            term: "embedding", context: nil,
            termLanguage: .english, explanationLanguage: .english)
        #expect(llm.capturedSystem?.contains("English") == true)
        #expect(llm.capturedUser?.contains("용어 언어: English") == true)

        // 기본값은 기존처럼 한국어 설명 지시다.
        _ = try await service.research(term: "임베딩", context: nil)
        #expect(llm.capturedSystem?.contains("한국어") == true)
        #expect(llm.capturedSystem?.contains("English") == false)
        #expect(llm.capturedUser?.contains("용어 언어:") == false)
    }

}

// MARK: - DuckDuckGo / PageFetcher (URLProtocol 로컬 스텁, 실제 네트워크 없음)

@Suite(.serialized) struct WebResearchNetworkStubTests {
    private static let ddgHTML = """
    <html><body><div class="result results_links">
    <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fembeddings%3Fid%3D7&amp;rut=abc123">임베딩이란 무엇인가</a>
    <a class="result__snippet">임베딩은 벡터로 의미를 표현한다</a>
    <a class="result__a" href="https://direct.example.com/vector">직접 링크 &amp; 설명</a>
    </div></body></html>
    """

    @Test func DDG_검색결과를_파싱한다() async throws {
        let state = StubURLProtocol.state
        state.reset()
        defer { state.reset() }
        state.setHandler { _ in (200, Data(Self.ddgHTML.utf8), ["Content-Type": "text/html; charset=utf-8"]) }

        let search = DuckDuckGoSearch(session: makeStubbedSession())
        let hits = try await search.search("임베딩", limit: 5)

        #expect(hits.count == 2)  // result__snippet은 결과가 아니다
        #expect(hits[0].url.absoluteString == "https://example.com/embeddings?id=7")  // uddg 복원
        #expect(hits[0].title == "임베딩이란 무엇인가")
        #expect(hits[1].url.absoluteString == "https://direct.example.com/vector")
        #expect(hits[1].title == "직접 링크 & 설명")

        #expect(try await search.search("임베딩", limit: 1).count == 1)  // limit 적용

        let requests = state.recordedRequests
        #expect(requests.count == 2)
        #expect(requests[0].url?.host == "html.duckduckgo.com")
        #expect(requests[0].url?.path == "/html")  // URL.path는 trailing slash를 정규화한다
        #expect(requests[0].url?.query?.contains("q=") == true)
        #expect(requests[0].value(forHTTPHeaderField: "User-Agent")?.contains("Mozilla/5.0") == true)
    }

    @Test func DDG_전송_오류는_unreachable로_감싼다() async throws {
        let state = StubURLProtocol.state
        state.reset()
        defer { state.reset() }
        state.setHandler { _ in throw URLError(.timedOut) }

        let search = DuckDuckGoSearch(session: makeStubbedSession())
        do {
            _ = try await search.search("임베딩", limit: 3)
            Issue.record("unreachable이 던져져야 한다")
        } catch {
            guard case LLMProviderError.unreachable = error else {
                Issue.record("예상 못한 오류: \(error)")
                return
            }
        }
    }

    @Test func DDG_HTTP_오류도_unreachable로_감싼다() async throws {
        let state = StubURLProtocol.state
        state.reset()
        defer { state.reset() }
        state.setHandler { _ in (403, Data(), [:]) }

        let search = DuckDuckGoSearch(session: makeStubbedSession())
        do {
            _ = try await search.search("임베딩", limit: 3)
            Issue.record("unreachable이 던져져야 한다")
        } catch {
            guard case LLMProviderError.unreachable = error else {
                Issue.record("예상 못한 오류: \(error)")
                return
            }
        }
    }

    @Test func PageFetcher_2xx면_본문을_돌려준다() async throws {
        let state = StubURLProtocol.state
        state.reset()
        defer { state.reset() }
        state.setHandler { _ in (200, Data("<p>본문</p>".utf8), ["Content-Type": "text/html; charset=utf-8"]) }

        let fetcher = PageFetcher(session: makeStubbedSession())
        let body = try await fetcher.fetch(URL(string: "https://docs.example.com/page")!)
        #expect(body == "<p>본문</p>")
    }

    @Test func PageFetcher_2xx가_아니면_던진다() async throws {
        let state = StubURLProtocol.state
        state.reset()
        defer { state.reset() }
        state.setHandler { _ in (404, Data(), [:]) }

        let fetcher = PageFetcher(session: makeStubbedSession())
        do {
            _ = try await fetcher.fetch(URL(string: "https://docs.example.com/missing")!)
            Issue.record("오류가 던져져야 한다")
        } catch {
            guard case LLMProviderError.unreachable = error else {
                Issue.record("예상 못한 오류: \(error)")
                return
            }
        }
    }
}
