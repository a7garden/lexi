import SwiftUI

/// 전체 사전 화면 (목업 #6). 이번 스켈레톤은 구조 셸만 — 실제 목록·상세는 다음 마일스톤.
struct LibraryView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Section("라이브러리") {
                    Label("모든 항목", systemImage: "books.vertical")
                    Label("최근 조회", systemImage: "clock")
                    Label("즐겨찾기", systemImage: "star")
                    Label("확인 있음", systemImage: "checkmark.seal")
                    Label("내가 수정한 항목", systemImage: "pencil.line")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            ContentUnavailableView(
                "아직 항목이 없어요",
                systemImage: "book.closed",
                description: Text("앱 밖에서 모르는 단어를 선택해 조회하면 여기에 쌓입니다.")
            )
        }
        .navigationTitle("Lexi")
    }
}
