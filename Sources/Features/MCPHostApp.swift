// SwiftUI アプリのエントリーポイント。
// このファイルは project.yml の XcodeGen ターゲット定義 (targets.MCPHost.sources) から
// 参照される。ローカル SwiftPM パッケージ(Kernel/Services)には含めない ——
// SwiftUI App ライフサイクル(@main)はアプリターゲット固有の概念であり、
// Kernel/Services はプラットフォーム非依存/UI 非依存に保つ方針のため
// (CLAUDE.md「アーキテクチャ方針」)。
import SwiftUI

@main
struct MCPHostApp: App {
    var body: some Scene {
        WindowGroup {
            rootView
        }
    }

    /// 起動環境変数でルート画面を切り替える。通常は接続画面、MCPHOST_SPIKE=transport のときは
    /// S2 の transport 疎通ハーネス(TransportSpikeView)を出す。P1 の MCPHOST_AUTOCONNECT と
    /// 同じ流儀で、simctl launch --setenv だけでエージェントが検証画面へ直行できるようにする。
    @ViewBuilder
    private var rootView: some View {
        if ProcessInfo.processInfo.environment["MCPHOST_SPIKE"] == "transport" {
            TransportSpikeView()
        } else if ProcessInfo.processInfo.environment["MCPHOST_SPIKE"] == "todos" {
            // P2 スパイク S4/S5: caldav に OAuth 接続して list-todos カードを1枚描画する。
            // OAuth 対話(changeme 入力→許可)は人手が要るため、起動後にシートが出る。
            TodosCardSpikeView()
        } else if ProcessInfo.processInfo.environment["MCPHOST_SPIKE"] == "reparent" {
            // P4 スパイク(設計 04 §6-1): WKWebView を inline↔sheet で reparent したとき
            // JS 状態が保たれるかを実測する自己完結ハーネス(MCP 接続不要)。
            ReparentSpikeView()
        } else {
            // 通常起動は P3-T4 のチャット主画面。P1 の ConnectionView(OAuth デバッグ画面)は
            // 残す(型は生きているので参照は切れない)が、既定導線はチャットにする
            // (docs/design/02-chat-llm.md §8 T4「MCPHOST_SPIKE でなく通常起動の主画面にする」)。
            ChatHomeView()
        }
    }
}
