// チャット出力のハプティクフィードバック(ChatGPT iOS アプリ風・ユーザー要望 2026-07-17)。
//
// UIKit(UIImpactFeedbackGenerator / UINotificationFeedbackGenerator)に直接依存するため
// Kernel/Services には置けず Features 層に置く(CLAUDE.md「Kernel はプラットフォーム非依存」・
// Services も MCP/LLM 関心のみで UI トリガの発火は View 層の関心)。
// スロットル判定(いつ鳴らしてよいか)だけは純関数として Kernel/Haptics/HapticThrottle.swift に
// 切り出してあり、ここは「判定に従って実際に generator を鳴らす」薄い配線に留める。
import UIKit
import Kernel  // ToolCallStep・HapticThrottle

/// チャット画面(ChatBodyView)が保持するハプティクス発火役。
///
/// 【View に @State で1個持たせる設計にした理由】UIFeedbackGenerator はインスタンスを使い回すほど
/// `prepare()` の効果(次の発火の遅延低減)が活きる。呼び出しのたびに generator を new すると
/// prepare() の意味が薄れるため、画面の生存期間中1個を保持して使い回す(InlineCardRegistry や
/// FullscreenCoordinator と同じ「@State で1個所有」のパターンに揃えた)。
@MainActor
final class ChatHapticsController {
    // ストリーミング tick 用。ChatGPT アプリの「テキストが刻まれてる感」を狙うが、強い impact だと
    // 電池も食う上にトークンが速いモデルではガタガタ震えて不快になる。`.soft` スタイル +
    // intensity 0.5(中間値)を採用: `.rigid`/`.heavy` は硬すぎて連打に向かない、
    // intensity を 1.0 に張ると1発ごとの主張が強すぎて「通知」寄りの感触になってしまうため、
    // 「触れているかどうか分かる程度」を狙って弱めに倒した(実機での主観調整・数値自体に厳密な
    // 根拠はないので今後 realistic に感じなければ 0.4〜0.6 の範囲で調整してよい・§可逆)。
    private let streamingImpact = UIImpactFeedbackGenerator(style: .soft)
    private static let streamingIntensity: CGFloat = 0.5

    // 送信時は「操作が確定した」という軽い合図なので `.light` 1発(タスク指示どおり)。
    private let sendImpact = UIImpactFeedbackGenerator(style: .light)

    // ツールステップの完了/失敗は「結果の通知」なので Notification 系(success/error)を使う。
    // success/error 兼用で1個の generator を使い回す(UINotificationFeedbackGenerator は
    // notificationOccurred(_:) の引数で種別を切り替えるだけなので複数持つ理由がない)。
    private let toolNotification = UINotificationFeedbackGenerator()

    // ストリーミング tick の最小間隔。毎トークン(数十 ms 間隔で届きうる)ごとに鳴らすと
    // 「震え続ける」だけで刻まれてる感が失われ、電池・触感どちらの面でも過剰。
    // 100ms を採用した理由: 人間が個々の触感パルスを「連続した質感」ではなく「独立した刻み」として
    // 知覚できる下限がおおよそこの近辺(一般に触覚の弁別閾は視覚より粗く、100ms 程度の間隔があれば
    // 個々のパルスが潰れず「刻まれてる」感が出る、というのが体感的な落としどころ)。
    // これより短いと機種・気分によってはブザーのように感じられ、長いと「たまに震える」程度になり
    // ChatGPT アプリの体感に届かない、という主観調整の結果(実機検証で必要なら詰める・タスク指示)。
    private var streamingThrottle = HapticThrottle(minInterval: 0.1)

    /// 画面表示時に呼ぶ。generator を prepare しておくと最初の発火の遅延が減る
    /// (UIKit の推奨パターン。使うタイミングの近くで呼ぶのが理想だが、チャット画面は
    /// 「開いたらすぐ使われうる」画面なので表示直後にまとめて prepare する)。
    func prepareAll() {
        streamingImpact.prepare()
        sendImpact.prepare()
        toolNotification.prepare()
    }

    /// assistant 応答テキストが伸びた(ストリーミング中)ときに呼ぶ。スロットルを通り、
    /// 発火するときだけ prepare→impactOccurred する(鳴らさなかったときに毎回 prepare し直すと
    /// 逆に無駄な準備コストが積み上がるため、発火する回だけ prepare する)。
    func streamingTick(now: Date = Date()) {
        guard streamingThrottle.shouldFire(now: now) else { return }
        streamingImpact.prepare()
        streamingImpact.impactOccurred(intensity: Self.streamingIntensity)
    }

    /// メッセージ送信時に呼ぶ。
    func sent() {
        sendImpact.prepare()
        sendImpact.impactOccurred()
    }

    /// カード内のユーザー操作(done/undo チェック・追加・削除等)で呼ぶ(ユーザー要望 2026-07-17)。
    /// カードのタップ自体はホストから不可視だが、操作は必ず bridge の tools/call 素通しを通るため、
    /// AppsBridgeSession.onCardToolCall → InlineCardHost.onCardToolCall 経由でここに届く
    /// (任意の MCP アプリに中立に効く・ビジョン2)。send と同じ .light を共用する(チェックボックス系の
    /// 標準的な感触。スロットルは不要 — 操作は人間のタップ律速で、streaming のような高頻度にならない)。
    func cardAction() {
        sendImpact.prepare()
        sendImpact.impactOccurred()
    }

    /// turn.toolSteps が変化したときに呼ぶ(ChatBodyView の `.onChange(of: turn.toolSteps)` の
    /// (oldValue, newValue) 版から配線する。SwiftUI が新旧を渡してくれるので、このコントローラ自身は
    /// 前回状態を保持する必要がない=状態を持たない薄いロジックのまま保てる)。
    ///
    /// 【うるさくならない設計(タスク指示で裁量)】
    /// - failed は**必ず**鳴らす: 個々のツール失敗はユーザーが気付くべき重要イベントで、
    ///   複数ツールが連続しても失敗ごとに知らせる価値がある(見逃すコストの方が大きい)。
    ///   同じ index が既に failed だった(=前回検知済み)場合は再発火しない(1回のみ)。
    /// - done(成功)は**連続ツール実行の最後だけ**鳴らす: 3ツールを連鎖で呼ぶような
    ///   ターンで毎回 success を鳴らすと「ずっと鳴ってる」体験になり、ChatGPT アプリのような
    ///   控えめさから外れる。「最後の要素が done に変わった」ときだけを成功の合図とする
    ///   (＝そのターンのツール実行列が完了した瞬間の1回)。並行実行時に配列の最後が先に done に
    ///   なるケースは現状の ChatViewModel の逐次実行モデルでは起きない想定(こう解釈)。
    func toolSteps(didChangeFrom old: [ToolCallStep], to new: [ToolCallStep]) {
        // failed: 新しく failed になった要素があれば都度エラー通知(取りこぼさない)。
        for (index, step) in new.enumerated() {
            guard step.state == .failed else { continue }
            let alreadyFailed = index < old.count && old[index].state == .failed
            guard !alreadyFailed else { continue }
            toolNotification.prepare()
            toolNotification.notificationOccurred(.error)
        }

        // done: 配列末尾が新たに done になった(=そのターンのツール実行列が完了した)ときだけ成功通知。
        guard let lastNew = new.last, lastNew.state == .done else { return }
        let lastWasAlreadyDoneAtSamePosition = old.count == new.count && old.last?.state == .done
        guard !lastWasAlreadyDoneAtSamePosition else { return }
        toolNotification.prepare()
        toolNotification.notificationOccurred(.success)
    }

    // 将来のために: システムのハプティクス設定(アクセシビリティ > タッチ > システムハプティクス)が
    // OFF のときは UIFeedbackGenerator 側が自動で無音になる(UIKit の仕様)ため、このコントローラで
    // 独自の ON/OFF トグルは持たない。アプリ内設定でハプティクスだけ個別に消したいという要望が
    // 将来出た場合は、この controller に `isEnabled: Bool` を足して各メソッド冒頭で guard する形が
    // 最小差分になる(現状はスコープ外・タスク指示どおり作らない)。
}
