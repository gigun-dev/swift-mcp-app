// チャット主画面(T4-B)。通常起動のルート。状態(needsSetup/connecting/ready/failed)に応じて
// 接続前ゲート / プログレス / チャット本体を出し分け、ナビバーに model chip と設定ボタンを置く。
//
// モック対応(chat-v1.html「1. チャット本体」のナビバー):
//  - h1("caldav")→ NavigationTitle(接続先の短縮名。今は固定文字列)。
//  - model-chip(●Gemini Flash‑Lite)→ ツールバー左の丸チップ(現在モデル名)。
//  - gear(⚙︎)→ 設定ボタン(SettingsSheet を presentation)。
//  - compose(✎)/ history(☰)→ T6(履歴・新規)なので今回は置かない。
//
// 接続前ゲート・接続中プログレスはモックに無い(モックは接続済み状態のみ描く)が、
// タスク指示で要求されている(接続ボタン + 設定ボタン / プログレス)。デバッグ画面ではなく
// 本番導線なので、SwiftUI 標準の素直な見た目にする(モックのトーンから逸脱しない範囲)。
import SwiftUI

struct ChatHomeView: View {
    // 設定は Home と Sheet で共有する1インスタンス。@State で所有(@Observable を SwiftUI が観測)。
    // 初期値は init で注入する(settings を home にも渡す必要があるため既定式は置かない)。
    @State private var settings: LLMSettingsStore
    @State private var home: ChatHomeViewModel
    @State private var showingSettings = false

    init() {
        // settings を先に作り、それを home に注入する。@State の init 直接代入は
        // _settings/_home を使う(SwiftUI の @State init パターン)。
        let settings = LLMSettingsStore()
        _settings = State(initialValue: settings)
        _home = State(initialValue: ChatHomeViewModel(settings: settings))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("caldav")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { modelChip }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(store: settings)
        }
        // デバッグ用自動接続(MCPHOST_AUTOCONNECT=1)。ConnectionView と同じ導線。
        .onAppear { home.autoConnectIfRequested() }
    }

    // MARK: - 状態別コンテンツ

    @ViewBuilder
    private var content: some View {
        switch home.state {
        case .needsSetup:
            setupGate
        case .connecting:
            // OAuth の対話(ブラウザのシート)が出る旨を添える(人手が要る合図)。
            VStack(spacing: 12) {
                ProgressView()
                Text("接続中…(ブラウザのシートが出ます・パスワード changeme)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        case .ready(let chatVM):
            ChatBodyView(chatVM: chatVM)
        case .failed(let message):
            failedView(message)
        }
    }

    /// 接続前ゲート: 接続ボタン + 設定ボタン(タスク指示)。
    private var setupGate: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("MCP サーバーに接続してチャットを始めます。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // キー未設定の注意(接続しても LLM 呼び出しで失敗するため先に促す)。
            if !settings.hasAPIKey {
                Text("API キーが未設定です。まず設定でキーを入力してください。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            Button {
                home.connect()
            } label: {
                Text("接続")
                    .fontWeight(.semibold)
                    .frame(maxWidth: 220)
            }
            .buttonStyle(.borderedProminent)

            Button("設定") { showingSettings = true }
                .font(.callout)
        }
        .padding()
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text("接続に失敗しました")
                .font(.headline)
            // 詳細はデバッグしやすさ優先でそのまま(ConnectionView と同方針)。
            Text(message)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("再試行") { home.connect() }
                .buttonStyle(.bordered)
            Button("設定") { showingSettings = true }
                .font(.callout)
        }
        .padding()
    }

    // MARK: - model chip(モックの .model-chip)

    private var modelChip: some View {
        HStack(spacing: 5) {
            // 接続状態を色で示す(ready=緑・それ以外=グレー)。モックの緑ドットに対応。
            Circle()
                .fill(isReady ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            Text(settings.model)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(Color(.separator), lineWidth: 1))
    }

    private var isReady: Bool {
        if case .ready = home.state { return true }
        return false
    }
}

#Preview {
    ChatHomeView()
}
