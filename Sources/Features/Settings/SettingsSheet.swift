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
// ベンダー中立(CLAUDE.md ビジョン2): プリセットはOpenAI互換の /v1 base URLを持ち、
// 選択されたwire APIに応じてResponsesまたはChat Completionsへ接続する。
import SwiftUI
import Kernel  // MCPEndpointPolicy(エンドポイント URL 検証の純関数)
import Services  // ServerRegistryStore / MCPServerEntry(MCP サーバー登録簿・M1)

/// LLM プロバイダのプリセット。base URL の既定値を埋めるだけ(キー・モデルは触らない)。
///
/// 各 URL はAPI種別に依存しない `/v1` base URL。
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
        case .openAI: return "https://api.openai.com/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .together: return "https://api.together.xyz/v1"
        // Ollama はローカル実行(http・localhost)。実機では Mac の LAN IP に手で直す前提だが、
        // まず既定として localhost を置く(シミュレータはホストの localhost に届く)。
        case .ollama: return "http://localhost:11434/v1"
        case .custom: return nil
        }
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
    @State private var isLoadingModels = false
    @State private var modelCatalogError: String?
    @State private var connectionSaveError: String?
    @State private var liteLLMPrices: [String: ModelPrice] = [:]

    var body: some View {
        NavigationStack {
            Form {
                serversSection
                presetSection
                savedCustomProvidersSection
                connectionSection
                modelSection
                telemetrySection
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
                        LLMReasoningEffort.normalize(store)
                        do {
                            try store.saveCurrentConnection()
                            home.applyInferenceSelection()
                            home.saveTelemetrySettings()
                            dismiss()
                        } catch {
                            connectionSaveError = error.localizedDescription
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
            // サーバー追加/編集フォーム(item ベース: 対象が決まったら提示・保存/キャンセルで nil に戻す)。
            // onDismiss で接続オーケストレータに反映(追加/URL 変更後に有効サーバーへ接続を試みる)。
            .sheet(
                item: $editingServer,
                onDismiss: { home.afterServerAddedOrEdited() },
                content: { target in ServerFormSheet(registry: registry, target: target) }
            )
            .task { await loadLiteLLMPrices() }
            .alert("接続を保存できません", isPresented: Binding(
                get: { connectionSaveError != nil },
                set: { if !$0 { connectionSaveError = nil } }
            )) {
                Button("OK", role: .cancel) { connectionSaveError = nil }
            } message: {
                Text(connectionSaveError ?? "入力内容を確認してください。")
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
            Text("プリセットは /v1 base URL の既定値を埋めます。API方式とモデルは接続先ごとに保存します。")
        }
    }

    @ViewBuilder
    private func presetChip(_ preset: LLMPreset) -> some View {
        let isSelected = preset == .custom
            ? store.selectedCustomProviderID != nil || store.isAddingCustomProvider
            : store.selectedPresetBaseURL == preset.baseURL
        Button {
            if let url = preset.baseURL {
                store.selectPreset(url)
            } else {
                store.beginAddingCustomProvider()
            }
            modelCatalogError = nil
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
        Section {
            apiStylePicker
            // base URL: 等幅・自動大文字化と自動修正を切る(URL 入力の定石)。
            TextField("https://api.openai.com/v1", text: $store.baseURL)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                // 固定プリセットのURLを書き換えて、そのプリセット用キーを別hostへ持ち越す経路を閉じる。
                // 任意URLは「カスタム接続を追加」から始めるとキーも空になる。
                .disabled(store.selectedPresetBaseURL != nil)

            // API キー: SecureField(伏せ字)。等幅で "sk-..." が読みやすいように。
            SecureField("sk-...", text: $store.apiKey)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("接続")
        } footer: {
            Text("ResponsesまたはChat Completionsを接続先ごとに選択します。base URLは /v1 までを入力してください。")
        }
    }

    // MARK: - モデル

    private var modelSection: some View {
        Section {
            NavigationLink {
                LLMModelListView(store: store, prices: liteLLMPrices)
            } label: {
                LabeledContent("利用可能なモデル", value: store.model)
            }
            NavigationLink {
                LLMReasoningEffortView(store: store)
            } label: {
                LabeledContent("Reasoning", value: LLMReasoningEffort.label(for: store.reasoningEffort))
            }
            Button {
                Task { await loadModels() }
            } label: {
                if isLoadingModels {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Label("接続先からモデルを取得", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isLoadingModels || !store.hasAPIKey)

            if let modelCatalogError {
                Text(modelCatalogError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("モデル")
        } footer: {
            Text("候補はOpenAI互換の /v1/models から取得し、接続先ごとに保存します。"
                + "一覧にないモデルも直接入力できます。価格はLiteLLMによる入力 / 出力100万tokenの概算です。"
                + "Reasoningの自動はreasoning_effortを送信しません。")
        }
    }

    /// backendを限定しないOTLP/HTTP traces endpointと任意headerを設定する。
    /// headerはSecureFieldで扱い、保存時にTelemetrySettingsStoreがKeychainへ移す。
    private var telemetrySection: some View {
        @Bindable var telemetry = home.telemetrySettings
        return Section {
            TextField("https://otel.example.com/v1/traces", text: $telemetry.endpoint)
                .font(.caption.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField("OTLP headers（name=value,name2=value2）", text: $telemetry.headers)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("OpenTelemetry")
        } footer: {
            Text("TracingをOTLP/HTTP protobufで送信します。認証headerはカンマ区切りで指定できます。"
                + "入力・応答・ツール入出力を含み、全トレースを記録します。")
        }
    }

    @MainActor
    private func loadLiteLLMPrices() async {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let pricingStore = PricingStore(baseDirectory: base.appendingPathComponent("pricing", isDirectory: true))
        await pricingStore.load()
        liteLLMPrices = pricingStore.snapshot()
    }

    @MainActor
    private func loadModels() async {
        guard let endpoint = URL(string: store.baseURL) else {
            modelCatalogError = "エンドポイントURLが不正です。"
            return
        }
        isLoadingModels = true
        modelCatalogError = nil
        defer { isLoadingModels = false }
        do {
            let models = try await OpenAICompatClient(baseURL: endpoint, apiKey: store.apiKey).listModels()
            store.updateAvailableModels(models.map(\.id))
        } catch {
            modelCatalogError = "モデル一覧を取得できません: \(error.localizedDescription)"
        }
    }
}

private extension SettingsSheet {
    /// 標準プリセットは固定chipのまま、ユーザーが保存したカスタム接続だけを別一覧にする。
    /// 選択後は直下の接続/モデル欄がそのprofileの編集フォームとして働く。
    var savedCustomProvidersSection: some View {
        Section {
            ForEach(store.savedCustomProviders) { provider in
                Button {
                    store.selectCustomProvider(id: provider.id)
                    modelCatalogError = nil
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName).foregroundStyle(.primary)
                            Text(provider.baseURL)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if store.selectedCustomProviderID == provider.id {
                            Image(systemName: "checkmark").fontWeight(.semibold)
                        }
                    }
                }
            }
            .onDelete { offsets in
                let ids = offsets.map { store.savedCustomProviders[$0].id }
                for id in ids {
                    store.deleteCustomProvider(id: id)
                }
            }

            Button {
                store.beginAddingCustomProvider()
                modelCatalogError = nil
            } label: {
                Label("カスタム接続を追加", systemImage: "plus.circle")
            }
        } header: {
            Text("保存済みカスタム接続")
        } footer: {
            Text("URLとAPIキーを入力して保存すると追加されます。行を選ぶと編集でき、左スワイプで削除できます。")
        }
    }
}
