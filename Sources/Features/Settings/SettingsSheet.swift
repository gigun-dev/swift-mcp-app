// BYOK 設定シート(T4-A・モック chat-v1.html の「2. BYOK 設定シート」を SwiftUI 化)。
//
// モック対応(chat-v1.html:246-290):
//  - sheet-head(キャンセル / "LLM 設定" / 保存)→ NavigationStack + toolbar の
//    cancellationAction / confirmationAction。iOS 標準のシート文法に落とす(モックの
//    自前ヘッダは HTML の都合で、SwiftUI では navigationBar が同じ役割)。
//  - プリセット chips(OpenRouter/Groq/Together/Ollama/カスタム)→ 横スクロールの chip 行。
//    タップで base URL を差し替える(モックの hint「プリセットは base URL の既定値を埋めるだけ」)。
//  - 接続セクション(base URL / API キー)→ Form の Section + TextField / SecureField。
//  - モデルセクション(モデル + コスト帯バッジ)→ TextField + 軽量バッジ。
//
// ベンダー中立(CLAUDE.md ビジョン2): プリセットは「OpenAI 互換 /chat/completions」を話す
// ゲートウェイを横断で選べることの可視化。どれも OpenAICompatClient で繋がる(caldav 固有知識ゼロ)。
import SwiftUI

/// LLM プロバイダのプリセット。base URL の既定値を埋めるだけ(キー・モデルは触らない)。
///
/// 各 URL は「chat/completions までのフル URL」(OpenAICompatClient.baseURL の仕様)。
/// プロバイダによって /v1 の有無・ホストが違うので、ここに妥当な既定を1つずつ置く
/// (2026-07 時点の各社 OpenAI 互換エンドポイント。陳腐化したらここを直す)。
private enum LLMPreset: String, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    case openRouter = "OpenRouter"
    case groq = "Groq"
    case together = "Together"
    case ollama = "Ollama(ローカル)"
    case custom = "カスタム"

    var id: String { rawValue }

    /// このプリセットが埋める base URL。custom は「差し替えない」印として nil。
    var baseURL: String? {
        switch self {
        case .openAI: return "https://api.openai.com/v1/chat/completions"
        case .openRouter: return "https://openrouter.ai/api/v1/chat/completions"
        case .groq: return "https://api.groq.com/openai/v1/chat/completions"
        case .together: return "https://api.together.xyz/v1/chat/completions"
        // Ollama はローカル実行(http・localhost)。実機では Mac の LAN IP に手で直す前提だが、
        // まず既定として localhost を置く(シミュレータはホストの localhost に届く)。
        case .ollama: return "http://localhost:11434/v1/chat/completions"
        case .custom: return nil
        }
    }

    /// 現在の base URL 文字列から、どのプリセットが選択中かを逆引きする。
    /// どれとも一致しなければ「カスタム」(ユーザーが手で書き換えた状態)。
    static func matching(baseURL: String) -> LLMPreset {
        allCases.first { $0.baseURL == baseURL } ?? .custom
    }
}

/// BYOK 設定シート。`store` を直接束縛して編集し、「保存」で store.save() を呼ぶ。
///
/// 編集中の値は store のメモリ値をそのまま書き換える(別の下書きバッファを持たない)。
/// キャンセルで破棄したい要求は今は無い(モックにも下書き破棄の概念はない)ので、
/// シンプルに store を直接編集する。将来「キャンセルで元に戻す」が要れば onAppear で
/// スナップショットを取る形に変える余地を残す。
struct SettingsSheet: View {
    @Bindable var store: LLMSettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                presetSection
                connectionSection
                modelSection
            }
            .navigationTitle("LLM 設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // キャンセル: 保存せず閉じる(store のメモリ値は変わったままだが、
                    // 未保存なら次回起動時に永続値が復元される。厳密な下書き破棄は上記コメント参照)。
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - プリセット chips

    private var presetSection: some View {
        Section {
            // 横スクロールの chip 行(モックの .preset-chips)。Form の行内に横スクロールを埋める。
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LLMPreset.allCases) { preset in
                        presetChip(preset)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("プリセット")
        } footer: {
            // モックの hint をそのまま(ベンダー中立の価値を言語化する)。
            Text("プリセットは base URL の既定値を埋めるだけ。OpenAI 互換(/chat/completions + tools)なら"
                + "どのプロバイダでも繋がる — ベンダーに縛られない。")
        }
    }

    @ViewBuilder
    private func presetChip(_ preset: LLMPreset) -> some View {
        let isSelected = LLMPreset.matching(baseURL: store.baseURL) == preset
        Button {
            // custom は「今の base URL を触らない」(ユーザーの手入力を尊重)。
            if let url = preset.baseURL {
                store.baseURL = url
            }
        } label: {
            Text(preset.rawValue)
                .font(.footnote)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isSelected ? Color.accentColor.opacity(0.14) : Color(.secondarySystemBackground))
                )
                .overlay(
                    Capsule().strokeBorder(isSelected ? Color.accentColor : Color(.separator), lineWidth: 1)
                )
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 接続(base URL / API キー)

    private var connectionSection: some View {
        Section("接続") {
            // base URL: 等幅・自動大文字化と自動修正を切る(URL 入力の定石)。
            TextField("https://api.openai.com/v1/chat/completions", text: $store.baseURL)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            // API キー: SecureField(伏せ字)。等幅で "sk-..." が読みやすいように。
            SecureField("sk-...", text: $store.apiKey)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    // MARK: - モデル

    private var modelSection: some View {
        Section {
            HStack {
                TextField("gpt-5.4-mini", text: $store.model)
                    .font(.callout.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Spacer(minLength: 8)
                // モックの cost-badge low(軽量・低コスト)。既定が軽量モデルであることの可視化。
                // 単価判定(T7)はまだ無いので固定バッジ。将来 CostEstimator で帯を出し分ける。
                Text("軽量・低コスト")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.14)))
                    .foregroundStyle(Color.green)
            }
        } header: {
            Text("モデル")
        } footer: {
            Text("既定は軽量モデル。tool-use は毎ターン ツール定義(caldav ≈18件)を送るため"
                + "トークン費が乗る — コスト重視なら軽量モデルを推奨。必要なタスクだけ上位モデルに切り替え可。")
        }
    }
}
