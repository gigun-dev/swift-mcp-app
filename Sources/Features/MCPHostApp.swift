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
            ContentView()
        }
    }
}
