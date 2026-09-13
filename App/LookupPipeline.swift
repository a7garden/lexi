import Foundation
import LexiCore

/// 조회 파이프라인 — 설계 문서의 중심 동작.
///
/// 저장된 개념이면 **AI를 실행하지 않고** 즉시 패널에 표시한다.
/// 없을 때만 조사·생성으로 넘어가고, 결과는 자동으로 사전에 저장한다.
/// "저장했다"와 "검증했다"는 다른 상태: 웹 조사 출처가 없으면 AI 초안으로 남긴다.
@MainActor
final class LookupPipeline {
    enum Phase: Equatable {
        case idle
        case researching(term: String, step: Int)  // step 0..2 (의미 파악 / 자료 검색 / AI 정리)
        case done
        case failed(String)
    }

    private let service: LookupService
    let research: WebResearchService?
    private let llmIdentifier: String?
    private let explanationLanguage: ExplanationLanguagePreference
    private(set) var lastQuery: String = ""

    init(
        service: LookupService,
        research: WebResearchService?,
        llmIdentifier: String?,
        explanationLanguage: ExplanationLanguagePreference = .fixed(.korean)
    ) {
        self.service = service
        self.research = research
        self.llmIdentifier = llmIdentifier
        self.explanationLanguage = explanationLanguage
    }

    /// 1차: 사전 정확 검색. AI 호출 없음. 요청한 설명 언어의 개정본을 우선한다.
    func lookup(_ rawQuery: String) async -> [DictionaryEntry] {
        lastQuery = rawQuery
        let termLanguage = LanguageDetector.detect(rawQuery)
        let revisionLang = explanationLanguage.resolve(termLanguage: termLanguage)
        let entries = (try? await service.lookupExact(rawQuery, revisionLang: revisionLang)) ?? []
        if let best = entries.first {
            try? await service.recordLookup(rawQuery, conceptId: best.conceptId, status: .hit)
        } else {
            try? await service.recordLookup(rawQuery, conceptId: nil, status: .miss)
        }
        return entries
    }

    /// 2차: 웹 조사 + 로컬 AI 정리 + 자동 저장.
    /// 실행 위치(로컬 모델 vs 외부 API)는 설정이 결정; 실패해도 외부로 몰래 바꾸지 않는다.
    func researchAndSave(_ rawQuery: String) async -> Result<(DictionaryEntry, [CitedSource]), Error> {
        guard let research else {
            return .failure(PipelineError.noEngine)
        }
        do {
            let termLanguage = LanguageDetector.detect(rawQuery)
            let explanationLang = explanationLanguage.resolve(termLanguage: termLanguage)
            let draft = try await research.research(
                term: rawQuery, context: nil,
                termLanguage: termLanguage, explanationLanguage: explanationLang)
            try Task.checkCancellation()
            let conceptId = try await service.saveConcept(
                preferredTerm: rawQuery,
                aliases: [],
                field: nil,
                oneLine: draft.oneLine,
                easyExplanation: draft.easyExplanation,
                author: "ai",
                provider: llmIdentifier,
                termLanguage: termLanguage,
                explanationLanguage: explanationLang
            )
            // 출처는 개정본에 연결 — 앱이 실제로 가져온 자료만 저장.
            let revisionId = try await latestRevisionId(conceptId)
            for source in draft.sources {
                try await service.addSource(
                    revisionId: revisionId,
                    title: source.title,
                    url: source.url?.absoluteString,
                    excerpt: source.excerpt
                )
            }
            let entries = try await service.lookupExact(rawQuery)
            if let entry = entries.first {
                try? await service.recordLookup(rawQuery, conceptId: entry.conceptId, status: .hit)
                return .success((entry, draft.sources))
            }
            return .failure(PipelineError.notSaved)
        } catch {
            return .failure(error)
        }
    }

    private func latestRevisionId(_ conceptId: Int64) async throws -> Int64 {
        try await service.database.writer.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT MAX(id) FROM definitionRevision WHERE conceptId = ?",
                arguments: [conceptId]
            ) ?? -1
        }
    }

    enum PipelineError: LocalizedError {
        case noEngine
        case notSaved

        var errorDescription: String? {
            switch self {
            case .noEngine: "생성 엔진이 설정되지 않았어요. 설정에서 로컬 모델을 연결하세요."
            case .notSaved: "생성은 됐지만 사전 저장에 실패했어요."
            }
        }
    }
}
