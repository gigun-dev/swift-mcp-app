// ホストの外観(SwiftUI colorScheme)を MCP Apps の hostContext.theme / styles へ変換する(#5)。
//
// このファイルは「iOS のシステム外観 → ext-apps のテーマ契約」の翻訳だけを担う。UIColor(UIKit)や
// SwiftUI ColorScheme に依存するので Kernel には置けず(プラットフォーム非依存が Kernel の条件・
// CLAUDE.md)、Features に置く。Session(Services/actor)はここで作った値を受け取って initialize /
// host-context-changed に載せるだけ(AppsBridgeSession.notifyThemeChanged のコメント参照)。
//
// 【なぜ UIColor から導出するのか(spec の意図・apps.mdx:822-882)】host-context の styles は
// 「ホストの見た目にカードを馴染ませる」ための CSS 変数群。iOS の意味カラー(systemBackground・label 等)は
// ライト/ダークで自動的に色が変わるので、これを解決してカードへ渡せば、カードは prefers-color-scheme を
// 自前で持たなくてもホストと同じ配色になる。ダーク時は systemBackground が黒系・label が白系に解決される。
import SwiftUI
import UIKit
import Kernel  // UITheme・HostStyles・UIStyleVariableKey

/// colorScheme → hostContext の theme/styles を組み立てる純ヘルパ(状態を持たない)。
enum HostThemeBuilder {
    /// SwiftUI の colorScheme を ext-apps の McpUiTheme("light"|"dark")へ写す。
    /// SwiftUI ColorScheme は将来値が増えうる列挙なので、.dark 以外はすべて light に倒す(安全側)。
    static func theme(for scheme: ColorScheme) -> UITheme {
        scheme == .dark ? .dark : .light
    }

    /// colorScheme に対応する CSS 変数トークン(最小セット)を組む。
    ///
    /// 【最小セットの選定理由】spec の McpUiStyleVariableKey は 70 個超あるが、v1 は「iOS の意味カラーから
    /// 1対1で素直に導出でき、かつカードの基本的な地色・文字色・境界・アクセントを賄える6キー」に絞る:
    ///   - 背景 primary/secondary(地とカード内の一段沈んだ面)
    ///   - 文字 primary/secondary(本文と補助テキスト)
    ///   - 境界 primary(区切り線)
    ///   - リング primary(フォーカス/アクセント色 = システムの tint)
    /// font/radius/shadow 系や info/danger/success 等の意味色は、iOS 側に 1対1 の意味カラーが無く恣意的な
    /// 対応づけになる(= 勝手な命名に近い)ので v1 では出さない。部分提供は spec 上合法(UIStyleVariableKey の
    /// コメント参照)なので、カード側は未提供キーを自前既定にフォールバックする。
    static func styles(for scheme: ColorScheme) -> HostStyles {
        // UIColor の意味カラーは「解決する trait」次第で色が変わる。SwiftUI の colorScheme から
        // 明示的に userInterfaceStyle を作って解決する(環境の現在 trait に依存させず決定的にする)。
        let trait = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)

        let variables: [String: String] = [
            UIStyleVariableKey.colorBackgroundPrimary: css(.systemBackground, trait),
            UIStyleVariableKey.colorBackgroundSecondary: css(.secondarySystemBackground, trait),
            UIStyleVariableKey.colorTextPrimary: css(.label, trait),
            UIStyleVariableKey.colorTextSecondary: css(.secondaryLabel, trait),
            UIStyleVariableKey.colorBorderPrimary: css(.separator, trait),
            // tintColor = システムのアクセント(既定はシステムブルー)。フォーカスリング色に流用する。
            UIStyleVariableKey.colorRingPrimary: css(.tintColor, trait),
        ]
        return HostStyles(variables: variables)
    }

    /// UIColor を指定 trait で解決し、CSS の `rgba(r, g, b, a)` 文字列へ変換する。
    /// 意味カラー(systemBackground 等)は trait を与えないと現在の環境で解決されてしまうので、
    /// 必ず resolvedColor(with:) で明示解決する。r/g/b は 0-255 整数、a は小数3桁。
    private static func css(_ color: UIColor, _ trait: UITraitCollection) -> String {
        let resolved = color.resolvedColor(with: trait)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = Int((r * 255).rounded())
        let gi = Int((g * 255).rounded())
        let bi = Int((b * 255).rounded())
        return "rgba(\(ri), \(gi), \(bi), \(String(format: "%.3f", a)))"
    }
}
