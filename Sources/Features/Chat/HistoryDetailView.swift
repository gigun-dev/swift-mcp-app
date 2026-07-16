// 読み取り専用の履歴詳細ビュー(T6 後半・タスク指示 C-3・設計 §5)。
//
// 過去セッション(ChatSession・純データ)を ChatBodyView 風に描画するが **read-only**:
// composer(入力欄)を持たず、ライブ接続(ChatViewModel / AppsServerProxy / LLM)にも一切触れない。
// カードはスナップショット HTML を StaticCardView で**静的表示**するだけ(設計 §5「過去セッションで
// 再実行しない=副作用ゼロ」)。ここが副作用ゼロの担保点。
//
// ChatBodyView との関係: 吹き出し・ツールステップの見た目は ChatBodyView に寄せる。ただし
// ChatBodyView は ChatViewModel(ライブ)前提で composer やカード構築(InlineCardView)を持つため
// 流用せず、read-only の描画だけを持つ別 View にする(過剰共通化はしない・タスク指示)。ツール
// req/res 展開行だけは共通の ToolStepRow(ChatBodyView.swift・internal)を再利用する。
import SwiftUI
import Kernel   // ChatSession・ChatTurn・ToolCallStep・CardEmbed・ChatMessage.Role・JSONValue

struct HistoryDetailView: View {
    let session: ChatSession

    // 静的カードのセッション台帳(StaticCardView.swift)。@State で1個所有し、スクロール再生成でも
    // 同じ host を引いて WKWebView を作り直さない(StaticCardRegistry のコメント参照)。
    // ライブと違い proxy は不要(snapshotHTML を静的ロードするだけ・設計 §5)。
    @State private var cardRegistry = StaticCardRegistry()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(session.turns.enumerated()), id: \.offset) { index, turn in
                    turnView(turn, turnIndex: index)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
        .navigationTitle(session.title.isEmpty ? "履歴" : session.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 1ターン(ChatBodyView.turnView の read-only 版)

    @ViewBuilder
    private func turnView(_ turn: ChatTurn, turnIndex: Int) -> some View {
        switch turn.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                bubble(turn.text, isUser: true)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                // ツールステップ(req/res 展開)。ライブと同じ ToolStepRow を再利用(タスク指示 C-3)。
                ForEach(Array(turn.toolSteps.enumerated()), id: \.offset) { _, step in
                    ToolStepRow(step: step, serverName: serverShortName(from: session.serverURL))
                }
                if !turn.text.isEmpty {
                    HStack {
                        bubble(turn.text, isUser: false)
                        Spacer(minLength: 40)
                    }
                }
                // カード: snapshotHTML があれば静的表示、無ければプレースホルダ。
                ForEach(Array(turn.cards.enumerated()), id: \.offset) { cardIndex, card in
                    cardView(card, key: "\(turnIndex)-\(cardIndex)")
                }
            }
        case .system, .tool:
            // wire 専用ロール。ターン表示には現れない(ChatBodyView と同じく何も出さない)。
            EmptyView()
        }
    }

    // MARK: - カード(スナップショット静的表示 / プレースホルダ)

    @ViewBuilder
    private func cardView(_ card: CardEmbed, key: String) -> some View {
        if let html = card.snapshotHTML, !html.isEmpty {
            // 設計 §5: スナップショット HTML を JS 無効・ブリッジ無しで静的ロード(副作用ゼロ)。
            StaticCardView(host: cardRegistry.host(for: key), html: html)
        } else {
            cardPlaceholder(card)
        }
    }

    /// スナップショット未保存カードのプレースホルダ(タスク指示 C-3)。
    /// ライブ中に size-changed へ到達する前にセッションが終わった等で snapshotHTML が無い場合に出る。
    /// toolName を示し、structuredContent があれば ToolStepRow 風に JSON を展開表示する
    /// (「そのとき何が返ったか」を履歴からでも追えるように・任意仕様)。
    private func cardPlaceholder(_ card: CardEmbed) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.dashed")
                    .foregroundStyle(.secondary)
                Text("このカードのスナップショットは未保存")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(card.toolName)
                .font(.caption.monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.14)))
                .foregroundStyle(Color.accentColor)
            // structuredContent があれば折りたたみで生 JSON を見せる(任意・調査用途)。
            if let json = prettyStructuredContent(card.structuredContent) {
                DisclosureGroup("structuredContent") {
                    ScrollView(.vertical) {
                        Text(json)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                    .frame(maxHeight: 200)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(.secondarySystemBackground)))
                }
                .font(.caption2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.85)))
    }

    // MARK: - ヘルパ

    /// 吹き出し(ChatBodyView.bubble の read-only 複製)。過剰共通化を避け小さく持つ(タスク指示)。
    private func bubble(_ text: String, isUser: Bool) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(isUser ? Color.white : Color.primary)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(isUser ? Color.accentColor : Color(.secondarySystemBackground))
            )
            .frame(maxWidth: 300, alignment: isUser ? .trailing : .leading)
            .textSelection(.enabled)
    }

    /// JSONValue(structuredContent)を pretty JSON 文字列にする。エンコード不能なら nil
    /// (プレースホルダ側は nil のとき展開行を出さない)。
    private func prettyStructuredContent(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
