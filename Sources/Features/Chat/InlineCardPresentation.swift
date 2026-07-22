// インラインカードの台帳と SwiftUI 表示。構築・接続を担う InlineCardHost から表示責務を分離する。
import SwiftUI
import Kernel
import Services

/// cardID → InlineCardHost の台帳。ChatBodyView が @State で1個所有し、チャット画面の生存期間中
/// カード群を生かし続ける(上のファイル冒頭「最重要の設計判断」参照)。@Observable にしないのは、
/// この dict 自体の変化を View が観測する必要がないため(観測対象は各 host.webView・そちらが @Observable)。
@MainActor
final class InlineCardRegistry {
    private var hosts: [String: InlineCardHost] = [:]

    /// key に対応する host を返す(無ければ生成して登録)。get-or-create なので body から呼んでも
    /// 同一インスタンスが返り、スクロール再生成に耐える。
    /// - Parameter coordinator: fullscreen 昇格の調停役(ChatBodyView 所有)。生成時に host へ注入する
    ///   (registry 経由が自然・設計 04 §5 H4-D)。既存 host には再注入しない(生存中は同一 coordinator)。
    func host(for key: String, coordinator: FullscreenCoordinator) -> InlineCardHost {
        if let existing = hosts[key] { return existing }
        let host = InlineCardHost()
        host.attach(fullscreenCoordinator: coordinator)
        hosts[key] = host
        return host
    }

    /// 全カードを破棄(チャット画面クローズ時)。以降の再表示は無いので session を畳んでよい。
    func teardownAll() {
        for host in hosts.values { host.teardown() }
        hosts.removeAll()
    }
}

/// 1枚のインラインカードを描画する View。実体(webView/session)は host が持ち、この View は
/// 「host の準備済み webView を高さ追従で載せるだけ」(AppCardView と同じ薄さ)。
struct InlineCardView: View {
    let host: InlineCardHost
    let proxy: AppsServerProxy
    let card: CardEmbed
    let containerWidth: CGFloat
    /// inline の実 maxHeight(可視高 × 0.65・P4-DM 決定1・設計 04 §5 H1)。ChatBodyView が可視高から算出して渡す。
    let maxHeight: CGFloat
    /// スナップショット取得時に呼ばれる(T6・設計 §5)。ChatBodyView が identity=(turnIndex,cardIndex)
    /// を閉じ込めて渡し、最終的に ChatViewModel.setCardSnapshot を叩く。既定 nil で T5 の既存呼び出し
    /// (スナップショット不要のプレビュー等)を壊さない。
    var onSnapshot: (@MainActor (String) -> Void)?

    // 高さ(desiredHeight)は AppCardState(ObservableObject)で観測する。@Observable の host とは
    // 別機構だが、既存の高さ状態型を作り替えない方針(ファイル冒頭 InlineCardHost.cardState 参照)。
    @ObservedObject private var cardState: AppCardState

    // #5: ホストの現在外観。initialize に載せる初期 theme と、変化時の host-context-changed 追送に使う。
    @Environment(\.colorScheme) private var colorScheme

    init(
        host: InlineCardHost,
        proxy: AppsServerProxy,
        card: CardEmbed,
        containerWidth: CGFloat,
        maxHeight: CGFloat,
        onSnapshot: (@MainActor (String) -> Void)? = nil
    ) {
        self.host = host
        self.proxy = proxy
        self.card = card
        self.containerWidth = containerWidth
        self.maxHeight = maxHeight
        self.onSnapshot = onSnapshot
        // @ObservedObject を host の cardState に束ねる(init で _cardState を組む標準パターン)。
        self._cardState = ObservedObject(wrappedValue: host.cardState)
    }

    var body: some View {
        content
            // 構築は host に一任(2回目以降 no-op)。containerWidth が未確定(初期 0)の間は構築を保留し、
            // 実測幅が来てから1度だけ構築する(狭すぎる幅でカードがレイアウトされるのを避ける)。
            .task(id: containerWidth > 0) {
                guard containerWidth > 0 else { return }
                // スナップショット取得口を host に差し込んでから構築する(build 中の size-changed で
                // 取得が走るので、それより前に設定しておく)。host は生存し続けるが closure は
                // View 再生成のたびに新しくなりうるので、毎回入れ替える(identity は同じなので実害なし)。
                host.onSnapshot = onSnapshot
                host.buildIfNeeded(
                    proxy: proxy,
                    card: card,
                    containerWidth: containerWidth,
                    maxHeight: maxHeight,
                    colorScheme: colorScheme
                )
            }
            // #5: ホスト外観の変化をカードへ追送する(ライト⇄ダーク切替・システム設定変更)。build 後の
            // 変更のみが対象で、host 側が同値ガード・session 未生成ガードを持つので初回や build 前は no-op。
            .onChange(of: colorScheme) { _, newScheme in
                host.updateColorScheme(newScheme)
            }
        // onDisappear では teardown しない(設計 §4 の生存優先・ファイル冒頭の判断)。スクロールアウトは
        // 一時的な View 破棄にすぎず、host は registry が生かし続ける。teardown はチャット画面クローズ時に
        // ChatBodyView が registry.teardownAll() でまとめて行う。
    }

    /// カード**外**・カード上に置く極薄のホストクローム行(⤢ のみ・右寄せ)。
    ///
    /// 【なぜオーバーレイをやめたか(設計 04 決定2・2026-07-17 追記)】旧実装はカード右上に
    /// `.overlay(alignment: .topTrailing)` で ⤢ を重ねていたが、caldav の sticky ヘッダ「完了」
    /// (todos-app.ts:1173)と実機で衝突し押せなくなった(ユーザー実機報告)。設計 04 は fullscreen 側の
    /// 対称なボタン(⤡)について既に「カード右上へのオーバーレイはボツ、位置はカード外」と裁定済み
    /// (04 §5 H4・2026-07-17 更新)。ホストはカードの内部レイアウト(ヘッダがどこにあるか)を知らない
    /// (CLAUDE.md ビジョン2: AppsBridge は caldav 非依存)ため、「ホストクロームをカードのコンテンツ
    /// 領域に重ねない」が任意のカードに対して安全な唯一の一般解。inline 側もこの原則を適用し、
    /// ⤢ を**カード枠の外・カードの上**の行に出す(fullscreen の上端ストリップと対称の位置づけ)。
    ///
    /// 【ボツ案: オーバーレイのまま位置だけずらす】カードごとに sticky ヘッダの配置(高さ・左右)が
    /// 違いうる(caldav は上端固定だが、他の任意の MCP App が同じ保証をする理由がない)ため、
    /// 「ずらせば直る」は特定カードへの場当たり対応でしかなく構造的に解決しない。却下(財産として残す)。
    ///
    /// 表示条件: cardSupportsFullscreen && displayMode==.inline のときだけ行自体を出す
    /// (非対応カードでは行が無い=余白を増やさない・押しても拒否される死にボタンにしない)。
    @ViewBuilder
    private var chromeRow: some View {
        if host.cardSupportsFullscreen && host.displayMode == .inline {
            HStack {
                Spacer()
                Button {
                    host.requestFullscreenFromHost()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("最大化")
            }
            .frame(height: 24)  // 極薄・背景なし(カード枠の外なので同居に制約は無いが、控えめに保つ)。
            .padding(.trailing, 4)
        }
    }

    @ViewBuilder
    private var content: some View {
        // host.webView(@Observable)を読むことで、構築完了(nil→非nil)時に自動で差し替わる。
        if let webView = host.webView {
            // role:.inline + host.displayMode を渡す(P4-DM・container 再アダプト方式)。host.displayMode を
            // ここで読むことで @Observable 依存が張られ、fullscreen 昇格/復帰で content が再評価され、
            // AppCardView の updateUIView が走って webView の載せ替え(奪い合いガード込み)が起きる。
            // fullscreen 中はこの inline 側 AppCardView は webView を所有しない(sheet 側が持つ)ため
            // 空の枠が cardState.desiredHeight で残る(カードは sheet に居る・設計 04 §6)。
            // #6 prefersBorder: カードが枠+背景を望むか。nil(未指定)= ホスト既定で「枠+背景あり」に倒す
            // (現行の見た目を維持・退行ゼロ)。false のときだけ枠・背景・角丸クリップを外して素のカードにする。
            let showBorder = host.prefersBorder ?? true
            // 【カード外クローム行(2026-07-17 追記)】⤢ はカードの上・カード枠の**外**に置く(chromeRow
            // 冒頭コメント参照)。VStack で縦積みするだけで、カード自体のレイアウト(background/clipShape/
            // overlay の枠線)には一切手を入れない — オーバーレイ撤去に伴う変更はここだけに閉じる。
            VStack(spacing: 4) {
                chromeRow
                AppCardView(
                    webView: webView, role: .inline, activeDisplayMode: host.displayMode,
                    // 監査 2026-07-18 HIGH #1: 実際に inline へ再アダプトされた直後に保留中の
                    // host-context-changed(inline 復帰)があれば送る(InlineCardHost.notifyReparented
                    // コメント参照)。
                    onAdopted: { host.notifyReparented() }
                )
                    .frame(height: cardState.desiredHeight)  // size-changed 追従(設計 §5・fullscreen 中は停止)。
                    .frame(maxWidth: .infinity)
                    // #5 ダークモード: 枠・背景はシステム意味カラーにして外観に追従する(旧: Color(white:) 固定は
                    // ダークで白浮きする)。webView 自体は透過なのでカードの地色は styles トークン由来で入る。
                    .background(showBorder ? Color(uiColor: .secondarySystemBackground) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: showBorder ? 12 : 0))
                    // 角丸+枠(TodosCardSpike の見た目を踏襲・showBorder のときだけ描く)。
                    .overlay {
                        if showBorder {
                            RoundedRectangle(cornerRadius: 12).stroke(Color(uiColor: .separator))
                        }
                    }
            }
        } else if host.buildFailed {
            // 【fable #3: 構築失敗のエラー表示】旧実装はこの分岐が無く、失敗時も下のローディングに
            // 落ちてスピナーが回り続けていた(ファイル冒頭 buildFailed 宣言のコメント参照)。
            // プレースホルダと同じ角丸+枠のトーンを踏襲しつつ、エラーだと分かる見た目(warning 色の
            // 三角アイコン+文言+ツール名)にする。リトライは今回のスコープ外(上の build() コメント参照)。
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.96))
                .frame(height: 120)
                .overlay(
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title3)
                            .foregroundStyle(.orange)
                        Text("カードを読み込めませんでした")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(card.toolName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                )
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.85)))
                // #8 随伴: エラーの意味をまとめて1つのアクセシビリティ要素として読み上げる。
                .accessibilityElement(children: .combine)
                .accessibilityLabel("カードを読み込めませんでした: \(card.toolName)")
        } else {
            // 【fable #7: ローディング改善】旧実装は無地の ProgressView(無名スピナー)だけで、
            // 何を読み込んでいるか分からなかった。ツール名ラベル + skeleton 風の薄いバー2本を添える
            // ことで「何を待っているか」を示す(caldav カード側の skeleton に寄せる必要はなく、
            // ホスト側は素朴な表現で良い・タスク指示)。HTML 取得〜握手までの数百 ms の間だけ見える。
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.96))
                .frame(height: 120)
                .overlay(
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("\(card.toolName) を読み込み中…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // skeleton 風の薄いバー(内容が来る前の骨格を示唆する程度。派手にしない)。
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(white: 0.88))
                                .frame(width: 120, height: 6)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(white: 0.88))
                                .frame(width: 80, height: 6)
                        }
                    }
                )
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.85)))
                .accessibilityLabel("\(card.toolName) を読み込み中")
        }
    }
}
