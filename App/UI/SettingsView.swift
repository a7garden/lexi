import SwiftUI

/// 설정 (목업 #8). AI 제공자 선택: Ollama → MLX 내장 → 외부 API(기본 비활성).
/// 이번 스켈레톤은 Ollama 연결 값만. 어댑터 연결과 실행 위치 구분은 다음 마일스톤.
struct SettingsView: View {
    @AppStorage("ollamaBaseURL") private var ollamaBaseURL = "http://localhost:11434"
    @AppStorage("ollamaModel") private var ollamaModel = ""

    var body: some View {
        Form {
            Section("AI 제공자") {
                Picker("제공 방식", selection: .constant("ollama")) {
                    Text("로컬 모델 (Ollama)").tag("ollama")
                    Text("내장 모델 (MLX)").tag("mlx").disabled(true)
                    Text("외부 API (OpenAI·Claude 등)").tag("external").disabled(true)
                }
                TextField("서버 주소", text: $ollamaBaseURL)
                TextField("모델 (예: llama3.1:8b)", text: $ollamaModel)
            }
            Section {
                Text("웹 조사는 별도 동의 후 활성화됩니다. 로컬 주소라도 실제 계산 위치는 설정에서 확인하세요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .formStyle(.grouped)
    }
}
