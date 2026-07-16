// ツール結果の ui:// カードをチャット内にインライン描画する層(T5・設計 §4/§5)。
//
// P2 のスパイク(TodosCardSpikeView)は「単カード全画面」だったが、T5 は「1ツール結果 = 1カード」を
// チャット文脈に一般化する。P2 で実証したフロー
//   proxy.fetchAppHTML → AppCardWebViewFactory.make → AppsBridgeSession(start → sendToolInput →
//   sendToolResult) → teardown、参照の強保持
// を「CardEmbed 1件を描画する」形に落とす。
//
// ---------------------------------------------------------------------------------------------
// 【最重要の設計判断: カードのライフサイクルと LazyVStack のスクロール問題】(設計 §4「カードの生存」)
//
// 設計 §4 は「チャットスクロールで画面外に出ても WKWebView は保持(再生成は高コスト・状態が飛ぶ)」を
// 要求する。ところが ChatBodyView のメッセージ列は LazyVStack で、行が画面外に出ると View が破棄され
// onDisappear が呼ばれる。もし InlineCardView 自体が session/webView を @State で持つと、スクロールで
// 破棄 → 再表示のたびに作り直し(fetchAppHTML から握手まで全部やり直し)になり、カード内で進めた
// 往復状態(complete したチェック等)が飛ぶ。これは §4 の生存方針に反する。
//
// 【採った解(タスク指示の「現実解」)】セッション群(webView + transport + coordinator + session)を
// **InlineCardView の外**、すなわちチャット画面が生きている限り生存する `InlineCardRegistry`
// (ChatBodyView が @State で1個所有)に **cardID キーで保持**する。InlineCardView は「registry から
// 同じ host を引いて、その webView を載せるだけ」にする。こうすると:
//  - スクロールで InlineCardView が破棄・再生成されても、registry の host は生き続けるので
//    buildIfNeeded は2回目以降 no-op(既存 webView をそのまま再表示)= 往復状態が飛ばない。
//  - AppCardView が「準備済み WKWebView を載せるだけ」の設計(AppCardView.swift 冒頭)とも整合する。
//
// 【teardown の方針】スクロールアウト(onDisappear)では teardown しない(§4 の生存優先)。teardown は
// チャット画面そのものが閉じるとき(ChatBodyView.onDisappear)に registry がまとめて行う。
//
// 【ライブ WKWebView の枚数上限(§4 の5枚→スナップショット降格)は T5 では未実装】スナップショット機構
// (outerHTML 取得・JS 無効ロード)は T6 で作るので、その転用である枚数上限も T6 送り(設計 §4 も
// 「スナップショット機構を作る以上、転用はほぼタダ」と T6 前提で書く)。ここでは上限を設けない。
// ---------------------------------------------------------------------------------------------
import SwiftUI
import WebKit
import OSLog
import Kernel    // CardEmbed・JSONValue
import Services  // AppsServerProxy・AppsBridgeSession・WebViewTransport・AppCardWebCoordinator 等

/// 1枚のインラインカードの「構築物」を強参照で束ねて生存させるホスト(設計 §4 の生存単位)。
///
/// @MainActor @Observable: `webView`(構築完了で nil→非nil)を SwiftUI が観測し、プレースホルダ→カードへ
/// 差し替える。transport/coordinator/session は手放すとブリッジが停止する(delegate が weak・
/// TodosCardSpikeViewModel と同じ理由)ので、ここで強参照して生かし続ける。
@MainActor
@Observable
final class InlineCardHost {
    /// 準備済み WKWebView。構築完了で publish され、InlineCardView がこれを載せる。未構築は nil。
    private(set) var webView: WKWebView?

    /// カード高さ(size-changed 追従・設計 §5)。ObservableObject なので View 側は @ObservedObject で観測。
    /// InlineCardHost(@Observable)とは別機構だが、AppCardState を新規に作り替えない方針(既存の
    /// AppCardView/スパイクと共有の高さ状態型)なのでそのまま流用する。
    let cardState = AppCardState()

    // 生存させ続ける参照群(手放すと停止する。TodosCardSpikeViewModel のプロパティ群と同じ役割)。
    private var transport: WebViewTransport?
    private var coordinator: AppCardWebCoordinator?
    private var session: AppsBridgeSession?
    private var buildTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "inlinecard")

    /// カードを1度だけ構築する。2回目以降(スクロール往復での再 .task)は no-op(既存 webView を維持)。
    /// - Parameters:
    ///   - proxy: 接続共有の AppsServerProxy(fetchAppHTML と tools/call 素通しの両方を担う・設計 §4)。
    ///   - card: 描画対象の CardEmbed(resourceUri・arguments・structuredContent を使う)。
    ///   - containerWidth: カード列の実測幅(設計 §5「幅=カード列の実測幅」)。initialize の
    ///     containerDimensions.width としてカードへ渡り、caldav カードがこの幅にレイアウトする。
    func buildIfNeeded(proxy: AppsServerProxy, card: CardEmbed, containerWidth: CGFloat) {
        guard buildTask == nil else { return }  // 既に構築開始済み(= host は生存中)なら何もしない。
        buildTask = Task { await self.build(proxy: proxy, card: card, containerWidth: containerWidth) }
    }

    private func build(proxy: AppsServerProxy, card: CardEmbed, containerWidth: CGFloat) async {
        do {
            // 1. HTML プリフェッチ(接続内キャッシュが効くので2枚目以降の同一 URI は resources/read を省く)。
            let (html, _) = try await proxy.fetchAppHTML(uri: card.resourceUri)

            // 2. サンドボックス WKWebView 生成。**インラインは高さ追従なので scrollEnabled:false**
            //    (設計 §5・AppCardWebViewFactory の scrollEnabled 引数コメント)。内部スクロールを切り、
            //    size-changed が返す max-content 高さを .frame(height:) で追従させる。
            let transport = WebViewTransport()
            self.transport = transport
            let coordinator = AppCardWebCoordinator()
            self.coordinator = coordinator
            let webView = await AppCardWebViewFactory.make(
                transport: transport, html: html, coordinator: coordinator, scrollEnabled: false)

            // 3. セッション起動。onSizeChanged は高さを cardState へ流し込み、maxHeight(600)でクランプ
            //    してチャットを食い潰さない(設計 §5)。
            let cardState = self.cardState
            let session = AppsBridgeSession(
                transport: transport,
                proxy: proxy,
                containerWidth: Double(containerWidth),
                maxHeight: 600,
                onSizeChanged: { height in
                    await MainActor.run {
                        withAnimation(.easeOut(duration: 0.3)) {
                            cardState.desiredHeight = min(CGFloat(height), 600)
                        }
                    }
                })
            self.session = session
            await session.start()

            // 4. webView を publish(この時点で View は WKWebView をマウントし、カードは ui/initialize を
            //    送ってくる)。start() の後に publish する順序は TodosCardSpikeViewModel と同じ
            //    (握手はマウント後・以降の配送は initialized まで outbox に退避される・設計 §2)。
            self.webView = webView

            // 5. tool-input(引数)→ tool-result(結果)の順で配送。ready 前は outbox に退避され、
            //    initialized 受信で FIFO flush される(設計 §2・スパイクと同順)。
            await session.sendToolInput(arguments: card.arguments ?? .object([:]))
            await session.sendToolResult(card.structuredContent ?? .null)
            logger.notice("インラインカード構築完了 uri=\(card.resourceUri, privacy: .public)")
        } catch {
            // 構築失敗(HTML 取得失敗・mimeType 不一致など)。webView は nil のままなので
            // View はプレースホルダを出し続ける。チャット全体は壊さない(1カードの失敗に閉じる)。
            logger.error("インラインカード構築失敗 uri=\(card.resourceUri, privacy: .public): \(String(reflecting: error), privacy: .public)")
        }
    }

    /// 明示破棄(チャット画面が閉じるとき registry から呼ばれる)。teardown を投げてから参照を手放す。
    func teardown() {
        let session = self.session
        Task { await session?.teardown() }
    }
}

/// cardID → InlineCardHost の台帳。ChatBodyView が @State で1個所有し、チャット画面の生存期間中
/// カード群を生かし続ける(上のファイル冒頭「最重要の設計判断」参照)。@Observable にしないのは、
/// この dict 自体の変化を View が観測する必要がないため(観測対象は各 host.webView・そちらが @Observable)。
@MainActor
final class InlineCardRegistry {
    private var hosts: [String: InlineCardHost] = [:]

    /// key に対応する host を返す(無ければ生成して登録)。get-or-create なので body から呼んでも
    /// 同一インスタンスが返り、スクロール再生成に耐える。
    func host(for key: String) -> InlineCardHost {
        if let existing = hosts[key] { return existing }
        let host = InlineCardHost()
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

    // 高さ(desiredHeight)は AppCardState(ObservableObject)で観測する。@Observable の host とは
    // 別機構だが、既存の高さ状態型を作り替えない方針(ファイル冒頭 InlineCardHost.cardState 参照)。
    @ObservedObject private var cardState: AppCardState

    init(host: InlineCardHost, proxy: AppsServerProxy, card: CardEmbed, containerWidth: CGFloat) {
        self.host = host
        self.proxy = proxy
        self.card = card
        self.containerWidth = containerWidth
        // @ObservedObject を host の cardState に束ねる(init で _cardState を組む標準パターン)。
        self._cardState = ObservedObject(wrappedValue: host.cardState)
    }

    var body: some View {
        content
            // 構築は host に一任(2回目以降 no-op)。containerWidth が未確定(初期 0)の間は構築を保留し、
            // 実測幅が来てから1度だけ構築する(狭すぎる幅でカードがレイアウトされるのを避ける)。
            .task(id: containerWidth > 0) {
                guard containerWidth > 0 else { return }
                host.buildIfNeeded(proxy: proxy, card: card, containerWidth: containerWidth)
            }
        // onDisappear では teardown しない(設計 §4 の生存優先・ファイル冒頭の判断)。スクロールアウトは
        // 一時的な View 破棄にすぎず、host は registry が生かし続ける。teardown はチャット画面クローズ時に
        // ChatBodyView が registry.teardownAll() でまとめて行う。
    }

    @ViewBuilder
    private var content: some View {
        // host.webView(@Observable)を読むことで、構築完了(nil→非nil)時に自動で差し替わる。
        if let webView = host.webView {
            AppCardView(webView: webView)
                .frame(height: cardState.desiredHeight)  // size-changed 追従(設計 §5)。
                .frame(maxWidth: .infinity)
                .background(Color(white: 0.98))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                // 角丸+枠(TodosCardSpike の見た目を踏襲)。
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.85)))
        } else {
            // ローディング中のプレースホルダ(HTML 取得〜握手までの数百 ms)。
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.96))
                .frame(height: 120)
                .overlay(ProgressView())
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.85)))
        }
    }
}
