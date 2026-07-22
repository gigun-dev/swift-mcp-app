// MCP サーバー設定の詳細・編集 UI。
// LLM 設定を扱う SettingsSheet から、サーバー1件の状態表示と入力フォームを責務単位で分離する。
import SwiftUI
import Kernel
import Services

/// 接続状態の色付きバッジ。一覧と詳細で同じ語彙・色を共有する。
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

/// 1サーバーの状態・有効化・ツール一覧を表示する。接続操作は home に集約する。
struct ServerDetailView: View {
    let entry: MCPServerEntry
    var registry: ServerRegistryStore
    var home: ChatHomeViewModel
    @State private var editing = false

    var body: some View {
        let state = home.connections.state(for: entry.id)
        Form {
            connectionSection(state)
            if case .ready(let ready) = state {
                toolsSection(ready)
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
        .sheet(
            isPresented: $editing,
            onDismiss: { home.afterServerAddedOrEdited() },
            content: { ServerFormSheet(registry: registry, target: .edit(entry)) }
        )
    }

    @ViewBuilder
    private func connectionSection(_ state: ConnectionsManager.State) -> some View {
        Section {
            Toggle("有効", isOn: Binding(
                get: { currentEntry?.enabled ?? entry.enabled },
                set: { home.setServerEnabled(id: entry.id, enabled: $0) }
            ))
            HStack {
                Text("状態")
                Spacer()
                if currentEntry?.enabled ?? entry.enabled {
                    ServerStateBadge.forState(state)
                } else {
                    ServerStateBadge(text: "無効", color: .secondary)
                }
            }
            if case .needsAuth = state {
                Button("認証して接続") { home.connectInteractively(serverID: entry.id) }
            } else if case .failed(let message) = state {
                Button("再接続を試みる") { home.connectInteractively(serverID: entry.id) }
                Text(message).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        } header: {
            Text(entry.url.absoluteString).font(.caption.monospaced()).textCase(nil)
        }
    }

    private func toolsSection(_ ready: ReadyConnection) -> some View {
        Section {
            ForEach(Array(ready.tools.enumerated()), id: \.offset) { _, tool in
                toolRow(tool)
            }
        } header: {
            Text("ツール(\(ready.tools.count))")
        }
    }

    private var currentEntry: MCPServerEntry? {
        registry.servers.first(where: { $0.id == entry.id })
    }

    @ViewBuilder
    private func toolRow(_ tool: Tool) -> some View {
        // metadata 変換失敗時は、理由なく app 専用扱いしないよう model-visible 側へ倒す。
        let modelVisible = (try? isToolModelVisible(tool)) ?? true
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(tool.name).font(.callout.monospaced())
                if !modelVisible { ServerStateBadge(text: "app 専用", color: .purple) }
            }
            if let description = tool.description, !description.isEmpty {
                Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }
}

/// `.add` は空の新規フォーム、`.edit` は既存値を下書きへ渡す。
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

/// サーバー名と HTTPS endpoint を追加・編集するフォーム。
struct ServerFormSheet: View {
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
        // 新規時の URL プリフィルは、ペーストを妨げ未操作エラーを作るため置かない。
        switch target {
        case .add:
            _name = State(initialValue: "")
            _urlString = State(initialValue: "")
        case .edit(let entry):
            _name = State(initialValue: entry.name)
            _urlString = State(initialValue: entry.url.absoluteString)
        }
    }

    private var urlValidation: Result<URL, MCPEndpointPolicy.Rejection> {
        MCPHostBuildPolicy.resolveEndpoint(urlString)
    }

    private var validURL: URL? { try? urlValidation.get() }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && validURL != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名前") {
                    TextField("表示名", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                endpointSection
            }
            .navigationTitle(isEditing ? "サーバーを編集" : "サーバーを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.fontWeight(.semibold).disabled(!canSave)
                }
            }
        }
    }

    private var endpointSection: some View {
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
                    if wasFocused, !isFocused, !trimmedURL.isEmpty { hasURLFieldBlurred = true }
                }
        } header: {
            Text("エンドポイント URL")
        } footer: {
            // 入力中は叱らず、非空のままフォーカスを離れた後だけ保存不可理由を示す。
            if hasURLFieldBlurred,
               !isURLFieldFocused,
               !trimmedURL.isEmpty,
               case .failure(let rejection) = urlValidation,
               rejection != .empty {
                Text(Self.message(for: rejection)).foregroundStyle(.red)
            }
        }
    }

    private var trimmedURL: String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private static func message(for rejection: MCPEndpointPolicy.Rejection) -> String {
        switch rejection {
        case .empty: return "エンドポイント URL を入力してください。"
        case .doubleScheme: return "URL にスキーム(https:// など)が2つ含まれています。URL 全体を貼り直してください。"
        case .notHTTPS:
            return MCPHostBuildPolicy.allowInsecureLoopback
                ? "https://、または開発用の localhost URL を入力してください。"
                : "https:// で始まる URL を入力してください(http は使えません)。"
        case .invalidHost: return "URL のホスト名が正しくありません。"
        case .malformed: return "有効な URL を入力してください。"
        }
    }

    private func save() {
        guard let url = validURL else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch target {
        case .add: registry.add(name: trimmedName, url: url)
        case .edit(let entry): registry.update(id: entry.id, name: trimmedName, url: url)
        }
        dismiss()
    }
}
