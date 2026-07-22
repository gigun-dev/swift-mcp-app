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
import Services  // ServerRegistryStore(サーバー登録簿・M1)

struct ChatHomeView: View {
    // 設定は Home と Sheet で共有する1インスタンス。@State で所有(@Observable を SwiftUI が観測)。
    // 初期値は init で注入する(settings を home にも渡す必要があるため既定式は置かない)。
    @State private var settings: LLMSettingsStore
    // MCP サーバー登録簿(M1)。Home / SettingsSheet / サーバー選択メニューで共有する1インスタンス。
    @State private var registry: ServerRegistryStore
    @State private var home: ChatHomeViewModel
    @State private var showingSettings = false
    // 履歴サイドバーの開閉(committed 状態)。実際の見せ方は「メイン画面を右へスライドして
    // 下層のサイドバーを露出する」方式(body 参照)。
    @State private var showingSidebar = false
    // 引き出しの横ドラッグ量(live)。**@GestureState でなく @State** にしているのは、指を離した
    // 瞬間の 0 リセットを自前で(snap と同じ withAnimation 内で)行うため — @GestureState は
    // 終了時に 0 へ即リセットされ、committed(showingSidebar)反映との間に1フレームの隙間ができて
    // 「一度閉じてから開く」ちらつきになる(ユーザー指摘・2026-07-16)。committed の showingSidebar と
    // 合わせて実オフセットを決める(currentOffset)。
    @State private var dragTranslation: CGFloat = 0

    init() {
        // settings を先に作り、それを home に注入する。@State の init 直接代入は
        // _settings/_home を使う(SwiftUI の @State init パターン)。
        let settings = LLMSettingsStore()
        let registry = ServerRegistryStore()
        _settings = State(initialValue: settings)
        _registry = State(initialValue: registry)
        _home = State(initialValue: ChatHomeViewModel(settings: settings, registry: registry))
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
            // 開度(0=閉 1=開)。オフセットを reveal 幅で正規化。暗幕の opacity 駆動に使う
            // (ベスプラ: 開閉を boolean でなく 0..1 の fraction で駆動すると滑らか)。
            let progress = revealWidth > 0 ? min(max(offset / revealWidth, 0), 1) : 0
            ZStack(alignment: .leading) {
                // 下層: サイドバー(左 revealWidth・全高)。**内容だけ safe area inset で寄せる**
                // (ヘッダがステータスバー/ノッチに潜らない・FAB がホームインジケータに被らない)。
                // 背景 paper は ZStack ごと全画面 bleed する(下の .background+.ignoresSafeArea)。
                ChatHistorySidebar(
                    store: home.chatStore,
                    activeSessionID: activeSessionID,
                    onSelect: { id in home.openHistory(id: id) },
                    onNewChat: { Task { await home.newChat() } },
                    onClose: { closeSidebar() }
                )
                .frame(width: revealWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)

                // サイドバーの暗幕(手本 image15・ユーザー指摘「完全展開まで全体に shadow が入る方が自然」)。
                // progress で opacity を駆動: 開ききるまで薄暗く、完全展開(progress=1)で 0。これで
                // 「サイドバーが影から現れる」自然な奥行きになる。閉時(progress=0)は最大 dim だがカードが
                // 覆うので不可視。opacity 0(全開)のとき SwiftUI が hit-test も自動で外す(ベスプラ)。
                // allowsHitTesting(false) でドラッグ中もサイドバー操作を妨げない。
                Color.black
                    .opacity((1 - progress) * 0.32)
                    .frame(width: revealWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .allowsHitTesting(false)

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
                // 開いている間は、退いたメインカードをタップで閉じる(手本と同じ・操作を「閉じる」に一本化)。
                //
                // 【2026-07-17 実機バグ修正(サイドバー全操作不能)— overlay/gesture は .offset の"前"に付ける】
                // SwiftUI の .offset は**描画だけ**を平行移動し、レイアウト frame は元の位置に残る。
                // 旧実装は `.offset(x:).overlay { タップキャッチャ }` の順だったため、overlay が
                // **ずれる前の全画面 frame**(=露出したサイドバーの真上)に配置され、ほぼ透明の
                // contentShape(Rectangle) + onTapGesture がサイドバーへの全入力(履歴タップ・検索フォーカス・
                // List スクロール)を食っていた — 「タップすると読み込まれずドロワーが閉じるだけ」
                // 「検索欄が反応しない」「スクロールできない」の実機症状すべての単一原因。
                // .offset の**前**に overlay/simultaneousGesture を付ければ、両方ともカードの描画と
                // 一緒に右へ動き、サイドバー領域には何も残らない(タップキャッチャは「退いたカードの
                // 見えている部分だけ」を覆う=本来の意図どおり)。
                .overlay {
                    if offset > 1 {
                        Color.black.opacity(0.0001)
                            .contentShape(Rectangle())
                            .onTapGesture { closeSidebar() }
                    }
                }
                // 横ドラッグでカードを追従させて開閉(「漫画のページめくり」)。縦スクロール・タップと
                // 両立させるため simultaneousGesture + 横方向優位ガード(縦優位のときは無反応)。
                // これも .offset の前(上記コメント参照 — 後に付けると全画面 frame でサイドバーの
                // 縦スクロールと競合する)。カード上の横ドラッグ開閉という意図は変わらない。
                .simultaneousGesture(dragGesture(revealWidth: revealWidth))
                .offset(x: offset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // paper を全画面へ(サイドバーのステータスバー下も埋める)+ ZStack ごと物理端まで広げる
            // (これがカード bleed の肝。個別 .ignoresSafeArea(edges:.vertical) では効きが弱かった)。
            .background(SidebarPalette.paper)
            .ignoresSafeArea()
        }
        // ハプティクス(iOS 17+ 現行推奨 .sensoryFeedback・UIKit 不要)。committed の showingSidebar が
        // 変わる = 開閉が snap 確定した瞬間に発火する(ドラッグ追従中は dragX 駆動で committed は
        // 変わらないので鳴らない = スナップ完了時だけ鳴る・ベスプラどおり)。iPhone のみ想定なので
        // iPad の非対応(ハプティクス無し)は考慮不要。
        .sensoryFeedback(.impact(weight: .medium), trigger: showingSidebar)
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(store: settings, registry: registry, home: home)
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
        // 起動即チャット + 有効な全サーバーへ無言接続(M2)。接続ゲートは廃止。
        .onAppear {
            home.start()
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
                    Task { await home.newChat() }
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
        return min(max(base + dragTranslation, 0), revealWidth)
    }

    /// 横ドラッグで引き出しを開閉するジェスチャ。
    /// - 縦スクロール/タップと両立させるため **横方向優位のときだけ**反応(縦優位は無反応で素通し)。
    /// - 指を離したら、投射位置(予測を少し加味)が reveal の 40% を超えていれば開、未満なら閉に snap。
    ///
    /// 【ちらつき対策(2026-07-16・ユーザー指摘)】@State の dragTranslation を使い、onEnded で
    /// **snap 確定(showingSidebar)と dragTranslation=0 を同一 withAnimation 内**で行う。こうすると
    /// 実オフセット(base + dragTranslation)が「離した位置」から「snap 先」へ連続してアニメーション
    /// する。@GestureState だと離した瞬間に 0 リセットが先行し、committed 反映との隙間で「一度閉じて
    /// から開く」1フレームのちらつきが出ていた(開閉とも)。
    private func dragGesture(revealWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragTranslation = value.translation.width
            }
            .onEnded { value in
                let horizontal = abs(value.translation.width) > abs(value.translation.height)
                // 【閾値を下げ・速度も見る(2026-07-16・ユーザー指摘「少ない動きで閉じたい・勢いを
                // つけるのは疲れる」)】以前は「全開幅の 40% 位置」を単一閾値にしていたため、閉じるには
                // 60% ぶんも左へ動かす必要があり疲れた。→ **現在状態からの移動量**が reveal の 22% を
                // 超える or その向きに勢い(現在速度ぶんの追加予測移動 > 100pt)があれば toggle する、
                // 対称で軽い判定にする(少しの動き or 軽いフリックのどちらでも確定)。
                let moved = value.translation.width
                let velocity = value.predictedEndTranslation.width - moved  // 現在速度ぶんの追加予測移動。
                let posThreshold = revealWidth * 0.22
                let velThreshold: CGFloat = 100
                let target: Bool
                if showingSidebar {
                    // 開いている → 左へ少し動かす or 左向きの勢いで閉じる。
                    let closing = moved < -posThreshold || velocity < -velThreshold
                    target = !closing
                } else {
                    // 閉じている → 右へ少し動かす or 右向きの勢いで開く。
                    target = moved > posThreshold || velocity > velThreshold
                }
                withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
                    if horizontal { showingSidebar = target }
                    dragTranslation = 0  // snap と同じアニメーション内でリセット(隙間=ちらつきを作らない)。
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
        case .ready(let chatVM):
            // カード由来サーバーの proxy を前置ツール名から解決するクロージャを渡す(M2・タスク指示 §4)。
            // 【混線バグ回避(M1 から継承)】`.id(chatVM.currentSession.id)` でセッションごとに View
            // identity を切り、chatVM 入れ替え時に ChatBodyView(と cardRegistry を含む @State 一式)を
            // 作り直させる(旧チャットのカード台帳を持ち越さない)。
            ChatBodyView(
                chatVM: chatVM,
                cardProxyResolver: { home.cardProxy(forToolName: $0) }
            )
            .id(chatVM.currentSession.id)
        case .failed(let message):
            failedView(message)
        }
    }

    /// チャット自体を組めない致命(LLM base URL 不正など)。接続失敗はここには来ない
    /// (M2 では接続はサーバーごとに非同期で、失敗してもチャット(ツール0件)は成立する)。
    private func failedView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text("チャットを開始できません")
                .font(.headline)
            Text(message)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("設定を開く") { showingSettings = true }
                .buttonStyle(.bordered)
        }
        .padding()
    }

    private var titleAndModel: some View {
        ServerStatusMenu(settings: settings, registry: registry, home: home) {
            showingSettings = true
        }
    }
}

#Preview {
    ChatHomeView()
}
