// Drawer の見た目や SwiftUI gesture wiring から、方向・除外帯・確定閾値の判断だけを分離する。
// UIKit/SwiftUI の型を持ち込まず Double と ClosedRange だけで表すため、Simulator無しで境界値を検証できる。

/// チャット履歴 drawer の横操作を判定する純関数群。
public enum SidebarGesturePolicy {
    /// 指追従させる方向。open は正方向、close は負方向だけを通す。
    public enum Intent: Sendable {
        case open
        case close
    }

    /// 開いた main card 上の minimumDistance=0 gesture を、tap と drag のどちらとして終えるか。
    public enum ExposedMainResolution: Equatable, Sendable {
        case close
        case remainOpen
    }

    /// MCP App の縦帯から始まった open gesture は拒否する。x方向を見ないのは、ユーザー契約が
    /// 「カードの現在の縦領域では横操作をすべて App に渡す」だからで、カード外余白だけを狙う必要がない。
    public static func canStartOpen(atY startY: Double, excludedVerticalBands: [ClosedRange<Double>]) -> Bool {
        !excludedVerticalBands.contains { $0.contains(startY) }
    }

    /// 縦優位の移動は drawer を追従させず、横優位でも intent と逆方向は 0 に丸める。
    public static func liveTranslation(
        horizontal: Double,
        vertical: Double,
        intent: Intent
    ) -> Double {
        guard abs(horizontal) > abs(vertical) else { return 0 }
        switch intent {
        case .open:
            return max(horizontal, 0)
        case .close:
            return min(horizontal, 0)
        }
    }

    /// 長距離を要求しない22%閾値と、短いflickを拾う100ptの予測差をopen/closeで対称に適用する。
    public static func commits(
        horizontal: Double,
        vertical: Double,
        predictedHorizontal: Double,
        revealWidth: Double,
        intent: Intent
    ) -> Bool {
        guard abs(horizontal) > abs(vertical) else { return false }
        let positionThreshold = revealWidth * 0.22
        let projectedVelocity = predictedHorizontal - horizontal
        switch intent {
        case .open:
            return horizontal > positionThreshold || projectedVelocity > 100
        case .close:
            return horizontal < -positionThreshold || projectedVelocity < -100
        }
    }

    /// 露出mainのtapとleft-dragを別 recognizer にしない。8pt以内ならtapとして閉じ、それを超えた
    /// 移動はclose判定を通った左dragだけ閉じる。縦scrollや右dragを誤ってtap closeへ戻さない。
    public static func resolveExposedMain(
        horizontal: Double,
        vertical: Double,
        predictedHorizontal: Double,
        revealWidth: Double,
        tapSlop: Double = 8
    ) -> ExposedMainResolution {
        if horizontal * horizontal + vertical * vertical <= tapSlop * tapSlop {
            return .close
        }
        return commits(
            horizontal: horizontal,
            vertical: vertical,
            predictedHorizontal: predictedHorizontal,
            revealWidth: revealWidth,
            intent: .close
        ) ? .close : .remainOpen
    }
}
