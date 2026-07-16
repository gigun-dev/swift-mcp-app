// 履歴再訪時の静的カード表示(T6・設計 §5「カードの履歴再訪問題」)。
//
// ライブカード(InlineCardView)は WKWebView + ブリッジで双方向に動くが、履歴では
// スナップショット HTML を **JS 無効・ブリッジ無し**で静的にロードするだけ(設計 §5:
// 再実行しない・副作用を起こさない・死んだボタンの JS エラーも切る)。実体生成は
// AppCardWebViewFactory.makeStatic が担い、この層は「準備済み WKWebView を高さ内に載せるだけ」
// (AppCardView と同じ薄さ)。
import SwiftUI
import WebKit
import OSLog

/// 1枚の静的スナップショットカードの構築物を束ねて生存させるホスト。
///
/// @MainActor @Observable: webView(構築完了で nil→非nil)を SwiftUI が観測しプレースホルダ→表示へ
/// 差し替える。coordinator は WKWebView の delegate が weak なので強参照で保持する(手放すと
/// navigation 封じが効かなくなる・AppCardWebCoordinator の説明と同じ理由)。
@MainActor
@Observable
final class StaticCardHost {
    private(set) var webView: WKWebView?
    // navigation/UI デリゲート。makeStatic が weak 参照するのでここで強参照。
    private var coordinator: AppCardWebCoordinator?
    private var buildTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "staticcard")

    /// スナップショット HTML を1度だけロードする(2回目以降は no-op・既存 webView を維持)。
    func buildIfNeeded(html: String) {
        guard buildTask == nil else { return }
        buildTask = Task { await self.build(html: html) }
    }

    private func build(html: String) async {
        let coordinator = AppCardWebCoordinator()
        self.coordinator = coordinator
        let webView = await AppCardWebViewFactory.makeStatic(html: html, coordinator: coordinator)
        self.webView = webView
        logger.notice("静的カードをロード(履歴再訪)")
    }
}

/// cardID → StaticCardHost の台帳(HistoryDetailView が @State で1個所有)。
/// InlineCardRegistry と同趣旨: SwiftUI の再生成(スクロール等)で View が破棄されても host を
/// 生かし、WKWebView を作り直さない(静的なので状態は飛ばないが、再ロードの無駄を避ける)。
@MainActor
final class StaticCardRegistry {
    private var hosts: [String: StaticCardHost] = [:]
    func host(for key: String) -> StaticCardHost {
        if let existing = hosts[key] { return existing }
        let host = StaticCardHost()
        hosts[key] = host
        return host
    }
}

/// 1枚の静的スナップショットカードを描画する View。
///
/// 【高さの判断(設計に固定値の指定なし・タスク指示で裁量)】ライブカードは size-changed で
/// 内容ぴったりに追従できるが、静的カードは**追従ブリッジが無い**(JS 無効なので size-changed も
/// 来ない)。そこで maxHeight を決めて **WKWebView 内部スクロール**に委ねる(makeStatic で
/// scrollEnabled=true)。固定高だと短いカードで余白、長いカードで見切れが起きるが、内部スクロール
/// なら「上限内に収め、溢れたぶんはカード内でスクロール」で素直に収まる。上限 360pt は
/// ライブの maxHeight 600 より控えめ(履歴は一覧的に眺める用途で、1枚が画面を占有しすぎない方が
/// スクロールしやすい・可逆な調整値)。
struct StaticCardView: View {
    let host: StaticCardHost
    let html: String

    var body: some View {
        content
            .task { host.buildIfNeeded(html: html) }
    }

    @ViewBuilder
    private var content: some View {
        if let webView = host.webView {
            AppCardView(webView: webView)
                .frame(height: 360)
                .frame(maxWidth: .infinity)
                .background(Color(white: 0.98))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.85)))
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.96))
                .frame(height: 120)
                .overlay(ProgressView())
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.85)))
        }
    }
}
