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
    // 履歴サイドバーの開閉(committed 状態)。実際の見せ方は「メイン画面を右へスライドして
    // 下層のサイドバーを露出する」方式(body 参照)。
    @State private var showingSidebar = false
    // 引き出しの横ドラッグ量(live)。ジェスチャ中だけ値が入り、終了で 0 に戻る(@GestureState の性質)。
    // committed の showingSidebar と合わせて実オフセットを決める(currentOffset)。
    @GestureState private var dragX: CGFloat = 0

    init() {
        // settings を先に作り、それを home に注入する。@State の init 直接代入は
        // _settings/_home を使う(SwiftUI の @State init パターン)。
        let settings = LLMSettingsStore()
        _settings = State(initialValue: settings)
        _home = State(initialValue: ChatHomeViewModel(settings: settings))
    }

    var body: some View {
        // 【引き出しの実装方式(2026-07-16 全面修正・ユーザー指摘 + Claude iOS 手本)】
        // 手本は「drawer がコンテンツの上に被さる」のではなく、**サイドバーが下層にいて、
        // メイン画面(角丸カード + ドロップシャドウ)が右へスライドして退く**方式。さらに
        // 画面を右へドラッグするとカードが指に追従して開く(「漫画のページめくり」)。
        // → 下層 = ChatHistorySidebar(左 revealWidth・全高)、上層 = メインを角丸カード化して
        //   x オフセット。オフセットは ☰ タップ(committed=showingSidebar)+ 横ドラッグ(live=dragX)で決める。
        GeometryReader { geo in
            // 露出幅: 画面の 84%(上限 330)。手本はカードの左端 ~15% が右に残る = reveal ~85%。
            let revealWidth = min(geo.size.width * 0.84, 330)
            let offset = currentOffset(revealWidth: revealWidth)
            // safe area の実測 inset(geo はまだ safe area を尊重した測定)。下でサイドバー内容を
            // これで寄せる。ZStack 全体は下の .ignoresSafeArea() で全画面へ広げる(カード bleed)。
            let topInset = geo.safeAreaInsets.top
            let bottomInset = geo.safeAreaInsets.bottom
            ZStack(alignment: .leading) {
                // 下層: サイドバー(左 revealWidth・全高)。**内容だけ safe area inset で寄せる**
                // (ヘッダがステータスバー/ノッチに潜らない・FAB がホームインジケータに被らない)。
                // 背景 paper は ZStack ごと全画面 bleed する(下の .background+.ignoresSafeArea)。
                ChatHistorySidebar(
                    store: home.chatStore,
                    activeSessionID: activeSessionID,
                    onSelect: { id in home.openHistory(id: id) },
                    onNewChat: { home.newChat() },
                    onClose: { closeSidebar() }
                )
                .frame(width: revealWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)

                // 上層: メイン(NavigationStack)を角丸カード化して右へスライド。
                // 【カードを物理画面の上下端まで bleed(2026-07-16・ユーザー指摘の再修正)】
                // ZStack ごと .ignoresSafeArea() で全画面に広げ、カード(NavigationStack)を物理端まで
                // 届かせる。こうすると右へ退いても見えるのは**左の縦エッジだけ**で、上端/下端の横エッジは
                // 出ない(手本 Claude iOS の「縦に貫通してめくれる」印象)。ナビバー・コンテンツの
                // safe area は NavigationStack が自前で確保する(ステータスバー下に navbar・
                // ホームインジケータ上に composer)。
                NavigationStack {
                    routedContent
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { toolbarContent }
                }
                .background(Color(.systemBackground))  // 下層が透けないよう不透明。ZStack ごと bleed する。
                .clipShape(RoundedRectangle(cornerRadius: offset > 0.5 ? 22 : 0, style: .continuous))
                .shadow(color: .black.opacity(offset > 0.5 ? 0.22 : 0), radius: 16, x: -6, y: 0)
                .offset(x: offset)
                // 開いている間は、退いたメインカードをタップで閉じる(手本と同じ・操作を「閉じる」に一本化)。
                .overlay {
                    if offset > 1 {
                        Color.black.opacity(0.0001)
                            .contentShape(Rectangle())
                            .onTapGesture { closeSidebar() }
                    }
                }
                // 横ドラッグでカードを追従させて開閉(「漫画のページめくり」)。縦スクロール・タップと
                // 両立させるため simultaneousGesture + 横方向優位ガード(縦優位のときは無反応)。
                .simultaneousGesture(dragGesture(revealWidth: revealWidth))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // paper を全画面へ(サイドバーのステータスバー下も埋める)+ ZStack ごと物理端まで広げる
            // (これがカード bleed の肝。個別 .ignoresSafeArea(edges:.vertical) では効きが弱かった)。
            .background(SidebarPalette.paper)
            .ignoresSafeArea()
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
        .onAppear {
            home.autoConnectIfRequested()
            // 【一時デバッグ・2026-07-16】開いた状態のレイアウトをエージェントがスクショで検証する
            // ための起動時オープン(UI タップができないため)。MCPHOST_SIDEBAR_OPEN=1 のときだけ。確認後に外す。
            if ProcessInfo.processInfo.environment["MCPHOST_SIDEBAR_OPEN"] == "1" {
                showingSidebar = true
            }
        }
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

    // MARK: - 引き出し(メイン画面を右へスライドして下層サイドバーを露出する方式)

    /// 実オフセット = committed(showingSidebar なら revealWidth)+ live ドラッグ(dragX)を 0...reveal にクランプ。
    /// これで「☰ タップで開閉」と「横ドラッグで指追従」を同じオフセットに合流させる。
    private func currentOffset(revealWidth: CGFloat) -> CGFloat {
        let base: CGFloat = showingSidebar ? revealWidth : 0
        return min(max(base + dragX, 0), revealWidth)
    }

    /// 横ドラッグで引き出しを開閉するジェスチャ。
    /// - 縦スクロール/タップと両立させるため **横方向優位のときだけ**反応(縦優位は無反応で素通し)。
    /// - 指を離したら、投射位置(予測を少し加味)が reveal の 40% を超えていれば開、未満なら閉に snap。
    private func dragGesture(revealWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($dragX) { value, state, _ in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                state = value.translation.width
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let base: CGFloat = showingSidebar ? revealWidth : 0
                // predictedEndTranslation を少し加味して「勢いのあるフリック」でも自然に開閉する。
                let projected = base + value.translation.width + value.predictedEndTranslation.width * 0.2
                withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
                    showingSidebar = projected > revealWidth * 0.4
                }
            }
    }

    private func closeSidebar() {
        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) { showingSidebar = false }
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
