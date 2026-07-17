// ストリーミング tick ハプティクスのスロットル判定(純関数・プラットフォーム非依存)。
//
// 【なぜ Kernel に置くか】発火そのもの(UIImpactFeedbackGenerator)は UIKit 依存で Features 層
// (ChatHaptics.swift)にしか置けないが、「いつ発火してよいか」の判定は Date の引き算だけの
// 純粋なロジックであり、UIKit 実機なしでも swift-testing で検証できる。CLAUDE.md の
// 「コードで検証できるものはコードで確定させる」に従い、判定だけ切り出して Kernel に置いた
// (ChatHaptics.swift 側は HapticThrottle.shouldFire の結果に従って generator を鳴らすだけの薄い配線)。
//
// Date/TimeInterval は Foundation 由来だが UIKit/SwiftUI ではなくプラットフォーム非依存なので
// Kernel の「外部依存を持ち込まない」制約(swift-sdk・UIKit・SwiftUI 不可)には抵触しない
// (Kernel の他ファイルも Foundation は普通に import している)。
//
// 【スロットル間隔を呼び出し側でなくここで固定しない理由】値そのもの(ChatHaptics.swift で 100ms を
// 採用)は「ChatGPT アプリ風の刻まれてる感 vs 電池・過剰感」という UX 判断であり Kernel の関心事では
// ない。HapticThrottle はあくまで「与えられた間隔で次の発火可否を判定する」汎用ロジックに留める。
import Foundation

public struct HapticThrottle: Sendable {
    /// 前回発火からこの間隔(秒)未満なら次の shouldFire は false を返す。
    public let minInterval: TimeInterval

    /// 直近の発火時刻。まだ一度も発火していなければ nil(その場合は必ず発火してよい)。
    private var lastFireDate: Date?

    public init(minInterval: TimeInterval) {
        self.minInterval = minInterval
        self.lastFireDate = nil
    }

    /// `now` の時点で発火してよいかを判定する。true を返したときだけ内部の lastFireDate を更新する
    /// (呼んだのに実際には鳴らさない=判定だけしたいケースは無い想定のため、判定と記録を1メソッドに
    /// まとめている。分けると「判定したのに記録し忘れる」呼び出しミスの余地が生まれるため)。
    public mutating func shouldFire(now: Date) -> Bool {
        if let last = lastFireDate, now.timeIntervalSince(last) < minInterval {
            return false
        }
        lastFireDate = now
        return true
    }
}
