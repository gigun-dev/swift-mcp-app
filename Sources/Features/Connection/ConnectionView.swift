// P1「接続(MVP フェーズ1)」の素朴な開発用画面。
//
// これはモック合意プロセス(CLAUDE.md「UI はモックで合意してから実装」)の対象ではない ——
// あくまで「OAuth で本番 /mcp に繋がって tools/list が返る」ことを目視確認するための
// デバッグ用途の最小画面。todos v3 / agenda カードのような UI 文法を写す本番画面は
// P2(MCP Apps ホストスパイク)以降、WKWebView 側で実現される想定(docs/next-directions.md
// 路線B)なので、ここでネイティブ SwiftUI の見た目を作り込む投資はしない。
import SwiftUI

struct ConnectionView: View {
    @StateObject private var viewModel = ConnectionViewModel()

    var body: some View {
        NavigationStack {
            form
        }
        // デバッグ用自動接続(MCPHOST_AUTOCONNECT=1)。simctl launch --setenv だけで
        // OAuth E2E を人手のタップなしで再現するための入口(ViewModel 側コメント参照)。
        .onAppear { viewModel.autoConnectIfRequested() }
    }

    private var form: some View {
        Form {
                Section("MCP サーバー") {
                    TextField("https://example.com/mcp", text: $viewModel.serverURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isConnecting)

                    Button(connectButtonTitle) {
                        viewModel.connectTapped()
                    }
                    .disabled(isConnecting)
                }

                switch viewModel.state {
                case .idle:
                    EmptyView()

                case .connecting:
                    Section {
                        HStack {
                            ProgressView()
                            Text("認可待ち…(ブラウザのシートが出ます)")
                        }
                    }

                case .connected(let tools):
                    Section("tools/list (\(tools.count))") {
                        if tools.isEmpty {
                            Text("ツールが0件でした。")
                        }
                        ForEach(tools, id: \.name) { tool in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name)
                                    .font(.body.monospaced())
                                if let description = tool.description, !description.isEmpty {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                case .failed(let message):
                    // エラーはそのまま文字列表示(タスク指示: デバッグしやすさ優先)。
                    // ユーザーフレンドリーな文言への整形は本番 UI(P2 以降)で検討する。
                    Section("エラー") {
                        Text(message)
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                    }
                }
        }
        .navigationTitle("MCPHost")
        // swift-format 相当の再インデントは P0 で lint 未導入のため保留(Form 内の
        // インデントが1段深いのは切り出し時の名残・動作に影響なし)
        // (旧: body 直下に Form をベタ書きしていたが、onAppear の自動接続フックを
        // NavigationStack の外に付けるため form を切り出した。navigationTitle は
        // NavigationStack 配下のこの Form に付ける)
    }

    private var isConnecting: Bool {
        if case .connecting = viewModel.state { return true }
        return false
    }

    private var connectButtonTitle: String {
        switch viewModel.state {
        case .connected: return "再接続"
        case .failed: return "再試行"
        default: return "接続"
        }
    }
}

#Preview {
    ConnectionView()
}
