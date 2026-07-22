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
import Services  // ServerRegistryStore / MCPServerEntry(MCP サーバー登録簿・M1)

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
    // MCP サーバー登録簿(M1)。LLM 設定と同じシートに「MCP サーバー」セクションを同居させる
    // ——「接続に関わる設定」を1シートに集約する(サーバーと LLM の両方が接続の材料)。
    var registry: ServerRegistryStore
    @Environment(\.dismiss) private var dismiss

    // サーバー追加/編集フォームの提示状態。nil = 非表示、非 nil = そのエントリを編集
    // (新規は id 未確定の下書き。ServerFormSheet 側で add / update を出し分ける)。
    @State private var editingServer: ServerFormTarget?

    var body: some View {
        NavigationStack {
            Form {
                serversSection
                presetSection
                connectionSection
                modelSection
            }
            .navigationTitle("設定")
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
            // サーバー追加/編集フォーム(item ベース: 対象が決まったら提示・保存/キャンセルで nil に戻す)。
            .sheet(item: $editingServer) { target in
                ServerFormSheet(registry: registry, target: target)
            }
        }
    }

    // MARK: - MCP サーバー(M1・複数登録して切替)

    private var serversSection: some View {
        Section {
            // 一覧: 各行 name + URL。タップで編集(rename / URL 変更)。スワイプで削除。
            ForEach(registry.servers) { entry in
                Button {
                    editingServer = .edit(entry)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(entry.name)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.primary)
                            // 選択中(次の新規チャットの既定)を控えめに示す。
                            if entry.id == registry.selectedServerID {
                                Text("選択中")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        Text(entry.url.absoluteString)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .buttonStyle(.plain)
            }
            // スワイプ削除。remove は該当 URL の OAuth トークンも Keychain から消す(ServerRegistryStore)。
            .onDelete { offsets in
                for index in offsets {
                    registry.remove(id: registry.servers[index].id)
                }
            }

            // 追加行。id 未確定の下書き(.add)を提示する。
            Button {
                editingServer = .add
            } label: {
                Label("サーバーを追加", systemImage: "plus.circle")
            }
        } header: {
            Text("MCP サーバー")
        } footer: {
            // 接続テストをここでやらない理由(タスク指示・二重の接続経路を作らない)を言語化。
            Text("チャットのタイトルから接続先を切り替えられます。接続(OAuth 認可)は"
                + "そのサーバーで最初にチャットを始めたときに走ります。")
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

// MARK: - サーバー追加/編集フォーム(M1)

/// フォームの対象。`.add` は新規(id 未確定)、`.edit` は既存エントリの編集。
/// Identifiable: SettingsSheet の `.sheet(item:)` に渡すため。id はフォーム提示の識別に使うだけで、
/// 新規は固定の zero UUID(同時に2枚出さない前提で衝突しない)。
enum ServerFormTarget: Identifiable {
    case add
    case edit(MCPServerEntry)

    var id: UUID {
        switch self {
        case .add: return UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        case .edit(let entry): return entry.id
        }
    }
}

/// サーバーの name / URL を入力するフォームシート(追加と編集を兼ねる)。
///
/// URL は **https 必須のバリデーション**(タスク指示)。接続テストや OAuth はここでしない
/// (二重の接続経路を作らない・接続は次のチャット開始時に既存フローで走る)。保存で
/// registry.add / update を呼び、次回チャットの接続先候補に載せるだけ。
private struct ServerFormSheet: View {
    var registry: ServerRegistryStore
    let target: ServerFormTarget
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var urlString: String

    init(registry: ServerRegistryStore, target: ServerFormTarget) {
        self.registry = registry
        self.target = target
        // 編集なら既存値を初期表示、新規なら空(URL は https:// を種として置き、入力の手間を減らす)。
        switch target {
        case .add:
            _name = State(initialValue: "")
            _urlString = State(initialValue: "https://")
        case .edit(let entry):
            _name = State(initialValue: entry.name)
            _urlString = State(initialValue: entry.url.absoluteString)
        }
    }

    /// 入力が妥当か: name 非空 + https スキームの URL としてパースできる。
    /// http を弾く理由: MCP Apps の OAuth 前提(本番エンドポイントは https)。ローカル平文 http が
    /// 要るケースは今は無い(あれば緩める余地を残すが、既定は安全側の https 必須)。
    private var validURL: URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && validURL != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名前") {
                    TextField("caldav", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    TextField("https://example.com/mcp", text: $urlString)
                        .font(.callout.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("エンドポイント URL")
                } footer: {
                    // https 必須の理由をその場で示す(バリデーション失敗時の手掛かり)。
                    if !urlString.isEmpty && validURL == nil {
                        Text("https:// で始まる有効な URL を入力してください。")
                            .foregroundStyle(.red)
                    } else {
                        Text("MCP サーバーの /mcp エンドポイント。https 必須。")
                    }
                }
            }
            .navigationTitle(isEditing ? "サーバーを編集" : "サーバーを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
        }
    }

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private func save() {
        guard let url = validURL else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch target {
        case .add:
            registry.add(name: trimmedName, url: url)
        case .edit(let entry):
            registry.update(id: entry.id, name: trimmedName, url: url)
        }
        dismiss()
    }
}
