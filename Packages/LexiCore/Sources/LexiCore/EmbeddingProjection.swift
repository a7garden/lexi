import Foundation

/// 임베딩 지도에 그릴 한 점. 좌표는 단위 상자 [-1, 1]로 정규화되어 있다.
public struct ProjectedConcept: Sendable, Equatable, Identifiable {
    public var conceptId: Int64
    public var term: String
    public var field: String?
    public var x: Double
    public var y: Double

    public var id: Int64 { conceptId }
}

/// 문서 벡터를 2차원 산점도 좌표로 바꾸는 주성분 투영.
///
/// 공분산 행렬을 만들지 않고 `Mv = Σ (xᵢ·v) xᵢ`를 점마다 계산하는 거듭제곱 반복으로
/// 첫 두 주성분을 찾는다. 문서 수 n, 차원 d 기준 반복 한 번이 O(n·d)라 수백 개 문서에도
/// 충분히 빠르다. 초기 벡터를 분산이 가장 큰 좌표축으로 고정해 결과를 결정적으로 만든다.
public enum EmbeddingProjection {
    /// 첫 두 주성분으로 2차원에 투영한다.
    ///
    /// 점이 3개 미만, 벡터 차원이 서로 다르거나 2 미만, 벡터에 분산이 전혀 없으면 nil.
    /// 벡터가 한 직선 위에만 있으면 두 번째 좌표는 0에 가깝게 나온다(직선 지도).
    public static func project(
        _ points: [ConceptEmbedding],
        maxIterations: Int = 64
    ) -> [ProjectedConcept]? {
        guard points.count >= 3 else { return nil }
        let dim = points[0].vector.count
        guard dim >= 2, points.allSatisfy({ $0.vector.count == dim }) else { return nil }

        // 평균 중심화: 지도는 "어떤 축이 데이터를 가장 크게 갈라는가"만 보면 된다.
        let count = Double(points.count)
        var mean = [Double](repeating: 0, count: dim)
        for point in points {
            for (index, value) in point.vector.enumerated() { mean[index] += Double(value) }
        }
        for index in mean.indices { mean[index] /= count }

        var centered = points.map { point in point.vector.map { Double($0) } }
        for row in centered.indices {
            for index in centered[row].indices { centered[row][index] -= mean[index] }
        }

        func multiply(_ vector: [Double]) -> [Double] {
            var result = [Double](repeating: 0, count: dim)
            for row in centered {
                var dot = 0.0
                for index in row.indices { dot += row[index] * vector[index] }
                for index in row.indices { result[index] += row[index] * dot }
            }
            return result
        }

        func normalized(_ vector: [Double]) -> [Double]? {
            let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 1e-12 else { return nil }
            return vector.map { $0 / norm }
        }

        // 좌표축별 제곱합 = 그 축 방향 분산. 가장 큰 축을 첫 반복의 시작점으로 쓴다.
        var axisVariance = [Double](repeating: 0, count: dim)
        for row in centered {
            for index in row.indices { axisVariance[index] += row[index] * row[index] }
        }
        let dominantAxis = axisVariance.indices.max { axisVariance[$0] < axisVariance[$1] } ?? 0
        // 전체 분산이 0이면 모든 벡터가 평균과 같다는 뜻이라 지도를 그릴 수 없다.
        guard axisVariance[dominantAxis] > 1e-24 else { return nil }

        func orthogonalized(_ vector: [Double], against: [Double]) -> [Double]? {
            let projection = zip(vector, against).reduce(0) { $0 + $1.0 * $1.1 }
            var result = vector
            for index in result.indices { result[index] -= projection * against[index] }
            return normalized(result)
        }

        // 데이터가 한 직선 위에 있으면 직교 성분의 분산이 0이라 반복이 진행되지 않는다.
        // 그때는 직교화된 시작 벡터를 그대로 둬 람다스트 지도(모든 y가 0)를 만든다.
        func powerIterate(_ initial: [Double], orthogonalTo: [Double]? = nil) -> [Double] {
            var vector = initial
            if let orthogonalTo, let orthogonal = orthogonalized(initial, against: orthogonalTo) {
                vector = orthogonal
            }
            for _ in 0..<maxIterations {
                guard var next = normalized(multiply(vector)) else { break }
                if let orthogonalTo {
                    guard let orthogonal = orthogonalized(next, against: orthogonalTo) else { break }
                    next = orthogonal
                }
                let delta = zip(next, vector).reduce(0) { $0 + abs($1.0 - $1.1) }
                vector = next
                if delta < 1e-9 { break }
            }
            return vector
        }
        var first = [Double](repeating: 0, count: dim)
        first[dominantAxis] = 1
        first = powerIterate(first)
        // 첫 주성분과의 내적이 가장 작은 좌표축으로 두 번째 반복을 시작한다.
        let orthogonalAxis = axisVariance.indices.min { dotAxis($0, first) < dotAxis($1, first) } ?? 0
        var second = [Double](repeating: 0, count: dim)
        second[orthogonalAxis] = 1
        second = powerIterate(second, orthogonalTo: first)

        var projected = zip(points, centered).map { point, row -> ProjectedConcept in
            let x = zip(row, first).reduce(0) { $0 + $1.0 * $1.1 }
            let y = zip(row, second).reduce(0) { $0 + $1.0 * $1.1 }
            return ProjectedConcept(
                conceptId: point.conceptId,
                term: point.term,
                field: point.field,
                x: x,
                y: y
            )
        }
        // 최대 절댓값으로 나눠 [-1, 1] 상자에 맞춘다. 절대 스케일은 화면 크기가 정한다.
        let scale = projected.reduce(0.0) { max($0, abs($1.x), abs($1.y)) }
        if scale > 0 {
            for index in projected.indices {
                projected[index].x /= scale
                projected[index].y /= scale
            }
        }
        return projected
    }

    /// 단위 좌표축 `axis`와 `vector`의 내적.
    private static func dotAxis(_ axis: Int, _ vector: [Double]) -> Double {
        abs(vector[axis])
    }
}
