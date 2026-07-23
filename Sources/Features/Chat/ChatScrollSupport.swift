import SwiftUI

/// ChatHomeView の DragGesture.startLocation と、子孫の MCP App frame を同じ座標で比較するための名前。
/// `.global` は sheet/window 変化の影響を受けるため、drawer の main card 内に閉じた座標空間を使う。
enum MCPAppGestureCoordinateSpace {
    static let name = "mcp-app-gesture-space"
}

/// 現在 View tree に載っている MCP App の矩形を集約する。LazyVStack で画面外のカードが外れれば
/// preference からも自然に消え、open gesture の除外帯は「現在見えているカード」に追従する。
struct MCPAppFrameKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// live/static を問わず、MCP App を実際に描画する外枠へ付ける。x範囲ではなく縦帯全体を
    /// host gesture から除外するのは、カード近傍の横操作を誤ってdrawerへ渡さないユーザー契約による。
    func reportsMCPAppGestureFrame() -> some View {
        background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: MCPAppFrameKey.self,
                    value: [geometry.frame(in: .named(MCPAppGestureCoordinateSpace.name))]
                )
            }
        )
    }
}

/// メッセージ列の内側幅(カード列幅)を GeometryReader → onPreferenceChange で吸い上げる鍵(設計 §5)。
/// 最大値を採る reduce にしておく(複数 reader が競合しても列の実幅に収束する)。
struct ColumnWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// チャット可視領域(ScrollView ビューポート)の高さを吸い上げる鍵(P4-DM・設計 04 §5 H1)。
/// inline カードの実 maxHeight = floor(可視高 × 0.65)の分母。幅と同じく最大値 reduce にしておく。
struct VisibleHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 最下部センチネルの maxY を "chatScroll" 座標空間で吸い上げる鍵(↓ ボタンのしきい値判定・上記コメント)。
/// スクロール位置に応じて動く値なので、幅/可視高のような「最大値 reduce」ではなく最後の値をそのまま採る
/// (センチネルは1個だけなので nextValue が実質そのまま最新値になる)。
struct BottomSentinelYKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// ChatGPT 式の「息をする丸」(2026-07-17 ユーザー裁定・thinkingIndicator のコメント参照)。
/// 直径 12pt の丸が 0.55⇄1.0 のスケールと薄い⇄濃いの opacity を ~0.9s 周期で往復する。
/// 値は ChatGPT iOS の見た目の近似(正確な仕様は非公開なので目視合わせ・1定数ずつ可逆)。
/// prefers-reduced-motion(SwiftUI は accessibilityReduceMotion)ではアニメを止めて静止した丸のみ。
struct ThinkingPulseDot: View {
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(Color.primary.opacity(pulsing ? 0.85 : 0.35))
            .frame(width: 12, height: 12)
            .scaleEffect(pulsing ? 1.0 : 0.55)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.45).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = true }
    }
}
