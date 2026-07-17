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

        // focus 要素の矩形を JS で取得(input/textarea/contenteditable のときだけ返す)。
        // 内部スクロール無効なので getBoundingClientRect の viewport 原点 = webView 左上。
        let js = """
        (function(){\
        var e=document.activeElement;\
        if(!e){return null;}\
        var t=e.tagName?e.tagName.toLowerCase():'';\
        if(t==='input'||t==='textarea'||e.isContentEditable){\
        var r=e.getBoundingClientRect();\
        return JSON.stringify({x:r.left,y:r.top,w:r.width,h:r.height});\
        }\
        return null;})()
        """
        webView.evaluateJavaScript(js) { result, _ in
            // 完了ハンドラはメインスレッド。@MainActor へ渡すため Task で包む(evaluateJavaScript の
            // completion は @Sendable 非分離クロージャで、@MainActor 隔離の UIView を直接触れない)。
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let rect = try? JSONDecoder().decode(FocusRect.self, from: data)
            else { return }
            Task { @MainActor in
                applyScroll(
                    webView: webView,
                    outerScrollView: outerScrollView,
                    window: window,
                    focusRect: rect,
                    keyboardEndFrame: endFrame)
            }
        }
    }

    /// JS が返す focus 要素矩形(webView ローカル座標・pt)。
    private struct FocusRect: Decodable {
        let x: CGFloat
        let y: CGFloat
        let w: CGFloat
        let h: CGFloat
    }

    /// 実際に外側 ScrollView を持ち上げる。座標変換 → scrollUpAmount → contentOffset 更新。
    @MainActor
    private static func applyScroll(
        webView: WKWebView,
        outerScrollView: UIScrollView,
        window: UIWindow,
        focusRect: FocusRect,
        keyboardEndFrame: CGRect
    ) {
        // webView ローカル矩形 → window 座標へ変換(内部スクロール無効なので origin 補正は不要)。
        let localRect = CGRect(x: focusRect.x, y: focusRect.y, width: focusRect.w, height: focusRect.h)
        let rectInWindow = webView.convert(localRect, to: window)

        // キーボード終端フレームは画面座標。window 座標へ変換して上端 Y を得る。
        let keyboardInWindow = window.convert(keyboardEndFrame, from: window.screen.coordinateSpace)
        let keyboardTop = keyboardInWindow.minY

        // 要素とキーボードの間に残す余白(pt)。QuickType バー相当も含め少しゆとりを持たせる。
        let margin: CGFloat = 24
        let amount = scrollUpAmount(
            elementMaxY: rectInWindow.maxY, keyboardTop: keyboardTop, margin: margin)
        guard amount > 0 else { return }  // 既に見えている。

        // 目標 offset を計算。上限(コンテンツ末尾)でクランプする。
        // 【タイミングの但し書き】keyboardWillShow 時点では SwiftUI の自動キーボード回避
        // (ScrollView 下端インセット付与)がまだ反映されていない場合があり、contentSize/インセットが
        // 過小評価されてクランプが厳しすぎることがある。JS 評価の非同期分だけ実質遅延が入るため多くの場合は
        // 問題にならないが、取りこぼす場合は「出現時1回」の v1 仕様(タスク指示)の範囲で許容する。
        let maxOffsetY = max(
            0,
            outerScrollView.contentSize.height
                - outerScrollView.bounds.height
                + outerScrollView.adjustedContentInset.bottom)
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
