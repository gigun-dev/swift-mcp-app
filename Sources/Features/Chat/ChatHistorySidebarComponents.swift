// ChatHistorySidebar の純表示部品。ユーザー操作と @State は親へ残し、行ラベルと palette だけを
// 分離することで、長押しメニュー追加後も Sidebar 本体を lint の責務サイズ内に保つ。
import Kernel
import SwiftUI

/// 履歴行のラベル。Button/contextMenu/accessibility action は親が所有し、この View は表示だけを担う。
struct ChatHistoryRowLabel: View {
    let summary: ChatSessionSummary
    /// 履歴が複数サーバーにまたがる場合だけ親が短縮名を渡す。nil なら chip 自体を描かない。
    let serverName: String?

    /// 相対時刻フォーマッタは生成コストが高いため全行で共有する。named は「昨日」「たった今」等の
    /// 自然な表現を返し、sidebar-v2 モックの「6分前」「昨日」に対応する。
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter
    }()

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title.isEmpty ? "新規チャット" : summary.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                // preview は一覧表示しないが、親のローカル検索対象には引き続き含まれる。
                HStack(spacing: 7) {
                    Text(Self.relativeFormatter.localizedString(for: summary.updatedAt, relativeTo: Date()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let serverName {
                        Text(serverName)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(SidebarPalette.paperSubtle))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 8)
            // pin.fill は一覧順が変わった理由を視覚的に示す。VoiceOver には親の value/action で伝える。
            if summary.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// 履歴一覧の1行。ChatHistoryRowLabel(純表示)に active 背景・hit geometry・
/// contextMenu・accessibility action を巻き付けた「操作を伴う行」。
///
/// 【なぜ親 struct から抽出したか】ChatHistorySidebar 本体が SwiftLint の
/// type_body_length 上限(250行)を超えたため、行1つ分の責務(約60行)を独立 struct へ切り出す。
/// disable コメントや閾値変更ではなく責務抽出で解消する(2026-07-23)。
/// 操作は「何をするか」だけをクロージャで親から注入し(onSelectTap ほか)、store 直読みや
/// @State(削除確認・リネーム prompt)は引き続き親が所有する。この行は状態を持たない純関数的 View。
struct ChatHistoryRow: View {
    let summary: ChatSessionSummary
    /// この行が現在表示中セッションか(active ピル塗り・区切り線抑制の判定)。親が activeSessionID と比較して渡す。
    let isActive: Bool
    /// 複数サーバーにまたがる履歴のときだけ親が短縮名を渡す。nil なら chip を描かない(ChatHistoryRowLabel へ素通し)。
    let serverName: String?
    /// 明示 tap での選択(親が onSelect + onClose を束ねる)。
    let onSelectTap: () -> Void
    /// ピン留めのトグル。
    let onTogglePin: () -> Void
    /// 名前変更(親が prompt を出す)。
    let onRename: () -> Void
    /// 削除要求(親が confirmation を挟む)。
    let onRequestDelete: () -> Void

    var body: some View {
        // active 背景と context-menu preview の正典を同じ Shape 値にする。外側 8x3 / 内側
        // 8x11 の二段 padding は、従来の content inset 16x14 と active 背景 inset 8x3 を保つ。
        let rowShape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return ChatHistoryRowLabel(
            summary: summary,
            serverName: serverName
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 11)
        .background {
            if isActive { rowShape.fill(SidebarPalette.pillActive) }
        }
        // interaction と preview の hit/highlight geometry を active の灰色背景と完全に揃える。
        .contentShape(.interaction, rowShape)
        .contentShape(.contextMenuPreview, rowShape)
        // List 内の Button は大きな横 swipe の終了を activate と解釈する場合があり、削除 swipe を
        // 廃止しても onSelect + onClose が発火した。通常 View + TapGesture なら移動量の大きい gesture は
        // tap として成立しないため、「明示 tap のみ選択」という drawer 競合排除の契約になる。
        .onTapGesture { onSelectTap() }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .listRowInsets(EdgeInsets())
        .listRowBackground(SidebarPalette.paper)
        // アクティブ行はピルとヘアラインが衝突するため区切り線を消す(モックの .hrow.active::before)。
        .listRowSeparator(isActive ? .hidden : .visible)
        .listRowSeparatorTint(SidebarPalette.hairline)
        // 左スワイプは drawer の開閉と競合するため使わない。破壊操作を含む管理メニューは
        // iOS 標準の長押し context menu へ集約し、誤操作時の削除はさらに確認を挟む。
        .contextMenu {
            Button {
                onTogglePin()
            } label: {
                Label(
                    summary.isPinned ? "ピン留めを解除" : "ピン留め",
                    systemImage: summary.isPinned ? "pin.slash" : "pin"
                )
            }
            Button {
                onRename()
            } label: {
                Label("名前を変更", systemImage: "pencil")
            }
            Button(role: .destructive) {
                onRequestDelete()
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(summary.isPinned ? "ピン留め済み" : "")
        // 見た目を Button から View へ変えても VoiceOver の標準 activate 操作は同じ選択動作を保つ。
        .accessibilityAction { onSelectTap() }
        // VoiceOver では長押しを要求せず、同じ操作を rotor actions として直接公開する。
        .accessibilityAction(named: Text(summary.isPinned ? "ピン留めを解除" : "ピン留め")) {
            onTogglePin()
        }
        .accessibilityAction(named: Text("名前を変更")) { onRename() }
        .accessibilityAction(named: Text("削除")) { onRequestDelete() }
    }
}

/// サイドバー専用パレット(sidebar-v2.html の CSS 変数を移植)。
///
/// 【Assets カタログ不使用の判断】このプロジェクトに .xcassets は無い。Assets を新設せず Swift の
/// `Color(uiColor:)` + dynamic provider で light/dark を表す。値は同モックの Hex が正典。
enum SidebarPalette {
    /// 温かい paper 背景(light: #faf9f5 / dark: #211f1c)。
    static let paper = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x21 / 255, green: 0x1f / 255, blue: 0x1c / 255, alpha: 1)
            : UIColor(red: 0xfa / 255, green: 0xf9 / 255, blue: 0xf5 / 255, alpha: 1)
    })

    /// 検索ボックス・chip の下地(light: #f1efe9 / dark: #2c2a26)。
    static let paperSubtle = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x2c / 255, green: 0x2a / 255, blue: 0x26 / 255, alpha: 1)
            : UIColor(red: 0xf1 / 255, green: 0xef / 255, blue: 0xe9 / 255, alpha: 1)
    })

    /// ヘアライン区切り線(light: #e8e6de / dark: #33312c)。
    static let hairline = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x33 / 255, green: 0x31 / 255, blue: 0x2c / 255, alpha: 1)
            : UIColor(red: 0xe8 / 255, green: 0xe6 / 255, blue: 0xde / 255, alpha: 1)
    })

    /// アクティブ行の柔らかいピル塗り(light: #e9e6dd / dark: #33312b)。
    static let pillActive = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x33 / 255, green: 0x31 / 255, blue: 0x2b / 255, alpha: 1)
            : UIColor(red: 0xe9 / 255, green: 0xe6 / 255, blue: 0xdd / 255, alpha: 1)
    })

    /// フローティングピルの背景(light: 黒 #26241f / dark: 白 #f0eee8。ダークで反転)。
    static let fabBackground = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0xf0 / 255, green: 0xee / 255, blue: 0xe8 / 255, alpha: 1)
            : UIColor(red: 0x26 / 255, green: 0x24 / 255, blue: 0x1f / 255, alpha: 1)
    })

    /// フローティングピルの文字色(fabBackground と対の反転)。
    static let fabForeground = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x21 / 255, green: 0x1f / 255, blue: 0x1c / 255, alpha: 1)
            : UIColor(red: 0xfa / 255, green: 0xf9 / 255, blue: 0xf5 / 255, alpha: 1)
    })
}
