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
import Kernel  // MCPEndpointPolicy(エンドポイント URL 検証の純関数)
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
    // 接続オーケストレータ(M2)。行の状態表示・トグル ON/OFF での接続/切断・削除時の切断を仲介する。
    var home: ChatHomeViewModel
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
            // onDismiss で接続オーケストレータに反映(追加/URL 変更後に有効サーバーへ接続を試みる)。
            .sheet(item: $editingServer, onDismiss: { home.afterServerAddedOrEdited() }) { target in
                ServerFormSheet(registry: registry, target: target)
            }
        }
    }

    // MARK: - MCP サーバー(M2・複数同時接続・トグルで有効/無効)

    private var serversSection: some View {
        Section {
            // 一覧: 各行 name + URL + 状態バッジ。行タップで詳細(状態・enabled トグル・tools 一覧)。
            ForEach(registry.servers) { entry in
                NavigationLink {
                    ServerDetailView(entry: entry, registry: registry, home: home)
                } label: {
                    serverRow(entry)
                }
            }
            // スワイプ削除。home.removeServer が接続を破棄し、該当 URL の OAuth トークンも
            // Keychain から消す(ServerRegistryStore.remove)。
            .onDelete { offsets in
                for index in offsets {
                    home.removeServer(id: registry.servers[index].id)
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
            Text("有効なサーバーには起動時に自動接続します(トークンが生きていればブラウザは出ません)。"
                + "認証が必要なサーバーは行を開いて接続できます。")
        }
    }

    /// サーバー1行(一覧)。名前 + 状態バッジ、下段に URL。状態は ConnectionsManager と連動。
    @ViewBuilder
    private func serverRow(_ entry: MCPServerEntry) -> some View {
        let state = home.connections.state(for: entry.id)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                if !entry.enabled {
                    ServerStateBadge(text: "無効", color: .secondary)
                } else {
                    ServerStateBadge.forState(state)
                }
            }
            Text(entry.url.absoluteString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
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

// MARK: - サーバー状態バッジ(M2・一覧/詳細で共有)

/// 接続状態の色付きバッジ(ready 緑 / needsAuth 橙 / connecting 灰 / failed 赤 / disconnected 灰)。
/// SettingsSheet の一覧行と ServerDetailView の両方で使うので独立 View に切り出した。
struct ServerStateBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }

    /// ConnectionsManager.State を色付きバッジへ写す(有効サーバー用)。
    @ViewBuilder
    static func forState(_ state: ConnectionsManager.State) -> some View {
        switch state {
        case .ready: ServerStateBadge(text: "接続済み", color: .green)
        case .connecting: ServerStateBadge(text: "接続中", color: .secondary)
        case .needsAuth: ServerStateBadge(text: "要認証", color: .orange)
        case .failed: ServerStateBadge(text: "失敗", color: .red)
        case .disconnected: ServerStateBadge(text: "未接続", color: .secondary)
        }
    }
}

// MARK: - サーバー詳細(M2・状態 + enabled トグル + tools ビューア)

/// 1サーバーの詳細。enabled トグル・接続状態・(要認証/失敗時の)接続ボタン・tools/list ビューアを出す。
/// tools は ConnectionsManager が接続時に取得済みの一覧(ReadyConnection.tools)を読む
/// (詳細画面から改めて tools/list を叩かない=二重の接続経路を作らない・M1 の footer 方針を継承)。
private struct ServerDetailView: View {
    let entry: MCPServerEntry
    var registry: ServerRegistryStore
    var home: ChatHomeViewModel

    @State private var editing = false

    var body: some View {
        let state = home.connections.state(for: entry.id)
        Form {
            Section {
                // enabled トグル。ON で無言接続・OFF で切断(home.setServerEnabled が両方を仲介)。
                Toggle("有効", isOn: Binding(
                    get: { currentEntry?.enabled ?? entry.enabled },
                    set: { home.setServerEnabled(id: entry.id, enabled: $0) }
                ))
                HStack {
                    Text("状態")
                    Spacer()
                    if (currentEntry?.enabled ?? entry.enabled) {
                        ServerStateBadge.forState(state)
                    } else {
                        ServerStateBadge(text: "無効", color: .secondary)
                    }
                }
                // 要認証/失敗は「接続」ボタンで対話接続(ブラウザ)を出す。
                if case .needsAuth = state {
                    Button("認証して接続") { home.connectInteractively(serverID: entry.id) }
                } else if case .failed(let message) = state {
                    Button("再接続を試みる") { home.connectInteractively(serverID: entry.id) }
                    Text(message)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(entry.url.absoluteString)
                    .font(.caption.monospaced())
                    .textCase(nil)
            }

            // tools/list ビューア(接続済みのときだけ)。app 専用ツールにはバッジを出す。
            if case .ready(let ready) = state {
                Section {
                    ForEach(Array(ready.tools.enumerated()), id: \.offset) { _, tool in
                        toolRow(tool)
                    }
                } header: {
                    Text("ツール(\(ready.tools.count))")
                }
            }

            Section {
                Button("名前・URL を編集") { editing = true }
                Button("このサーバーを削除", role: .destructive) {
                    home.removeServer(id: entry.id)
                }
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing, onDismiss: { home.afterServerAddedOrEdited() }) {
            ServerFormSheet(registry: registry, target: .edit(entry))
        }
    }

    /// registry の最新エントリ(トグル反映を即時に読むため id で引き直す)。無ければ nil。
    private var currentEntry: MCPServerEntry? {
        registry.servers.first(where: { $0.id == entry.id })
    }

    /// tools/list の1行。ツール名 + 説明。LLM に見せないツール(visibility に "model" を含まない)は
    /// 「app 専用」バッジを付ける(apps.mdx:400 で LLM 一覧から除外されるものの可視化)。
    @ViewBuilder
    private func toolRow(_ tool: Tool) -> some View {
        // isToolModelVisible は _meta.ui の JSONValue 変換で throw しうる(実データでは起きない)。
        // 変換に失敗したら「モデルに見せる(既定)」側へ倒す(ツールが理由不明に app 専用扱いされない)。
        let modelVisible = (try? isToolModelVisible(tool)) ?? true
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(tool.name)
                    .font(.callout.monospaced())
                if !modelVisible {
                    ServerStateBadge(text: "app 専用", color: .purple)
                }
            }
            if let description = tool.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
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
    @State private var hasURLFieldBlurred = false
    @FocusState private var isURLFieldFocused: Bool

    init(registry: ServerRegistryStore, target: ServerFormTarget) {
        self.registry = registry
        self.target = target
        // 編集なら既存値を初期表示し、新規はどちらも空から始める。
        // URL の一部を先回りして埋めると、フル URL のペーストを邪魔するうえ、未操作なのに
        // エラー状態を作ってしまう。入力欄はユーザーの値だけを保持し、要件は保存可否で示す。
        switch target {
        case .add:
            _name = State(initialValue: "")
            _urlString = State(initialValue: "")
        case .edit(let entry):
            _name = State(initialValue: entry.name)
            _urlString = State(initialValue: entry.url.absoluteString)
        }
    }

    /// URL 欄の検証結果(成功なら登録する URL、失敗なら理由)。
    ///
    /// 判定ロジックは Kernel の純関数 `MCPEndpointPolicy` に移した(2026-07-22)。ここに
    /// インラインで `URL(string:) + scheme == "https" + host != nil` を書いていた頃、
    /// 二重スキームの "https://http://..." が
    /// **バリデーションを通過して保存できてしまう**バグを実機で踏んだため
    /// (経緯の詳細は MCPEndpointPolicy.swift 冒頭)。UI から切り離してテストで固定する。
    private var urlValidation: Result<URL, MCPEndpointPolicy.Rejection> {
        MCPEndpointPolicy.resolve(urlString: urlString)
    }

    private var validURL: URL? {
        try? urlValidation.get()
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && validURL != nil
    }

    /// 拒否理由 → ユーザーに出す日本語。文言は UI の関心なので Kernel には置かず
    /// (Kernel は Rejection の列挙までが責務)、ここで対応付ける。
    /// 二重スキームだけは「何をしてしまったか」を名指しする。フォーム側でプリフィルは
    /// 廃止したが、キーボード編集や外部からのコピーで不正 URL が入る可能性は残るため、
    /// Policy の防御と具体的な案内は維持する。
    private static func message(for rejection: MCPEndpointPolicy.Rejection) -> String {
        switch rejection {
        case .empty:
            return "エンドポイント URL を入力してください。"
        case .doubleScheme:
            return "URL にスキーム(https:// など)が2つ含まれています。URL 全体を貼り直してください。"
        case .notHTTPS:
            return "https:// で始まる URL を入力してください(http は使えません)。"
        case .invalidHost:
            return "URL のホスト名が正しくありません。"
        case .malformed:
            return "有効な URL を入力してください。"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名前") {
                    TextField("表示名", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    TextField("URL", text: $urlString)
                        .font(.callout.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($isURLFieldFocused)
                        .submitLabel(.done)
                        .onSubmit { isURLFieldFocused = false }
                        .onChange(of: isURLFieldFocused) { wasFocused, isFocused in
                            // 入力前・入力途中に赤字を出さない。非空の値をいったん入力し、
                            // URL 欄を離れた時点ではじめて保存不可の理由を知らせる。
                            if wasFocused,
                               !isFocused,
                               !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                hasURLFieldBlurred = true
                            }
                        }
                } header: {
                    Text("エンドポイント URL")
                } footer: {
                    // 正常時の補足説明は置かない。エラーも「非空のまま blur 済み」に限り、
                    // 保存ボタンが無効な理由が必要になったときだけ表示する。
                    if hasURLFieldBlurred,
                       !isURLFieldFocused,
                       !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       case .failure(let rejection) = urlValidation,
                       rejection != .empty {
                        Text(Self.message(for: rejection))
                            .foregroundStyle(.red)
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
