import SwiftUI
import UIKit
import Kernel

// ツールステップ1行(モックの .tool-step)。タップで開閉し、開くと argumentsJSON(リクエスト)/
// resultJSON(レスポンス)を整形表示する。@State isExpanded を行ごとに持つため、ChatBodyView 本体
// (struct View で開閉状態を持てない)から切り出した独立行 View。
// internal(private でない)にしているのは、読み取り専用の履歴ビュー(HistoryDetailView)が
// 同じツール req/res 展開行を再利用するため(タスク指示 C-view「ToolStepRow 再利用」)。
//
// UX 改善 #2+#4(fable ベスプラ調査・ChatGPT Apps 公式ガイドライン/claude.ai 準拠・ユーザー参照画像):
// 従来は「先頭 chevron で行全体トグル」だったが、ChatGPT/claude.ai は tool-calling 行を
// 「attribution(サーバー・ツールの出自を示す控えめなクローム)+ 右端 `</>` で req/res を開く」
// という形にしている。先頭 chevron は廃止し、開閉の合図を右端の `</>` アイコン一本に統一した
// (合図が2箇所にあると視線が迷う・ユーザー要望「</> を押すと開く」に直結)。
struct ToolStepRow: View {
    let step: ToolCallStep
    /// attribution に出すサーバー短縮名(例 "caldav")。呼び出し側(ChatBodyView/HistoryDetailView)が
    /// それぞれの接続先(ライブ chatVM / 履歴 ChatSession)から導出して渡す(このビュー自身は
    /// 接続情報を持たない=汎用ホストとしての中立性を保つ・CLAUDE.md ビジョン2)。
    let serverName: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if isExpanded {
                detail
                    .padding(.leading, 20)
                    .padding(.top, 2)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            // 状態アイコン: running=スピナー / done=チェック / failed=× / pending=時計。
            // attribution の直前に置き、開閉トリガ(右端 `</>`)とは独立して常に見える位置にする。
            switch step.state {
            case .running:
                ProgressView().scaleEffect(0.7).frame(width: 14, height: 14)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .pending:
                Image(systemName: "clock").foregroundStyle(.secondary)
            }

            // attribution: モノグラムバッジ + サーバー短縮名 + "·" + ツール名(claude.ai/ChatGPT の
            // tool-calling 行の見た目に合わせる・ユーザー参照画像)。トーンは secondary 寄りで控えめ。
            attribution

            Spacer(minLength: 4)

            // 右端 `</>`: リク/レス JSON パネルの開閉トリガ(このビュー唯一の開閉合図)。
            codeToggleButton
        }
        .padding(.leading, 2)
        // 行全体タップでも開閉できるようにする(ChatGPT の作法・タスク指示「両方可なら両方」)。
        // contentShape で余白部分もタップ対象にし、Spacer 上のタップも拾う。
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
    }

    /// モノグラムバッジ(角丸四角 + serverName 先頭1字)+ サーバー短縮名 + "·" + ツール名。
    private var attribution: some View {
        HStack(spacing: 5) {
            // モノグラムバッジは装飾(サーバー短縮名テキストと情報が重複する)なので読み上げ対象外にする。
            Text(monogram)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary))
                .accessibilityHidden(true)
            Text(serverName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("·")
                .font(.caption)
                .foregroundStyle(.secondary)
            // ツール名(モックは code タグで強調していた等幅 + 薄い accent 背景をそのまま踏襲)。
            Text(step.toolName)
                .font(.caption.monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.14)))
                .foregroundStyle(Color.accentColor)
        }
    }

    /// serverName の先頭1字(例 "caldav" → "c")。空文字なら "?" にフォールバック(壊れた
    /// 入力でもバッジが空白にならないように)。
    private var monogram: String {
        guard let first = serverName.first else { return "?" }
        return String(first).uppercased()
    }

    /// 右端の `</>` 開閉トリガ。展開時は accentColor で塗って「開いている」ことを示し、
    /// 折りたたみ時は secondary の控えめな色にする(タスク指示の色/塗りでの状態表現)。
    private var codeToggleButton: some View {
        Button { toggle() } label: {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.caption)
                .foregroundStyle(isExpanded ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        // 行全体タップの onTapGesture と重複してトグルしないよう、ボタン自身のタップは
        // simultaneousGesture ではなく通常の Button アクションのまま(SwiftUI がボタン領域の
        // タップを優先して親の onTapGesture に伝播させないため、二重トグルは起きない)。
        .accessibilityLabel("リクエスト/レスポンスを表示")
        .accessibilityValue(isExpanded ? "展開中" : "折りたたみ")
        .accessibilityAddTraits(.isButton)
    }

    private func toggle() {
        withAnimation(.easeOut(duration: 0.12)) { isExpanded.toggle() }
    }

    /// 展開時の中身。argumentsJSON(リクエスト)/ resultJSON(レスポンス)が nil のセクションは
    /// 出さない(pending/running 中は resultJSON がまだ確定していないので「レスポンス」は出ない)。
    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let args = step.argumentsJSON {
                JSONCodeBlock(title: "リクエスト", raw: args)
            }
            if let result = step.resultJSON {
                JSONCodeBlock(title: "レスポンス", raw: result)
            }
        }
    }
}

/// リク/レスの JSON を等幅表示するコードブロック(1つ = リクエスト or レスポンス)。右上に
/// コピーボタンを持つ(ユーザー要望・2026-07-17)。コピー押下で一時的に ✓ に切り替えて
/// フィードバックする(押したことが分かるように・@State copied を各ブロックが個別に持つため
/// ToolStepRow から独立した小ビューに切り出した)。
private struct JSONCodeBlock: View {
    let title: String
    let raw: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(prettyJSON(raw))
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)  // 全文コピー可能に(調査・デバッグ用途)。
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxHeight: 240)  // 長い結果に備えて内部スクロール(全体レイアウトを圧迫させない)。
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(.secondarySystemBackground)))
            // コピーボタンはグレーブロックの**内部右上**にオーバーレイする(ユーザー要望 2026-07-17:
            // タイトル行でなくコード塊の右上が自然)。iOS は hover が無いので常時表示だが、
            // 半透明 material の小さな丸背景で JSON テキストの上でも視認でき、かつ主張しすぎない。
            .overlay(alignment: .topTrailing) { copyButton }
        }
    }

    /// prettyJSON(整形後)をペーストボードへコピーする小ボタン。押下で 1.2s だけ ✓ に切替。
    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = prettyJSON(raw)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption2)
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .padding(5)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .padding(4)  // ブロック角から少し離す。
        .accessibilityLabel("\(title)をコピー")
    }
}

/// サーバー URL の host 先頭ラベル(例: caldav.gigun-dev.workers.dev → "caldav")を attribution 用に
/// 導出する共有ヘルパ(タスク指示: 導出ロジックは1箇所にまとめて ChatBodyView/HistoryDetailView の
/// 両方から使う)。ロジック自体は ChatHomeView.serverShortName / ChatHistorySidebar.serverShortName と
/// 同一だが、それらは画面固有の入力(serverURLString / ChatHistorySummary)から呼ばれる別関数のため
/// 統合はしていない(過剰共通化を避ける・ここは ToolStepRow 系のみの共有先)。
func serverShortName(from url: URL) -> String {
    guard let host = url.host else { return "MCP" }
    return host.split(separator: ".").first.map(String.init) ?? host
}

/// JSON 文字列 → pretty print(等幅表示用)。tool_call の引数・結果はどちらも compact JSON
/// 文字列(または失敗時はエラー文言)なので、整形できるものだけ整形し、できない生文字列
/// (エラー文言等)はそのまま返す(タスク指示のヘルパをそのまま踏襲)。
private func prettyJSON(_ raw: String) -> String {
    guard let data = raw.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let pretty = try? JSONSerialization.data(
              withJSONObject: obj,
              options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
          ),
          let prettyString = String(data: pretty, encoding: .utf8)
    else { return raw }
    return prettyString
}

// MARK: - zoom トランジション(P4-DM 遷移アニメ・設計 04 §5 決定2 2026-07-17 改訂)
//
// iOS 18 の zoom transition(matchedTransitionSource + navigationTransition(.zoom))を薄くラップする。
// source(inline カード)と destination(fullScreenCover 中身)を同じ (id, namespace) で結ぶと、
// カード枠 rect ↔ 全画面 rect の「その場から拡大/縮小」遷移が公式に得られる(⤢=拡大メタファに一致)。
// iOS 17 は fullScreenCover の遷移差し替えが公開 API 上不可なので #available で no-op に落とし、
// 既定のカバー(下からせり上がり)にフォールバックする(遷移だけの差で機能は同一・§4 可逆)。
// 自前 overlay スナップショットズーム(旧案)は Web プロセス再レイアウト飛行のコスト・自前提示機構の
// 高依存でボツ=財産(設計 04 §5 の 2026-07-17 追更新ブロック参照)。id は host.id(ObjectIdentifier)。
extension View {
    /// 拡大の起点(inline カード枠)に付ける source アンカー。
    @ViewBuilder
    func zoomSource(id: ObjectIdentifier, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self  // iOS 17: 差し替え不可 → 既定カバー遷移のまま。
        }
    }

    /// 拡大の着地先(fullScreenCover 中身)に付ける destination アンカー。source と同 id/namespace で対応。
    @ViewBuilder
    func zoomTransition(id: ObjectIdentifier, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}
