// チャット主画面(T4-B)。通常起動のルート。状態(needsSetup/connecting/ready/failed)に応じて
// 接続前ゲート / プログレス / チャット本体を出し分け、ナビバーに model chip と設定ボタンを置く。
//
// モック対応(chat-v1.html「1. チャット本体」のナビバー):
//  - h1("caldav")→ NavigationTitle(接続先の短縮名。今は固定文字列)。
//  - model-chip(●Gemini Flash‑Lite)→ ツールバー左の丸チップ(現在モデル名)。
//  - gear(⚙︎)→ 設定ボタン(SettingsSheet を presentation)。
//  - history(☰)→ 履歴サイドバーを引き出す(topBarLeading)。T6 後半で追加。
//  - compose(✎)→ 新規チャット(topBarTrailing・gear と並べる)。T6 後半で追加。
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
    // 履歴サイドバー(引き出し)の開閉。ZStack + offset の overlay drawer で見せる(下の drawer 参照)。
    @State private var showingSidebar = false

    init() {
        // settings を先に作り、それを home に注入する。@State の init 直接代入は
        // _settings/_home を使う(SwiftUI の @State init パターン)。
        let settings = LLMSettingsStore()
        _settings = State(initialValue: settings)
        _home = State(initialValue: ChatHomeViewModel(settings: settings))
    }

    var body: some View {
        NavigationStack {
            // drawer を素直に動かすため ZStack で本体の上にサイドバーを重ねる(下の drawer 参照)。
            ZStack(alignment: .leading) {
                routedContent
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { toolbarContent }
                drawer
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(store: settings)
        }
        // 履歴読み込み失敗(タスク指示・握りつぶさない)。VM が historyLoadError に載せたら見せる。
        .alert(
            "履歴を開けませんでした",
            isPresented: Binding(
                get: { home.historyLoadError != nil },
                // ユーザーが閉じたら文言をクリアする(これを呼ばないと非 nil のままアラートが
                // 再提示され続ける)。
                set: { if !$0 { home.clearHistoryLoadError() } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(home.historyLoadError ?? "")
        }
        // デバッグ用自動接続(MCPHOST_AUTOCONNECT=1)。ConnectionView と同じ導線。
        .onAppear { home.autoConnectIfRequested() }
    }

    // MARK: - ツールバー(モックのナビバー)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // 左: 履歴閲覧中は「戻る」(ライブへ)、通常は ☰(履歴サイドバーを開く)。
        // モックはナビバー左に ☰(history-btn)。履歴詳細を開いたときだけ戻る導線に切り替える。
        ToolbarItem(placement: .topBarLeading) {
            if isViewingHistory {
                Button {
                    home.returnToLive()
                } label: {
                    Label("戻る", systemImage: "chevron.left")
                }
            } else {
                Button {
                    // トグル: 開いていれば畳む(ユーザー指摘「もう一度押したら畳まれるべき」)。
                    withAnimation(.easeOut(duration: 0.22)) { showingSidebar.toggle() }
                } label: {
                    Image(systemName: "line.3.horizontal")
                }
            }
        }
        // 中央: 接続先 + モデル名(履歴閲覧中は下の routedContent 側で navigationTitle が勝つが、
        // ライブ時はこの principal を出す。履歴詳細は自前の navigationTitle を持つ)。
        ToolbarItem(placement: .principal) {
            if !isViewingHistory { titleAndModel }
        }
        // 右: 新規チャット(compose)+ 設定(gear)。モックは右に compose/gear 系。
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 2) {
                Button {
                    home.newChat()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
    }

    // MARK: - 表示モードでのルーティング(ライブ / 履歴閲覧)

    /// displayMode で本体を出し分ける。`.viewingHistory` は読み取り専用の HistoryDetailView
    /// (副作用ゼロ・設計 §5)。`.live` は既存の状態別コンテンツ。
    @ViewBuilder
    private var routedContent: some View {
        switch home.displayMode {
        case .live:
            content
        case .viewingHistory(let session):
            HistoryDetailView(session: session)
        }
    }

    private var isViewingHistory: Bool {
        if case .viewingHistory = home.displayMode { return true }
        return false
    }

    // MARK: - 履歴サイドバー(引き出し式 drawer)

    /// 引き出し式サイドバー(モック3画面目)。
    ///
    /// 【drawer 実装方式の判断(タスク指示で裁量)】モックは「ナビバー左から左スライドで引き出す」
    /// drawer なので、.sheet(下からのモーダル)ではなくその見た目に寄せて **ZStack + offset の
    /// overlay drawer** で実装する。開くと半透明の暗幕 + 左からスライドインするパネル。暗幕タップ・
    /// パネル内の選択/新規で閉じる。ドラッグで閉じる操作も足す(左へスワイプで dismiss)。
    /// NavigationSplitView の常設サイドバーにしないのは、モックが iPhone は「常設でなく引き出し式」
    /// と明記しているため(iPad 常設化は将来の余地・モック注記)。
    @ViewBuilder
    private var drawer: some View {
        if showingSidebar {
            // 暗幕(タップで閉じる)。ZStack 全面を覆う。
            // sidebar-v2 実装メモ9: 暗幕は black.opacity(0.3)(前版の 0.25 から微調整・モック --dim 準拠)。
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { closeSidebar() }
                .transition(.opacity)

            GeometryReader { proxy in
                // sidebar-v2 実装メモ9: 幅 min(width*0.82, 320)。前版は固定 320pt のみだったが、
                // モックの drawer chrome(width:316px ≒ 82%)に合わせ画面幅追従の上限付きに変更。
                ChatHistorySidebar(
                    store: home.chatStore,
                    activeSessionID: activeSessionID,
                    onSelect: { id in home.openHistory(id: id) },
                    onNewChat: { home.newChat() },
                    onClose: { closeSidebar() }
                )
                .frame(width: min(proxy.size.width * 0.82, 320))
                .frame(maxHeight: .infinity)
                // sidebar-v2 実装メモ9: 右端のみ角丸(UnevenRoundedRectangle・topTrailing/bottomTrailing
                // = 20)。前版は矩形のままだったが、モックの drawer chrome(border-radius:0 20px 20px 0)
                // に合わせて右端だけ丸める(左端は画面端に接するので角丸不要)。
                .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 20, topTrailingRadius: 20))
                .shadow(color: .black.opacity(0.18), radius: 16, x: 8, y: 0)
                .ignoresSafeArea(edges: .bottom)
                .transition(.move(edge: .leading))
                // 左スワイプで閉じる(引き出しを押し戻す自然な操作)。閾値を超えたら dismiss。
                .gesture(
                    DragGesture()
                        .onEnded { value in
                            if value.translation.width < -40 { closeSidebar() }
                        }
                )
            }
        }
    }

    private func closeSidebar() {
        withAnimation(.easeOut(duration: 0.22)) { showingSidebar = false }
    }

    /// サイドバーの .active ハイライト対象。ライブ時は現在セッション、履歴閲覧時は閲覧中セッション。
    private var activeSessionID: UUID? {
        switch home.displayMode {
        case .viewingHistory(let session):
            return session.id
        case .live:
            if case .ready(let chatVM) = home.state {
                return chatVM.currentSession.id
            }
            return nil
        }
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
            // proxy は .ready で必ず非 nil(runConnect が state=.ready の直前に生成)。カード構築
            //(InlineCardView)に渡す。防御的に if let で受け、万一 nil ならカード無しで本体だけ出す。
            if let proxy = home.proxy {
                ChatBodyView(chatVM: chatVM, proxy: proxy)
            } else {
                ChatBodyView(chatVM: chatVM, proxy: nil)
            }
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

    // MARK: - タイトル + model chip(モックの h1 + .model-chip を縦に合成)

    /// 中央タイトル領域。上段=接続先(サーバー短縮名)、下段=接続状態ドット + モデル名の chip。
    /// 全体を Button にして、タップで設定(モデル変更含む)を開く(chip に機能を持たせる)。
    private var titleAndModel: some View {
        Button {
            showingSettings = true
        } label: {
            VStack(spacing: 1) {
                // 上段: 接続先の短縮名(サーバー URL の host 先頭ラベル。今は caldav)。
                Text(serverShortName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                // 下段: 状態ドット + モデル名(フル表示・potato にならないよう十分な幅の principal に置く)。
                HStack(spacing: 4) {
                    Circle()
                        .fill(isReady ? Color.green : Color.gray)
                        .frame(width: 6, height: 6)
                    Text(settings.model)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // タップできる合図(モデル切替への導線)。
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// 接続先サーバー URL の host 先頭ラベル(例: caldav.gigun-dev.workers.dev → "caldav")。
    /// 解析できないときは素の文字列を短く出す(汎用ホストなので任意 URL を許す)。
    private var serverShortName: String {
        guard let host = URL(string: home.serverURLString)?.host else { return "MCP" }
        return host.split(separator: ".").first.map(String.init) ?? host
    }

    private var isReady: Bool {
        if case .ready = home.state { return true }
        return false
    }
}

#Preview {
    ChatHomeView()
}
