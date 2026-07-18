// inline カード(WKWebView)内の focus 要素がキーボードに隠れる問題への対処
// (ユーザー実機 FB 2026-07-17: 「inline カードで vtodo 行をタップ→編集→キーボードが出ると
//  選択した入力欄がキーボードの裏に隠れて見えない」)。
//
// 【なぜホスト側で手当てが要るか(原因)】inline カードは設計 §5 に従い
// `scrollView.isScrollEnabled = false`(内部スクロール無し・高さは size-changed で外側が追従)。
// この設定だと WKWebView 標準の「focus 要素へ自動スクロール」が効かない(内部スクロールが無いので
// スクロールしようがない)。一方、外側の SwiftUI ScrollView は「カード内のどこに focus があるか」を
// 一切知らない(WKWebView は不透明な1枚のビュー)。結果、誰も focus 要素をキーボード上に運ばない。
//
// 【方針(中立・caldav 固有知識ゼロ・CLAUDE.md ビジョン2)】
//  1. keyboardWillShow を受ける。
//  2. 現在の first responder を辿り、それが inline カードの WKWebView 配下なら、
//     `getBoundingClientRect()` で focus 要素の矩形(webView ローカル座標=CSS px=pt)を取る。
//  3. webView ローカル → window 座標へ変換し、focus 要素の下端がキーボード上端より下(=隠れる)なら、
//     その webView を内包する「外側の UIScrollView」の contentOffset を、要素がキーボードの上に
//     余白付きで見える位置まで持ち上げる。
//
// 【なぜ UIScrollView を直接叩くのか(手段選定)】iOS 17 では SwiftUI の ScrollViewReader は
// 「ビュー単位の scrollTo(id:anchor:)」しか無く、focus 要素の**ピクセル位置**へ寄せる術が無い
// (ScrollPosition の offset 指定は iOS 18+)。iOS 17 でも動く経路を優先する指示なので、
// first responder から superview 鎖を辿って SwiftUI ScrollView の裏付け UIScrollView を掴み、
// contentOffset を直接ずらす(introspect ライブラリ非依存・追加依存ゼロ)。
// ボツ案: iOS 18 ScrollPosition(y:) は簡潔だが iOS 17 で無効になり実機(授業/提出は iOS 実機)で
// 直らない場面が残るため却下(財産として記す)。
import UIKit
import WebKit

// MARK: - 純ロジック(座標計算)
//
// キーボード回避は実機/シミュレータ無しではテストしづらい(first responder・WKWebView・window 座標が
// 絡む)。そこで「どれだけ持ち上げるか」の算術だけを副作用ゼロの static 関数に切り出す。
// 【テスト所在の但し書き(親へ報告事項)】この関数は Features ターゲット(XcodeGen 側・SwiftUI)に
// 属し、`swift test`(Kernel/Services の SwiftPM パッケージ)からは到達できない。純算術なので Kernel に
// 置けばテストできるが、CLAUDE.md の Kernel 定義(MCP DTO / ブリッジ型)から外れる汎用ジオメトリを
// Kernel に混ぜたくないため Features 内に留めた。ロジックが自明(1式)なこともあり、単体テストは
// 付けていない(この判断は最終報告に明記する)。
enum InlineCardKeyboardAvoider {
    /// focus 要素をキーボードの上に余白付きで見せるために外側 ScrollView を「上へ」動かす量。
    /// 返り値 > 0 のときだけ実際にスクロールする(0 なら既に見えている=何もしない)。
    ///
    /// - Parameters:
    ///   - elementMaxY: focus 要素の下端の window 座標 Y。
    ///   - keyboardTop: キーボード上端の window 座標 Y。
    ///   - margin: 要素とキーボードの間に残す余白(pt)。
    /// - Returns: 上方向へ動かすべき量(pt)。負にはならない。
    static func scrollUpAmount(elementMaxY: CGFloat, keyboardTop: CGFloat, margin: CGFloat) -> CGFloat {
        // 要素下端 + 余白 が キーボード上端を下回っていなければ隠れていない → 0。
        // 超過している分だけ持ち上げれば「要素下端がキーボード上端 - margin」にちょうど収まる。
        max(0, (elementMaxY + margin) - keyboardTop)
    }

    /// keyboardWillShow を受けて inline カードの focus 要素を可視化する入口。
    /// ChatBodyView が `.onReceive(keyboardWillShowNotification)` から呼ぶ。
    /// - Note: すべて UIKit グローバル(key window / first responder)から辿るので、
    ///   SwiftUI 側は Notification を横流しするだけでよい(WebKit/UIKit を import せずに済む)。
    @MainActor
    static func handleKeyboardWillShow(_ notification: Notification) {
        // キーボード終端フレーム(画面座標)。無ければ何もしない。
        guard let userInfo = notification.userInfo,
              let endFrame = (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }

        // first responder を辿り、それが WKWebView 配下(= カードのテキスト入力)かを判定する。
        // WKWebView の実 first responder は内部の WKContentView なので、responder ではなく
        // その view から superview 鎖を上って WKWebView 祖先を探す。
        guard let responderView = currentFirstResponderView(),
              let webView = enclosingWebView(from: responderView)
        else { return }

        // inline カードだけを対象にする(fullscreen カードは内部スクロール有効で WKWebView 標準の
        // 自動スクロールが効くため、こちらは触らない=壊さない)。scrollEnabled==false が inline の印。
        guard webView.scrollView.isScrollEnabled == false else { return }

        // webView を内包する「外側の」UIScrollView(= SwiftUI ScrollView の裏付け)を探す。
        // webView.superview から上るのがミソ: webView 自身が内部に持つ WKScrollView を飛ばして、
        // チャットのスクロールビューに到達する。見つからなければ(fullscreen 提示中など)何もしない。
        guard let outerScrollView = enclosingScrollView(from: webView) else { return }

        guard let window = webView.window else { return }

        // 【2026-07-18 ユーザー指示で方針転換: focus 要素の矩形 → カード(webView)の下端基準へ】
        // 旧実装は JS(getBoundingClientRect)で focus 要素の矩形を取り「その要素が見えるまで」
        // 持ち上げていた。ユーザーの意図は「mcp-app の描画の**最下端**が、swift 側チャット描画領域の
        // 下端(=キーボード上端)からはみ出さない位置までスクロールする」— カードは inline で
        // 可視高 0.65 倍にクランプ済みなので、下端を収めればカード全体が視野に入り、追加ドラフト行
        // (カード最下部に生える)も自然にキーボード直上へ来る。JS 往復・focus 矩形の座標変換が
        // 丸ごと不要になり、レイアウト確定タイミングへの依存も減る(ボツ案として旧方式を記す:
        // 要素単位の最小移動は「カードの途中の行を編集」時に移動量最小という利点があったが、
        // クランプ済みカードでは下端基準でも全体が見えるため利点が実質消えた)。
        applyScroll(
            webView: webView,
            outerScrollView: outerScrollView,
            window: window,
            keyboardEndFrame: endFrame)
    }

    /// 実際に外側 ScrollView を持ち上げる。カード下端 → scrollUpAmount → contentOffset 更新。
    @MainActor
    private static func applyScroll(
        webView: WKWebView,
        outerScrollView: UIScrollView,
        window: UIWindow,
        keyboardEndFrame: CGRect
    ) {
        // カード(webView)全体の矩形を window 座標で取る。下端 maxY が基準(上の方針コメント)。
        let cardRectInWindow = webView.convert(webView.bounds, to: window)

        // キーボード終端フレームは画面座標。window 座標へ変換して上端 Y を得る。
        let keyboardInWindow = window.convert(keyboardEndFrame, from: window.screen.coordinateSpace)
        let keyboardTop = keyboardInWindow.minY

        // カード下端とキーボードの間に残す余白(pt)。カード下端基準なので旧 24pt ほどの
        // ゆとりは不要(カード枠自体に padding がある)。8pt で「接していない」ことだけ示す。
        let margin: CGFloat = 8
        let amount = scrollUpAmount(
            elementMaxY: cardRectInWindow.maxY, keyboardTop: keyboardTop, margin: margin)
        guard amount > 0 else { return }  // 既に見えている。

        // 目標 offset を計算。上限(コンテンツ末尾)でクランプする。
        // 【2026-07-18 実機 FB「追加行がキーボードに隠れる」で旧クランプを改訂】旧実装は
        // adjustedContentInset.bottom(現在値)をそのまま使っていたが、keyboardWillShow 時点では
        // SwiftUI の自動キーボード回避(下端インセット付与)がまだ反映されておらず、リスト最下部の
        // 行(FAB で生やすドラフト行がまさにここ)では上限が過小評価されて必要量までスクロール
        // できなかった(旧コメントの「取りこぼしは許容」の但し書きが実機で顕在化した)。
        // キーボードは最終的に scrollView 下端と keyboardTop の重なりぶんのインセットを生む
        // (SwiftUI の自動回避と同じ量)ので、その将来値を先取りして上限に織り込む。
        let scrollFrameInWindow = outerScrollView.convert(outerScrollView.bounds, to: window)
        let keyboardOverlap = max(0, scrollFrameInWindow.maxY - keyboardTop)
        let effectiveBottomInset = max(outerScrollView.adjustedContentInset.bottom, keyboardOverlap)
        let maxOffsetY = max(
            0,
            outerScrollView.contentSize.height
                - outerScrollView.bounds.height
                + effectiveBottomInset)
        let targetY = min(outerScrollView.contentOffset.y + amount, maxOffsetY)
        // 既に目標以上にスクロール済みなら動かさない(下スクロール方向へは動かさない)。
        guard targetY > outerScrollView.contentOffset.y else { return }

        let target = CGPoint(x: outerScrollView.contentOffset.x, y: targetY)
        UIView.animate(withDuration: 0.25) {
            outerScrollView.setContentOffset(target, animated: false)
        }
    }

    // MARK: - ビュー階層ヘルパ

    /// アプリ全体の現在の first responder(の UIView)を返す。
    /// `sendAction(to: nil)` は responder chain 上の first responder に届くので、その中で自分を捕まえる
    /// 定番トリック。返るのは WKWebView ではなく内部の WKContentView(UIView)であることに注意。
    @MainActor
    private static func currentFirstResponderView() -> UIView? {
        _firstResponder = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder._inlineCardAvoider_findFirstResponder(_:)), to: nil, from: nil, for: nil)
        return _firstResponder as? UIView
    }

    // sendAction の trap で捕まえた first responder を一時的に置く場所。
    // sendAction → trap → 読み出しは同一メインスレッド上で同期的に完結するため、
    // nonisolated(unsafe) で actor 隔離を外す(@objc trap から書き込むための実務上の逃げ・
    // 実際の競合は起きない)。
    fileprivate nonisolated(unsafe) static var _firstResponder: UIResponder?

    /// view から superview 鎖を上って最初の WKWebView 祖先を返す(自身が WKWebView ならそれ)。
    private static func enclosingWebView(from view: UIView) -> WKWebView? {
        var current: UIView? = view
        while let v = current {
            if let webView = v as? WKWebView { return webView }
            current = v.superview
        }
        return nil
    }

    /// webView の**外側**にある UIScrollView を返す。webView.superview から上ることで、
    /// webView 内部の WKScrollView(webView.scrollView)を飛ばして外側のチャット ScrollView に到達する。
    private static func enclosingScrollView(from webView: WKWebView) -> UIScrollView? {
        var current: UIView? = webView.superview
        while let v = current {
            if let scrollView = v as? UIScrollView { return scrollView }
            current = v.superview
        }
        return nil
    }
}

// first responder 捕獲用トラップ。名前衝突を避けるためプレフィクス付きセレクタにする。
private extension UIResponder {
    @objc func _inlineCardAvoider_findFirstResponder(_ sender: Any?) {
        InlineCardKeyboardAvoider._firstResponder = self
    }
}
