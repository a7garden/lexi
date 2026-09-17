import Foundation
import Testing
@testable import LexiCore

/// Stage 0 — fixture와 계약 고정(docs/PDC-MIGRATION.md).
///
/// `pdc-document-conformance/2` revision 2 corpus(`Fixtures/pdc2/`, 정본 사본에서
/// vendoring)를 LexiCore 테스트로 연결하고, 문서가 고정한 계약 판단을 테스트로
/// 고정한다. codec·import plan 자체는 Stage 1 이후 과제라 여기서 다루지 않는다.
@Suite struct PDCConformanceTests {
    private static func loadCorpus() throws -> PDCConformanceCorpus {
        let url = try #require(
            Bundle.module.url(
                forResource: "corpus", withExtension: "json", subdirectory: "Fixtures/pdc2"))
        return try JSONDecoder().decode(PDCConformanceCorpus.self, from: Data(contentsOf: url))
    }

    /// fixtures/ 아래 파일을 corpus.json 기준 상대 경로로 나열한다.
    /// corpus.json의 경로는 `fixtures/…` 접두어를 포함하므로 pdc2 루트 기준으로 삼는다.
    private static func fixtureTree() throws -> Set<String> {
        let root = try #require(
            Bundle.module.resourceURL?.appendingPathComponent("Fixtures/pdc2"))
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var files = Set<String>()
        for case let url as URL in try #require(enumerator) {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if !isDirectory.boolValue, url.lastPathComponent != "corpus.json",
                url.lastPathComponent != "README.md" {
                files.insert(String(url.path.dropFirst(root.path.count + 1)))
            }
        }
        return files
    }

    // MARK: - 계약 식별자 고정

    @Test func corpus는_문서가_고정한_계약_식별자를_선언한다() throws {
        let corpus = try Self.loadCorpus()
        #expect(corpus.format == PDCContract.conformanceFormat)
        #expect(corpus.revision == PDCContract.conformanceRevision)
        #expect(corpus.queryContract == PDCContract.queryProfile)
        #expect(corpus.bodyProfiles == [PDCContract.markdownProfile, PDCContract.htmlProfile])
        #expect(corpus.markdownBaseline.contains("CommonMark 0.31.2"))
        #expect(corpus.markdownBaseline.contains("GFM"))
    }

    // MARK: - fixture 연결 완전성

    @Test func 모든_케이스가_존재하는_fixture를_가리킨다() throws {
        let corpus = try Self.loadCorpus()
        let tree = try Self.fixtureTree()
        #expect(!corpus.cases.isEmpty)
        for item in corpus.cases {
            for referenced in item.referencedPaths {
                #expect(
                    tree.contains(referenced),
                    "케이스 \(item.id)가 가리키는 \(referenced)가 fixture 트리에 없다")
            }
        }
    }

    @Test func 모든_fixture_파일이_케이스나_companion으로_설명된다() throws {
        let corpus = try Self.loadCorpus()
        let referenced = Set(corpus.cases.flatMap(\.referencedPaths))
        let tree = try Self.fixtureTree()
        // 케이스가 직접 가리키지 않는 파일은 external-change의 상대 문서(changed.*)뿐이다.
        let companions = tree.subtracting(referenced)
        #expect(
            companions.isEmpty || companions.allSatisfy {
                $0.contains("fixtures/operations/") && $0.contains("/changed.")
            },
            "설명되지 않는 fixture 파일: \(companions)")
    }

    // MARK: - 기대값 범주 고정

    /// 문서가 고정한 네 범주: 정식 입력 / 보이는 읽기 전용 legacy / 진단 / writer 규약.
    private static let validFamily: Set<String> = ["valid", "valid_unexecuted"]
    private static let legacyFamily: Set<String> = ["legacy_valid", "legacy_html", "legacy_markdown"]
    private static let diagnosisFamily: Set<String> = [
        "invalid_transport", "invalid_document_id", "invalid_envelope", "unsafe_content",
        "unsupported_body_version", "unsupported_document_version", "invalid_query",
        "document_too_large", "document_too_complex", "duplicate_document_id",
        "duplicate_block_id", "external_change_conflict",
    ]
    private static let writerFamily: Set<String> = ["byte-identical"]

    @Test func 모든_기대값은_고정된_네_범주에_속한다() throws {
        let corpus = try Self.loadCorpus()
        for item in corpus.cases {
            let expectation = item.expect
            #expect(
                Self.validFamily.contains(expectation)
                    || Self.legacyFamily.contains(expectation)
                    || Self.diagnosisFamily.contains(expectation)
                    || Self.writerFamily.contains(expectation),
                    "케이스 \(item.id)의 기대값 \(expectation)이 어느 범주에도 속하지 않는다")
        }
    }

    @Test func legacy는_절대_정식_입력으로_분류되지_않는다() throws {
        let corpus = try Self.loadCorpus()
        for item in corpus.cases {
            let isLegacyFlavor = item.path?.contains("fixtures/legacy/") == true
                || item.path?.hasSuffix(".djot") == true
                || (item.paths ?? []).contains { $0.hasSuffix(".djot") }
            if isLegacyFlavor {
                #expect(
                    !Self.validFamily.contains(item.expect),
                    "legacy 케이스 \(item.id)가 정식 입력 기대값(\(item.expect))을 갖는다")
            }
        }
        // v1 문서와 unmarked 입력은 읽을 수는 있어도 새 revision 대상이 아니다(PDC 불변 조건 7).
        for item in corpus.cases where item.path?.contains("fixtures/legacy/") == true {
            #expect(Self.legacyFamily.contains(item.expect))
        }
    }

    @Test func 안전하지_않은_입력은_가져오지_않고_진단만_한다() throws {
        let corpus = try Self.loadCorpus()
        for item in corpus.cases where item.path?.contains("fixtures/invalid/") == true {
            #expect(
                Self.diagnosisFamily.contains(item.expect),
                "invalid 케이스 \(item.id)가 진단이 아닌 기대값(\(item.expect))을 갖는다")
        }
    }

    // MARK: - writer 규약 고정

    @Test func 문서를_다시_쓰지_않는_연산은_바이트를_보존한다() throws {
        let corpus = try Self.loadCorpus()
        // no-op·metadata-patch는 원본 바이트를 그대로 유지해야 한다(불변 조건 7:
        // 자동 변환·재작성 없음). v1 djot·html과 v2 md·html 네 조합 모두.
        let bytePreserving = corpus.cases.filter {
            $0.operation == "no-op-round-trip" || $0.operation == "metadata-patch"
        }
        #expect(bytePreserving.count >= 8)
        for item in bytePreserving {
            #expect(item.expect == "byte-identical", "케이스 \(item.id)")
        }
        // 외부 변경이 섞인 경우는 충돌로 다룬다(조용히 병합하지 않는다).
        for item in corpus.cases where item.operation == "external-change" {
            #expect(item.expect == "external_change_conflict", "케이스 \(item.id)")
        }
    }
    // MARK: - 결정론 고정

    @Test func 동일_입력은_항상_같은_분류를_만든다() throws {
        let first = try Self.loadCorpus()
        let second = try Self.loadCorpus()
        #expect(first == second)
        // 분류가 입력 횟수와 무관하게 안정적이다.
        #expect(first.cases.map(\.expect) == second.cases.map(\.expect))
        // 케이스 ID는 유일하다.
        #expect(Set(first.cases.map(\.id)).count == first.cases.count)
    }
}
