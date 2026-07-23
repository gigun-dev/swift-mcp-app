// 読み取り専用の履歴詳細ビュー(T6 後半・タスク指示 C-3・設計 §5)。
//
// 過去セッション(ChatSession・純データ)の会話本文は **read-only** のまま描画する。composer や LLM
// 再開口は持たない。一方、MCP App カードは生成元と現在の ready 接続を安全に同定できた場合だけ
// live island として bridge を再構築する。元 tool は再実行せず、保存済み tool-input / tool-result を
// 配送して初期表示し、それ以後のカード内 tools/call だけを現在の同一 MCP へ流す。
//
// ChatBodyView との関係: 吹き出し・ツールステップの見た目は ChatBodyView に寄せる。ただし
// ChatBodyView は ChatViewModel(ライブ)前提で composer やカード構築(InlineCardView)を持つため
// 流用せず、read-only の描画だけを持つ別 View にする(過剰共通化はしない・タスク指示)。ツール
// req/res 展開行だけは共通の ToolStepRow(ChatBodyView.swift・internal)を再利用する。
import SwiftUI
import UIKit
import Kernel   // ChatSession・ChatTurn・ToolCallStep・CardEmbed・ChatMessage.Role・JSONValue
import Services // AppsServerProxy

struct HistoryDetailView: View {
    let session: ChatSession
    /// 履歴カードを live 再接続用の connection + 失敗理由で解決する(queue 11)。理由は card.resolve 観測へ載せる。
    let cardResolver: (CardEmbed) -> HistoricalCardResolution
    /// クライアント観測ポート(合成ルートで OSLogTelemetry / テスト・プレビューは NullTelemetry)。
    let telemetry: TelemetryPort
    /// per-launch のセッション相関 ID(ChatHomeViewModel が採番・card.resolve の session フィールドに stamp)。
    let sessionTraceID: String

    // 静的カードのセッション台帳(StaticCardView.swift)。@State で1個所有し、スクロール再生成でも
    // 同じ host を引いて WKWebView を作り直さない(StaticCardRegistry のコメント参照)。
    // provenance解決不能時だけ使い、proxy無しでsnapshotHTMLを静的ロードする。
    @State private var cardRegistry = StaticCardRegistry()
    /// live 復元できたカードだけを保持する台帳。履歴画面を閉じるまで card の操作状態を維持する。
    @State private var liveCardRegistry = InlineCardRegistry()
    @State private var fullscreenCoordinator = FullscreenCoordinator()
    @State private var haptics = ChatHapticsController()
    @State private var columnWidth: CGFloat = 0
    @State private var visibleHeight: CGFloat = 0
    @Namespace private var cardZoom

    private var inlineMaxHeight: CGFloat {
        (visibleHeight * 0.65).rounded(.down)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(session.turns.enumerated()), id: \.offset) { index, turn in
                    turnView(turn, turnIndex: index)
                }
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ColumnWidthKey.self, value: geo.size.width)
                }
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: VisibleHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(ColumnWidthKey.self) { columnWidth = $0 }
        .onPreferenceChange(VisibleHeightKey.self) { visibleHeight = $0 }
        .navigationTitle(session.title.isEmpty ? "履歴" : session.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { haptics.prepareAll() }
        .fullScreenCover(item: activeHostBinding) { host in
            FullscreenCardView(host: host)
                .zoomTransition(id: host.id, in: cardZoom)
        }
        // 履歴カード内の編集フォームも通常カードと同じ keyboard avoidance を使う。fullscreen は
        // WKWebView 自身の内部スクロールへ任せ、zoom 中に元カードの座標を動かさない。
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            guard fullscreenCoordinator.activeHost == nil else { return }
            InlineCardKeyboardAvoider.handleKeyboardWillShow(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { note in
            guard fullscreenCoordinator.activeHost == nil else { return }
            InlineCardKeyboardAvoider.handleKeyboardWillShow(note)
        }
        .onDisappear {
            liveCardRegistry.teardownAll()
            fullscreenCoordinator.activeHost = nil
        }
    }

    private var activeHostBinding: Binding<InlineCardHost?> {
        Binding(
            get: { fullscreenCoordinator.activeHost },
            set: { if $0 == nil { fullscreenCoordinator.dismiss() } }
        )
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
                    toolStepRow(step)
                }
                if !turn.text.isEmpty {
                    HStack {
                        bubble(turn.text, isUser: false)
                        Spacer(minLength: 40)
                    }
                }
                // 会話本文は固定だが、安全に由来を解決できるカードだけ live に戻す。
                ForEach(Array(turn.cards.enumerated()), id: \.offset) { cardIndex, card in
                    cardView(card, key: "\(turnIndex)-\(cardIndex)")
                }
            }
        case .system, .tool:
            // wire 専用ロール。ターン表示には現れない(ChatBodyView と同じく何も出さない)。
            EmptyView()
        }
    }

    /// 保存済みの実行時表示名を優先し、旧履歴だけ名前空間 slug / 代表 URL へ順に戻す。
    private func toolStepRow(_ step: ToolCallStep) -> some View {
        let parsed = ToolNamespacing.parse(prefixed: step.toolName)
        var display = step
        display.toolName = step.originalToolName ?? parsed?.tool ?? step.toolName
        let serverName = step.serverName ?? parsed?.slug ?? serverShortName(from: session.serverURL)
        return ToolStepRow(step: display, serverName: serverName)
    }

    // MARK: - カード(live island / fail-closed の静的表示)

    @ViewBuilder
    private func cardView(_ card: CardEmbed, key: String) -> some View {
        let resolution = cardResolver(card)
        // outcome は「解決の結果」を表す(columnWidth 等のレイアウトゲートは含めない)。connection があれば
        // resolvedLive、無ければ snapshot 有無で snapshotFallback / placeholder。レイアウト待ちで一瞬 0 になる
        // columnWidth を outcome に混ぜると、実際は live 解決できるカードを snapshot と誤記録してしまうため
        // (onAppear が transient を拾う)、あえて分離する。
        let hasSnapshot = !(card.snapshotHTML?.isEmpty ?? true)
        let outcome: CardResolutionOutcome = resolution.connection != nil
            ? .resolvedLive
            : (hasSnapshot ? .snapshotFallback : .placeholder)
        cardBody(card, key: key, connection: resolution.connection)
            // 1カード(view identity = key)につき1回だけ観測を吐く。body 再評価では発火しない onAppear を使う
            // (@ViewBuilder body 直書きだと再描画のたびに多重発火してログを汚す)。
            .onAppear {
                telemetry.event(
                    CardResolutionTelemetry.eventName,
                    fields: CardResolutionTelemetry.resolveFields(
                        outcome: outcome,
                        reason: resolution.reason,
                        card: card,
                        session: sessionTraceID
                    ),
                    // notice: card.resolve は「常に残したい運用イベント」。debug/info は既定で永続化されず
                    // 実機吸い出しで取りこぼす(OSLog の仕様)。
                    level: .notice
                )
            }
    }

    /// カード本体の3分岐描画(観測とは分離)。connection があれば live island、無ければ snapshot 静的表示、
    /// それも無ければプレースホルダ。columnWidth/visibleHeight のレイアウトゲートはここで効かせる。
    @ViewBuilder
    private func cardBody(_ card: CardEmbed, key: String, connection: HistoricalCardConnection?) -> some View {
        if let connection, columnWidth > 0, visibleHeight > 0 {
            let host = liveCardRegistry.host(
                for: "\(key)-\(connection.registryIdentity)",
                coordinator: fullscreenCoordinator
            )
            // swiftlint:disable:next redundant_discardable_let
            let _ = { host.onCardToolCall = { haptics.cardAction() } }()
            InlineCardView(
                host: host,
                proxy: connection.proxy,
                card: connection.card,
                containerWidth: columnWidth,
                maxHeight: inlineMaxHeight,
                // 履歴レコードは不変。復元後の DOM を snapshotHTML へ上書きせず、再訪時は常に
                // 保存時の tool-input/result を起点にする。
                onSnapshot: nil,
                // 履歴経路であることを明示。既に build 済みの host を再表示したとき、保存済み toolResult を
                // 1回だけ再 push して caldav 側 SWR に revalidate 機会を与える(2026-07-24・鮮度ギャップ修正)。
                isHistoryRevisit: true
            )
            // 【2026-07-23・queue 2】以前はここに revalidation 待ち/失敗オーバーレイ(操作ゲート)を
            // 重ねていたが撤去した。gate/hint は caldav 側裁定で撤去(caldavリポジトリ docs/modeling/15・SWR)。
            // 履歴カードは即操作可能にし、鮮度は caldav 側 SWR(generatedAt 60 秒判定)が担う。その
            // 発火条件である「保存済み toolResult の再 push」は InlineCardHost.sendInitialPayload が担保する。
            .zoomSource(id: host.id, in: cardZoom)
            .reportsMCPAppGestureFrame()
        } else if let html = card.snapshotHTML, !html.isEmpty {
            // 接続先を断定できないカードは JS 無効・bridge 無しの保存 snapshot へ fail closed。
            StaticCardView(host: cardRegistry.host(for: key), html: html)
                .reportsMCPAppGestureFrame()
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
