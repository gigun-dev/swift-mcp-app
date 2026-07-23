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

    /// gesture 開始直後に一度だけ決める追従軸。UIScrollView の direction lock と同じ考え方で、
    /// 以後この軸を固定して迷わない。
    public enum Axis: Sendable {
        case horizontal
        case vertical
    }

    // 2026-07-23 カクつき修正: 旧実装は liveTranslation/commits が「毎フレームの累積 translation」で
    // abs(horizontal) > abs(vertical) を判定していた。フリックは一気に横成分が勝つので問題ないが、
    // 指を付けたままゆっくり斜めに動かすと横縦が拮抗し、フレームごとに判定が反転 → translation が
    // 「実値 ↔ 0」を往復して境界がカクついた。UIScrollView 同様、最初に軸を1度だけロックして解決する。
    /// gesture の最初の onChanged(minimumDistance 到達時点)の累積 translation で軸を一度だけ決める。
    /// この時点なら 12pt(または tapSlop 超え)ぶん動いており、ユーザーの意図方向が十分に現れている。
    public static func lockAxis(horizontal: Double, vertical: Double) -> Axis {
        // 判定基準は旧 liveTranslation と同じ abs 比較。違いは「毎フレーム」ではなく「初回だけ」呼ぶこと。
        abs(horizontal) > abs(vertical) ? .horizontal : .vertical
    }

    /// MCP App の縦帯から始まった open gesture は拒否する。x方向を見ないのは、ユーザー契約が
    /// 「カードの現在の縦領域では横操作をすべて App に渡す」だからで、カード外余白だけを狙う必要がない。
    public static func canStartOpen(atY startY: Double, excludedVerticalBands: [ClosedRange<Double>]) -> Bool {
        !excludedVerticalBands.contains { $0.contains(startY) }
    }

    /// 横ロック済みの gesture 前提で、intent と逆方向だけ 0 に丸める。縦横比較はしない
    /// (縦ロック時は呼び出し側が本関数を呼ばず translation を 0 のまま据え置く — 軸ロック方式)。
    /// 縦成分を引数から外したのは、ロック後は縦成分をいっさい見ないことを型で示すため。
    public static func liveTranslation(
        horizontal: Double,
        intent: Intent
    ) -> Double {
        switch intent {
        case .open:
            return max(horizontal, 0)
        case .close:
            return min(horizontal, 0)
        }
    }

    /// 長距離を要求しない22%閾値と、短いflickを拾う100ptの予測差をopen/closeで対称に適用する。
    /// 縦横比較はしない — 横ロック済みの gesture だけが commit 判定に到達する契約(呼び出し側で
    /// 軸をロックし、縦ロックの gesture はここへ来ない。旧 abs 比較 guard は軸ロックへ移設した)。
    public static func commits(
        horizontal: Double,
        predictedHorizontal: Double,
        revealWidth: Double,
        intent: Intent
    ) -> Bool {
        let positionThreshold = revealWidth * 0.22
        let projectedVelocity = predictedHorizontal - horizontal
        switch intent {
        case .open:
            return horizontal > positionThreshold || projectedVelocity > 100
        case .close:
            return horizontal < -positionThreshold || projectedVelocity < -100
        }
    }

    /// 露出mainのtapとleft-dragを別 recognizer にしない。tapSlop以内ならtapとして閉じ、それを超えた
    /// 移動は軸ロック結果で分岐する。縦ロック(縦scroll)は remainOpen、横ロックは close判定を通った
    /// 左dragだけ閉じる。lockedAxis は onChanged 初回でロックした軸(slop 未満なら nil のまま)。
    public static func resolveExposedMain(
        horizontal: Double,
        vertical: Double,
        predictedHorizontal: Double,
        revealWidth: Double,
        lockedAxis: Axis?,
        tapSlop: Double = 8
    ) -> ExposedMainResolution {
        // slop 内(=軸未ロック)は微小移動の tap 扱い。誤って drag として remainOpen にしない。
        if lockedAxis == nil || horizontal * horizontal + vertical * vertical <= tapSlop * tapSlop {
            return .close
        }
        // 縦ロックの gesture は commit 判定に到達させない(縦scroll を close に誤変換しない)。
        guard lockedAxis == .horizontal else { return .remainOpen }
        return commits(
            horizontal: horizontal,
            predictedHorizontal: predictedHorizontal,
            revealWidth: revealWidth,
            intent: .close
        ) ? .close : .remainOpen
    }
}
