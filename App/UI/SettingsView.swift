import SwiftUI

/// 설정 (목업 #8). AI 제공자: 내장 MLX(Apple Silicon) 기본. 외부 API는 기본 비활성.
/// 설계 규칙: 웹 조사는 별도 동의.
struct SettingsView: View {
    @AppStorage("mlxModelID") private var mlxModelID = "mlx-community/Qwen3-4B-4bit"
    @AppStorage("webResearchAllowed") private var webResearchAllowed = false

    var body: some View {
        Form {
            Section("AI 제공자") {
                Picker("제공 방식", selection: .constant("mlx")) {
                    Text("내장 모델 (MLX · Apple Silicon)").tag("mlx")
                    Text("외부 API (OpenAI·Claude 등)").tag("external").disabled(true)
                }
                TextField("모델 (mlx-community HuggingFace ID)", text: $mlxModelID)
                Text("모델 파일은 첫 생성 시 HuggingFace에서 내려받아 로컬에서 실행됩니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("웹 조사") {
                Toggle("새 개념 조회 시 공개 자료 검색 허용", isOn: $webResearchAllowed)
                Text("끄면 로컬 모델 지식만으로 초안을 만들고, 결과는 'AI 초안 · 외부 출처 없음'으로 표시됩니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("설정 변경은 앱을 다시 시작하면 적용됩니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .formStyle(.grouped)
    }
}
