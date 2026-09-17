import SwiftUI
import Charts
import LexiCore

/// 통계 창의 상태. 라이브러리와 별개로 DB를 열고 읽기 전용 스냅샷을 유지한다.
@MainActor
final class StatsViewModel: ObservableObject {
    /// 임베딩 지도 진행 상태. 모델 내려받기·계산은 명시적 요청에서만 시작한다.
    enum EmbeddingPhase: Equatable {
        case idle
        case computing
        case ready([ProjectedConcept])
    }

    @Published private(set) var stats: LibraryStats?
    @Published private(set) var loadError: String?
    @Published private(set) var isLoaded = false
    @Published private(set) var embeddingPhase: EmbeddingPhase = .idle
    @Published private(set) var embeddingMessage: String?

    private var service: LookupService?
    private var semanticSearch: SemanticLibrarySearch?
    private var loadGeneration = 0
    private var embeddingGeneration = 0

    init() {
        bootstrap()
    }

    init(database: AppDatabase, embeddingProvider: any TextEmbeddingProvider = MLXTextEmbeddingProvider()) {
        configure(database: database, embeddingProvider: embeddingProvider)
        Task { await load() }
    }

    private func configure(database: AppDatabase, embeddingProvider: any TextEmbeddingProvider) {
        let service = LookupService(database: database)
        self.service = service
        self.semanticSearch = SemanticLibrarySearch(service: service, provider: embeddingProvider)
    }

    /// 지연 초기화: DB 열기·마이그레이션은 창을 막지 않도록 MainActor 밖에서 수행한다.
    private func bootstrap() {
        Task {
            do {
                let database = try await Task.detached(priority: .userInitiated) {
                    let database = try AppDatabase.makeDefault()
                    try database.migrate()
                    return database
                }.value
                configure(database: database, embeddingProvider: MLXTextEmbeddingProvider())
                await load()
            } catch {
                loadError = "통계 데이터베이스를 열 수 없어요: \(error.localizedDescription)"
            }
        }
    }

    /// 스냅샷을 다시 읽는다. 뒤늦게 도착한 응답이 새 스냅샷을 덮지 않게 세대로 관리한다.
    func load() async {
        guard let service else { return }
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let snapshot = try await service.libraryStats()
            guard generation == loadGeneration else { return }
            stats = snapshot
            loadError = nil
            isLoaded = true
        } catch {
            guard generation == loadGeneration else { return }
            loadError = "통계를 불러오지 못했어요: \(error.localizedDescription)"
        }
    }

    /// 임베딩 지도 계산. 처음 실행하면 임베딩 모델을 내려받는다(사용자 명시 동작).
    func loadEmbeddingMap() {
        guard let semanticSearch else { return }
        embeddingGeneration += 1
        let generation = embeddingGeneration
        embeddingPhase = .computing
        embeddingMessage = nil
        Task {
            do {
                let embeddings = try await semanticSearch.libraryEmbeddings()
                guard generation == embeddingGeneration else { return }
                if let projected = EmbeddingProjection.project(embeddings) {
                    embeddingPhase = .ready(projected)
                } else {
                    embeddingPhase = .idle
                    embeddingMessage = embeddings.count < 3
                        ? "지도를 그리려면 개념이 3개 이상 쌓여야 해요."
                        : "개념 벡터가 아직 서로 구분되지 않아요. 개념이 더 쌓이면 다시 시도해 주세요."
                }
            } catch is CancellationError {
                guard generation == embeddingGeneration else { return }
                embeddingPhase = .idle
            } catch {
                guard generation == embeddingGeneration else { return }
                embeddingPhase = .idle
                embeddingMessage = "임베딩을 계산하지 못했어요: \(error.localizedDescription)"
            }
        }
    }

    /// 오늘(기록이 없으면 어제)부터 연속으로 조회한 날 수.
    var lookupStreak: Int {
        guard let daily = stats?.daily, !daily.isEmpty else { return 0 }
        var streak = 0
        for point in daily.reversed() {
            if point.lookups > 0 {
                streak += 1
            } else if point.id == daily.last?.id, streak == 0 {
                continue // 오늘 아직 조회가 없어도 어제까지의 기록은 산다.
            } else {
                break
            }
        }
        return streak
    }
}

/// 통계 화면: 요약 카드 + 조회 활동 차트 + 임베딩 지도.
struct StatsView: View {
    @EnvironmentObject private var appDelegate: AppDelegate
    @StateObject private var viewModel: StatsViewModel

    init() {
        _viewModel = StateObject(wrappedValue: StatsViewModel())
    }

    init(viewModel: StatsViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        Group {
            if let stats = viewModel.stats {
                if stats.overview.conceptCount == 0 {
                    emptyState
                } else {
                    dashboard(stats)
                }
            } else if let error = viewModel.loadError {
                errorState(error)
            } else {
                ProgressView("통계를 준비하는 중…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("통계")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.load() }
                } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                }
                .help("최신 통계를 다시 읽어요")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lexiLibraryChanged)) { _ in
            Task { await viewModel.load() }
        }
    }

    // MARK: - 상태 화면

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("아직 통계를 낼 개념이 없어요").font(.title3.weight(.semibold))
            Text("단어를 조회하거나 추가하면 여기에 활동이 쌓여요.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(message).multilineTextAlignment(.center)
            Button("다시 시도") { Task { await viewModel.load() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - 대시보드

    private func dashboard(_ stats: LibraryStats) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                overviewSection(stats.overview)
                activitySection(stats.daily)
                topWordsSection(stats)
                hourlySection(stats.hourly)
                breakdownSection(stats)
                missedSection(stats.missedQueries)
                embeddingSection
            }
            .padding(24)
        }
    }

    private var dateFootnote: String? {
        guard let overview = viewModel.stats?.overview else { return nil }
        var parts: [String] = []
        if let firstSaved = overview.firstSavedAt {
            let days = max(1, (Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: firstSaved), to: Calendar.current.startOfDay(for: Date())).day ?? 0) + 1)
            parts.append("사전과 함께한 지 \(days)일째")
        }
        if let lastLookup = overview.lastLookupAt {
            parts.append("마지막 조회: \(lastLookup.formatted(.relative(presentation: .named)))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func overviewSection(_ overview: LibraryStatsOverview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("한눈에 보기", footnote: dateFootnote)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170), spacing: 12)],
                spacing: 12
            ) {
                StatCard(
                    title: "총 개념",
                    value: "\(overview.conceptCount)",
                    subtitle: "별칭 \(overview.aliasCount)개 · 개정본 \(overview.revisionCount)개"
                )
                StatCard(
                    title: "총 조회",
                    value: "\(overview.totalLookups)",
                    subtitle: "성공 \(overview.hitLookups) · 실패 \(overview.missLookups)"
                )
                StatCard(
                    title: "재조회률",
                    value: overview.revisitRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–",
                    subtitle: overview.revisitRate.map { _ in
                        "조회된 \(overview.lookedConceptCount)개 중 \(overview.revisitedConceptCount)개를 다시 찾았어요"
                    }
                )
                StatCard(
                    title: "평균 조회",
                    value: overview.averageLookupsPerLookedConcept
                        .map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–",
                    subtitle: "조회된 개념당"
                )
                StatCard(
                    title: "연속 조회",
                    value: "\(viewModel.lookupStreak)일",
                    subtitle: viewModel.lookupStreak > 0 ? "기록이 이어지고 있어요" : "오늘 조회해 보세요"
                )
                StatCard(
                    title: "즐겨찾기",
                    value: "\(overview.favoriteCount)",
                    subtitle: "AI 개정본 \(overview.aiRevisionCount)개 · 직접 수정 \(overview.userRevisionCount)개"
                )
            }
        }
    }

    private func activitySection(_ daily: [StatsDayPoint]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("최근 30일 활동", footnote: "조회는 실패한 검색도 포함해요")
            card {
                Chart {
                    ForEach(daily) { point in
                        BarMark(
                            x: .value("날짜", point.day, unit: .day),
                            y: .value("조회", point.lookups)
                        )
                        .foregroundStyle(Color.accentColor.opacity(0.85))
                    }
                    ForEach(daily) { point in
                        BarMark(
                            x: .value("날짜", point.day, unit: .day),
                            y: .value("저장", point.saved)
                        )
                        .foregroundStyle(Color.green.opacity(0.6))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) {
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month().day())
                    }
                }
                .frame(height: 170)
                legend([("조회", Color.accentColor.opacity(0.85)), ("저장", Color.green.opacity(0.6))])
            }
        }
    }

    private func topWordsSection(_ stats: LibraryStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("가장 많이 조회한 단어", footnote: "조회 수 기준 상위 8개")
            card {
                if stats.topWords.isEmpty {
                    placeholderText("아직 조회 기록이 없어요.")
                } else {
                    Chart(stats.topWords) { entry in
                        BarMark(
                            x: .value("조회", entry.lookupCount),
                            y: .value("단어", entry.term)
                        )
                        .cornerRadius(4)
                        .foregroundStyle(Color.accentColor.opacity(0.8))
                        .annotation(position: .trailing) {
                            Text("\(entry.lookupCount)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .chartXAxis(.hidden)
                    .frame(height: CGFloat(stats.topWords.count) * 26 + 12)
                }
                if !stats.neglectedWords.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("다시 볼 때가 된 단어").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(stats.neglectedWords) { entry in
                            HStack(spacing: 8) {
                                Text(entry.term).lineLimit(1)
                                Spacer()
                                Text("마지막 조회: \(entry.lastLookedUpAt.formatted(.relative(presentation: .named)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                appDelegate.openLibrary(conceptID: entry.conceptId)
                            }
                        }
                    }
                }
            }
        }
    }

    private func hourlySection(_ hourly: [StatsHourCount]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("시간대별 조회")
            card {
                Chart(hourly) { bucket in
                    BarMark(
                        x: .value("시각", String(format: "%02d", bucket.hour)),
                        y: .value("조회", bucket.lookups)
                    )
                    .cornerRadius(2)
                    .foregroundStyle(Color.accentColor.opacity(0.7))
                }
                .chartXAxis {
                    AxisMarks(values: ["00", "06", "12", "18", "23"]) { value in
                        AxisValueLabel {
                            if let hour = value.as(String.self) {
                                Text("\(hour)시")
                            }
                        }
                    }
                }
                .frame(height: 130)
            }
        }
    }

    private func breakdownSection(_ stats: LibraryStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("언어와 분야")
            HStack(alignment: .top, spacing: 12) {
                card {
                    miniBars(stats.languages, color: .indigo)
                }
                card {
                    miniBars(stats.fields, color: .orange)
                }
            }
        }
    }

    private func miniBars(_ items: [StatsNameCount], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if items.isEmpty {
                placeholderText("데이터가 없어요.")
            } else {
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        Text(item.name).font(.caption).lineLimit(1)
                        Spacer(minLength: 8)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color.opacity(0.6))
                            .frame(width: barWidth(item.count, in: items), height: 8)
                        Text("\(item.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 20, alignment: .trailing)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func barWidth(_ count: Int, in items: [StatsNameCount]) -> CGFloat {
        let maxCount = items.map(\.count).max() ?? 1
        guard maxCount > 0 else { return 4 }
        return max(4, CGFloat(count) / CGFloat(maxCount) * 90)
    }

    private func missedSection(_ missed: [MissedQuery]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("저장되지 않은 검색어", footnote: "사전에 닿지 못하고 지나간 질의예요")
            card {
                if missed.isEmpty {
                    placeholderText("지금까지 모든 검색이 저장된 개념으로 이어졌어요.")
                } else {
                    ForEach(missed) { entry in
                        HStack(spacing: 8) {
                            Text(entry.query).lineLimit(1).textSelection(.enabled)
                            Spacer()
                            Text("\(entry.count)회")
                                .font(.caption.monospacedDigit())
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.red.opacity(0.12)))
                                .foregroundStyle(.red)
                            Text(entry.lastAttemptedAt.formatted(.relative(presentation: .named)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 90, alignment: .trailing)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private var embeddingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("개념 임베딩 지도", footnote: "비슷한 개념이 가까이 모여요. 점을 누르면 라이브러리에서 열어요")
            card {
                switch viewModel.embeddingPhase {
                case .idle:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("각 개념의 문서 벡터를 2차원으로 펼쳐 사전의 지형을 보여줘요.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button("임베딩 계산하기") { viewModel.loadEmbeddingMap() }
                            Text("처음 사용하면 다국어 임베딩 모델을 내려받아요. 내용은 Mac 안에서만 처리돼요.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let message = viewModel.embeddingMessage {
                            Text(message).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .computing:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("임베딩을 계산하는 중…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                case .ready(let points):
                    VStack(alignment: .leading, spacing: 8) {
                        MapChart(points: points) { conceptId in
                            appDelegate.openLibrary(conceptID: conceptId)
                        }
                        .frame(minHeight: 320, maxHeight: 420)
                        Text("거리는 의미 유사도를 대략적으로 반영해요. 축 방향 자체는 의미가 없어요.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 조각

    private func sectionHeader(_ title: String, footnote: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func legend(_ entries: [(String, Color)]) -> some View {
        HStack(spacing: 12) {
            ForEach(entries, id: \.0) { label, color in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func placeholderText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
    }
}

/// 임베딩 지도: 2차원 산점도. 점 옆에 표제어를 붙이고, 탭한 지점에서 가장 가까운 개념을 연다.
private struct MapChart: View {
    let points: [ProjectedConcept]
    let onOpen: (Int64) -> Void

    /// 분야가 너무 많으면 범례 대신 단색으로 그린다.
    private var colorByField: Bool {
        Set(points.map { $0.field ?? "분야 없음" }).count <= 8
    }

    var body: some View {
        Chart(points) { point in
            if colorByField {
                mapPoint(point)
                    .foregroundStyle(by: .value("분야", point.field ?? "분야 없음"))
            } else {
                mapPoint(point)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(colorByField ? .visible : .hidden)
        .chartOverlay { proxy in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard let nearest = nearest(to: location, in: proxy) else { return }
                    onOpen(nearest.conceptId)
                }
        }
    }

    private func mapPoint(_ point: ProjectedConcept) -> some ChartContent {
        PointMark(
            x: .value("x", point.x),
            y: .value("y", point.y)
        )
        .annotation(position: .overlay, alignment: .bottom, spacing: 2) {
            Text(point.term)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// 탭 위치에서 가장 가까운 점(24pt 안). 데이터 값이 아니라 화면 좌표로 잰다.
    private func nearest(to location: CGPoint, in proxy: ChartProxy) -> ProjectedConcept? {
        var best: (point: ProjectedConcept, distance: CGFloat)?
        for point in points {
            guard let position = proxy.position(for: (x: point.x, y: point.y)) else { continue }
            let dx = position.x - location.x
            let dy = position.y - location.y
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance < 24, best == nil || distance < best!.distance {
                best = (point, distance)
            }
        }
        return best?.point
    }
}

/// 요약 카드 하나.
private struct StatCard: View {
    let title: String
    let value: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.bold))
                .monospacedDigit()
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}
