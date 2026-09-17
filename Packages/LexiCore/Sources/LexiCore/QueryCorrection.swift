import Foundation

/// 오타 자동 보정 — 정확 검색이 빈 결과일 때만 저장된 표현과 비교한다.
///
/// 조회 파이프라인의 보수적 규칙을 따른다:
/// - 후보 선정에만 대소문자·발음 구별·전각/반각 폴딩을 느슨하게 쓰고, 결과는 저장된 원문을 그대로 돌려준다.
/// - 편집거리(전치 1회 포함) 임계값: 접힌 길이 ≤ 4는 1, 그 외에는 2. 두 글자 미만 질의는 보정하지 않는다.
/// - 동률은 결정적으로 깨진다: 편집거리 → 길이 차 → 접힌 표현 사전순. 같은 입력엔 항상 같은 답.
public enum QueryCorrection {
    /// `candidates` 중 `query`와 철자가 가장 가까운 저장 표현. 임계값을 넘거나 후보가 없으면 nil.
    public static func bestMatch(for query: String, in candidates: [String]) -> String? {
        let foldedQuery = fold(query)
        let queryChars = Array(foldedQuery)
        guard queryChars.count >= 2 else { return nil }
        let limit = maxDistance(foldedLength: queryChars.count)

        var best: (text: String, folded: String, distance: Int, lengthGap: Int)?
        for candidate in candidates {
            let foldedCandidate = fold(candidate)
            let candidateChars = Array(foldedCandidate)
            // 편집거리는 길이 차 이상이므로 긴 후보를 DP로 돌리기 전에 가른다.
            guard !candidateChars.isEmpty, abs(candidateChars.count - queryChars.count) <= limit
            else { continue }
            let distance = restrictedEditDistance(queryChars, candidateChars)
            guard distance <= limit else { continue }
            let lengthGap = abs(candidateChars.count - queryChars.count)
            let challenger = (text: candidate, folded: foldedCandidate, distance: distance, lengthGap: lengthGap)
            if let current = best {
                if (challenger.distance, challenger.lengthGap, challenger.folded)
                    < (current.distance, current.lengthGap, current.folded) {
                    best = challenger
                }
            } else {
                best = challenger
            }
        }
        return best?.text
    }

    /// 비교용 폴딩. 저장 원문은 이 값으로 바뀌지 않는다.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// 보수적 임계값: 짧은 표현은 한 글자, 길어야 두 글자까지.
    static func maxDistance(foldedLength: Int) -> Int {
        foldedLength <= 4 ? 1 : 2
    }

    /// 제한 편집거리(Optimal String Alignment): 삽입·삭제·치환 1, 인접 전치 1.
    static func restrictedEditDistance(_ a: [Character], _ b: [Character]) -> Int {
        let rows = a.count, columns = b.count
        if rows == 0 { return columns }
        if columns == 0 { return rows }
        var table = Array(repeating: Array(0 ... columns), count: rows + 1)
        for i in 1 ... rows { table[i][0] = i }
        for i in 1 ... rows {
            for j in 1 ... columns {
                let substitution = table[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                var value = min(table[i - 1][j] + 1, table[i][j - 1] + 1, substitution)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, table[i - 2][j - 2] + 1)
                }
                table[i][j] = value
            }
        }
        return table[rows][columns]
    }
}
