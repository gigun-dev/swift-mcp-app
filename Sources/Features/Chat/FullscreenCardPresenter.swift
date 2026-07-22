// fullscreen カードの調停役 + sheet 器(P4-DM・設計 04 §5 H4-C/E・決定2/2b)。
//
// このファイルは H4 の Features 側 2 要素を持つ:
//  1. FullscreenCoordinator: 「今どのカードが fullscreen 昇格中か」の単一状態(高々1枚・決定2b)。
//     カード横断の判断なので単一の InlineCardHost には置けず、ChatBodyView 層(registry の隣)に置く。
//  2. FullscreenCardView: sheet に載せる中身。モック合意(§5 H4)どおり「カードが sheet 全面・ホストは
//     グラバー(チキ)のみ・カード自前 sticky ヘッダがそのまま上端・内部スクロール・下スワイプで戻る」。
//     ホストのナビバー(タイトル+閉じるボタン)は重ねない(カードの『完了』と二重になる案は却下・§5 H4)。
import SwiftUI
import Kernel    // ContainerDimensions
import Services  // DisplayModeResolution

/// fullscreen 昇格の調停役(決定2b: 常に高々1カード)。ChatBodyView が @State で1個所有する。
///
/// なぜ ChatBodyView 層か(設計 04 §3 責務表): 「今どのカードが fullscreen か」はカード横断の判断で、
/// 単一の InlineCardHost には収まらない。sheet は同時1枚しか出せないので、既に1枚昇格中なら2枚目の
/// 要求は拒否する(apps.mdx:787「モードを変えなかった場合も結果のモードを返す」に適合)。
@MainActor
@Observable
final class FullscreenCoordinator {
    /// 現在 fullscreen 昇格中のカード(nil = 無し)。`.sheet(item:)` のトリガも兼ねる。
    var activeHost: InlineCardHost?

    /// カード発の fullscreen 要求を捌く(§5 H4-C・決定2b)。
    /// - 誰も昇格していない(activeHost==nil)なら受理: activeHost をセット・host.displayMode=.fullscreen にし、
    ///   推定寸法つきで `.fullscreen` を返す。→ Session が result.mode + host-context-changed を送る。
    /// - 既に**別**カードが昇格中なら拒否: `.inline` を返す(sheet は1枚だけ)。
    /// - 同一カードの再要求(通常来ないが冪等性のため)は受理扱いで `.fullscreen` を返す。
    func requestFullscreen(_ host: InlineCardHost, estimatedDimensions: ContainerDimensions) -> DisplayModeResolution {
        if activeHost == nil {
            activeHost = host
            host.displayMode = .fullscreen  // 単一の真実を更新(sheet 側 AppCardView が adopt する条件)。
            return DisplayModeResolution(mode: .fullscreen, containerDimensions: estimatedDimensions)
        }
        if activeHost === host {
            // 既に自分が昇格中。冪等に fullscreen を返す(displayMode は既に .fullscreen)。
            return DisplayModeResolution(mode: .fullscreen, containerDimensions: estimatedDimensions)
        }
        // 別カードが占有中 → 拒否(現状維持=inline)。host.displayMode は触らない。
        return DisplayModeResolution(mode: .inline)
    }

    /// sheet を閉じて inline へ戻す(下スワイプ dismiss・§5 H4-E)。順序固定の復帰処理は host.restoreInline() が担う
    /// (rehome → scrollEnabled=false → host-context-changed)。ここでは activeHost をクリアするだけ。
    func dismiss() {
        activeHost?.restoreInline()
        activeHost = nil
    }
}

/// sheet に載る fullscreen カード本体(§5 H4 モック合意)。カードを全面に広げ、内部スクロールを許す。
/// グラバー(presentationDragIndicator)だけ出し、ホストのナビバー・閉じるボタンは重ねない
/// (カードの sticky ヘッダ『完了』と役割が重ならない中立設計・ビジョン2)。
struct FullscreenCardView: View {
    let host: InlineCardHost
    // fullScreenCover の閉じ口(§5 決定2 更新 2026-07-17)。⤡ ボタンがこれを呼ぶと、ChatBodyView の
    // activeHostBinding.set(nil) 経路が走り coordinator.dismiss()(= restoreInline の固定順序復帰)に繋がる
    // ——⤡ は環境 dismiss を叩くだけで、復帰処理を二重に持たない(単一経路)。
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // 上端の最小ホストストリップ(§5 決定2 更新): タイトル無し・境界線無し・右端に ⤡ のみ。
            // inline のカード枠右上 ⤢ と同位置(右上)で拡大↔復元が対称になる。ホストの UINavigationBar
            // (タイトル+テキストボタン)は置かない合意を維持(⤡ はアイコン=空間操作の別語彙で、
            // カード自前ヘッダの「完了」= 編集確定 とは役割が違うので二重感が出ない)。
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")   // ⤡ = 縮小(⤢ と対称)。
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("元のサイズに戻す")
            }
            .padding(.horizontal, 8)
            .frame(height: 44)   // 極薄ストリップ。safe area(上)はこの外側で確保される。

            // カード本体(全面・内部スクロール)。
            Group {
                if let webView = host.webView {
                    // role:.fullscreen + host.displayMode を渡す。fullscreen 中は host.displayMode==.fullscreen
                    // なので、この AppCardView が webView を adopt する(inline 側は displayMode ガードで奪わない)。
                    // onAdopted: 監査 2026-07-18 HIGH #1 — 実際に fullscreen コンテナへ再アダプトされた
                    // 直後に、保留中の host-context-changed(fullscreen 昇格)があればここで初めて送る
                    // (InlineCardHost.notifyReparented コメント参照)。これが「WebView の reparent より
                    // 寸法通知が先に届く」順序バグの直接の修正点。
                    AppCardView(
                        webView: webView, role: .fullscreen, activeDisplayMode: host.displayMode,
                        onAdopted: { host.notifyReparented() }
                    )
                } else {
                    // 通常来ない(昇格は webView 構築後にしか起きない)が、防御的にプレースホルダ。
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 下端の safe area までカードを広げる(ストリップは上端 safe area の内側)。
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            // fullscreen はカード内部スクロール(§5 H4-E・§6-2)。生成時 false だったのをここで true に。
            host.setWebViewScrollEnabled(true)
            // 実寸ズレの補正(§5 H4-E)は任意。fullscreen はカード内部スクロールで高さ誤差の実害が小さく、
            // 幅は推定(画面幅=全幅)と一致するので、初期の推定寸法のままで足りると判断し送らない
            // (必要になれば host.setWebViewScrollEnabled と同型の補正通知をここに足す)。
        }
    }
}
