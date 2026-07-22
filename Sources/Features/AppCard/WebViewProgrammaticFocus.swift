// プログラム的 focus() でもキーボードを開かせるための WKWebView ワークアラウンド。
//
// 【なぜ必要か(2026-07-18 実機 FB「追加押しても text field に focus 入らない」)】
// iOS の WKWebView は、JS の element.focus() を「ユーザー操作(タップ等)の同期ハンドラ内」で
// 呼ばれたときにしかキーボード表示まで進めない(WebKit の userIsInteracting ゲート)。
// caldav todos カードの追加フローは 2026-07-18 の常時 fullscreen 昇格化で
//   ⊕ タップ → requestDisplayMode の応答待ち(Promise)→ 450ms 遅延(ズーム遷移との直列化)→ focus()
// とジェスチャの外に focus が出たため、iOS がキーボード表示を拒否するようになった。
// カード側で「タップ内で focus」に戻すとズーム遷移とキーボードが再び同時に走り、
// 「最大化の中心が右上へ流れる」ブレ(直列化で解決済み)が再発する — 順序はカードの都合が正しく、
// ゲートの方をホストが外すのが筋(汎用 MCP Apps ホストとして、どのカードの遅延 focus も通す)。
//
// 【手法(私 API スウィズル・既知の定番)】WKWebViewConfiguration に公開ノブが無いため、
// WKContentView(WKWebView 内部の first responder)の
//   _elementDidFocus:userIsInteracting:blurPreviousNode:activityStateChanges:userObject:
// の実装を差し替え、userIsInteracting を常に true で元実装へ渡す。React Native WebView の
// `keyboardDisplayRequiresUserAction: false` や Cordova(KeyboardDisplayRequiresUserAction)が
// 長年使っている同一手法(iOS 13 以降このセレクタ・iOS 17/18 でも有効なことを実機で確認する)。
// 【リスク・但し書き】私 API 名への依存なので OS 更新でセレクタが変わると黙って無効化される
// (クラッシュはしない — メソッドが見つからなければ何もしない安全側)。App Store 審査での
// リジェクトリスクは歴史的に低い(RN/Cordova 製アプリが大量に通っている)が、SaaS 展開時に
// 問題化したら「カード側にタップ内 focus モードを追加する」代替へ切り替える(ボツ第一候補として記す)。
// 【副作用の範囲】スウィズルはプロセス全体の WKContentView に効く(= 本アプリの全カード)。
// 本アプリの WKWebView はすべて MCP Apps カード(自動 focus を歓迎する UI アプリ)なので許容。
import UIKit
import WebKit

enum WebViewProgrammaticFocus {
    /// 一度だけスウィズルを適用する(2回目以降は no-op)。カード生成経路(AppCardWebViewFactory.make)
    /// から毎回呼んでよい(dispatch once 相当を static let で担保)。
    static func enableKeyboardWithoutUserAction() {
        _ = applyOnce
    }

    // Swift の static let は遅延 + スレッドセーフに1回だけ初期化される(dispatch_once 相当)。
    private static let applyOnce: Void = {
        guard let contentViewClass: AnyClass = NSClassFromString("WKContentView") else { return }
        // iOS 13.0+ のセレクタ(それ以前の変遷は対象 OS(iOS 17+)外なので分岐しない)。
        let selector = sel_getUid(
            "_elementDidFocus:userIsInteracting:blurPreviousNode:activityStateChanges:userObject:"
        )
        guard let method = class_getInstanceMethod(contentViewClass, selector) else {
            // セレクタが OS 更新で消えた場合はここに落ちる(機能は静かに無効化・クラッシュしない)。
            return
        }
        // 引数: (self, _cmd, node*, userIsInteracting, blurPreviousNode, activityStateChanges, userObject)
        typealias OriginalImp = @convention(c) (Any, Selector, UnsafeRawPointer, Bool, Bool, UInt, Any?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: OriginalImp.self)
        // ObjC ABIの全引数を同一closureで受けるため、改行するとSwiftLint規則とは両立しない。
        // swiftlint:disable closure_parameter_position
        let block: @convention(block) (Any, UnsafeRawPointer, Bool, Bool, UInt, Any?) -> Void = { hostView, node,
            _, blurPrevious, stateChanges, userObject in
            // userIsInteracting を true に固定して元実装へ(これがゲート解除の全て)。
            original(hostView, selector, node, true, blurPrevious, stateChanges, userObject)
        }
        // swiftlint:enable closure_parameter_position
        method_setImplementation(method, imp_implementationWithBlock(block))
    }()
}
