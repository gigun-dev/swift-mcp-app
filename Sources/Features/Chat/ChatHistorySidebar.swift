// チャット履歴サイドバー(T6 後半→sidebar-v2 リデザイン)。
//
// モック対応(docs/modeling/ui-mockups/sidebar-v2.html・末尾「SwiftUI 実装メモ」9項目):
//  - .side-head(ワードマーク + .search-field)→ header(検索は上部に据え置き。
//    理由はモック注記どおり「drawer 内ではフローティングピルと競合するため」)。
//  - .recent-label(「最近の項目」)→ 先頭の小見出し行。
//  - .side-list / .hrow(edge-to-edge・ヘアライン・太字タイトル+相対時刻2行)→ List(.plain) の各行。
//  - .hrow.active(柔らかい角丸ピル塗り)→ listRowBackground の角丸矩形(accent 不使用)。
//  - .srv-chip(複数サーバー接続時のみ)→ 一覧単位で判定した chip。
//  - .fab(下部フローティング黒/白ピル「＋ 新規チャット」)→ List に .overlay(alignment:.bottom)。
//  - .empty(空状態)→ 既存の空状態分岐を刷新後の文言に合わせて維持。
//
// 【前版(日付グループ+insetGrouped+preview表示+左3pxアクセントバー)からの変更点】
// Claude iOS 実機の所見(モック冒頭コメント参照)を受けて全面刷新。骨格
// (表示専用・store 直読み・onSelect/onNewChat/onClose コールバック契約・検索フィルタの
// 対象が title/preview であること)は不変。見た目のみの差し替え(完全に可逆)。
import SwiftUI
import Kernel   // ChatSessionSummary
import Services // ChatStore
import os.log

struct ChatHistorySidebar: View {
    /// 一覧の読み込み(loadIndex)・削除(delete)に使う。表示専用サイドバーが直接触る(冒頭参照)。
    let store: ChatStore

    /// 現在ライブ表示 or 閲覧中のセッション ID(.active ハイライト用)。無ければ(未接続等)nil。
    var activeSessionID: UUID?

    /// 行タップ = 「この id を開く」を親へ通知(親が store.load → .viewingHistory へ)。
    let onSelect: (UUID) -> Void
    /// 新規チャット。
    let onNewChat: () -> Void
    /// サイドバーを閉じる(選択・新規の後に親が閉じる導線と、明示クローズの両方で使う)。
    let onClose: () -> Void

    // 一覧の実体。onAppear と削除後に store.loadIndex() で読み直す。View ローカルの @State でよい
    // (サイドバーが開いている間だけ必要な、揮発的な表示状態)。
    @State private var summaries: [ChatSessionSummary] = []
    // 検索クエリ(title/preview の部分一致・ローカルフィルタ・設計 §5「一覧の title/preview の部分一致で足りる」)。
    // preview は表示から外した(実装メモ3)が、検索対象には引き続き残す(実装メモ3・ボツ案メモ(d))。
    @State private var query: String = ""

    private static let logger = Logger(subsystem: "dev.gigun.mcphost", category: "sidebar")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            listOrEmpty
        }
        .background(SidebarPalette.paper)
        // 初回表示で一覧を読む。サイドバーは開くたびに再マウントされる想定(drawer の
        // offset 表示ではなく条件付き生成にしているため)なので、開くたびに最新の index を読む。
        .task { reload() }
    }

    // MARK: - ヘッダ(ワードマーク + 検索。モックの .side-head)

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("swift-mcp-app")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            // 検索フィールド(モックの .search-field)。角丸の薄い箱 + 虫眼鏡。
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("検索", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12).fill(SidebarPalette.paperSubtle))
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    // MARK: - 一覧 / 空状態

    @ViewBuilder
    private var listOrEmpty: some View {
        let filtered = filteredSummaries
        if filtered.isEmpty {
            // 空状態(モックの .empty)。検索で0件か、そもそも履歴が無いかで文言を分ける
            // (「検索に一致しない」と「まだ何も無い」は原因が違うので握りつぶさず区別する)。
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: query.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                    .font(.system(size: 24))
                    .frame(width: 56, height: 56)
                    .background(RoundedRectangle(cornerRadius: 18).fill(SidebarPalette.paperSubtle))
                    .foregroundStyle(.secondary)
                Text(query.isEmpty ? "まだ履歴がありません" : "一致する履歴がありません")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                if query.isEmpty {
                    Text("下のボタンから会話を始めましょう")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 80)
        } else {
            // 実装メモ1: 日付グループ(groupedSummaries)は廃止し単一 ForEach(平坦リスト)。
            // loadIndex() が updatedAt 降順を保証するので並べ替えは不要(store 契約)。
            List {
                // 実装メモ2: 「最近の項目」のみ小見出しとして残す(日付グループ見出しは廃止)。
                Text("最近の項目")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                    .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(SidebarPalette.paper)

                ForEach(filtered, id: \.id) { summary in
                    historyRow(summary)
                }

                // 実装メモ7: 下部フローティングピルの逃げ余白(リスト末尾がピルの下に隠れないため)。
                Color.clear
                    .frame(height: 96)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(SidebarPalette.paper)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(SidebarPalette.paper)
            // 実装メモ7: 下部フローティング黒/白ピル「＋ 新規チャット」。safeAreaInset だと
            // リストが手前で止まり「後ろを流れる」抜け感が出ないため overlay で重ねる(モック注記どおり)。
            .overlay(alignment: .bottom) { newChatFAB }
        }
    }

    private func historyRow(_ summary: ChatSessionSummary) -> some View {
        let isActive = summary.id == activeSessionID
        return Button {
            onSelect(summary.id)
            onClose()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.title.isEmpty ? "新規チャット" : summary.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    // 実装メモ4: preview は表示しない(検索対象としては filteredSummaries で残す)。
                    HStack(spacing: 7) {
                        Text(relativeTime(summary.updatedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // 実装メモ5: 複数サーバー接続歴があるときだけ chip を出す(一覧単位で判定)。
                        if showsServerChip {
                            Text(serverShortName(summary.serverURL))
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
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())  // 余白部分のタップも拾う。
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        // 実装メモ6: アクティブ行は柔らかい角丸ピル塗り(accent は使わない・手本準拠)。
        // 背景 View は行サイズへ引き伸ばされるので padding で内側に寄せてピル状にする。
        .listRowBackground(historyRowBackground(isActive: isActive))
        // アクティブ行はピルとヘアラインが衝突するため区切り線を消す(モックの .hrow.active::before)。
        .listRowSeparator(isActive ? .hidden : .visible)
        .listRowSeparatorTint(SidebarPalette.hairline)
        // スワイプ削除(既存踏襲)。削除後は一覧を読み直す。
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                delete(summary.id)
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
    }

    /// List の型消去を行描画から隔離し、アクティブ時だけ柔らかいピル背景へ切り替える。
    private func historyRowBackground(isActive: Bool) -> AnyView {
        guard isActive else { return AnyView(SidebarPalette.paper) }
        return AnyView(
            RoundedRectangle(cornerRadius: 14)
                .fill(SidebarPalette.pillActive)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
        )
    }

    /// 下部フローティングの新規チャットピル(モックの .fab .pill)。
    /// ダークでは黒/白が反転する(SidebarPalette.fabBackground/fabForeground 参照)。
    private var newChatFAB: some View {
        Button {
            onNewChat()
            onClose()
        } label: {
            Label("新規チャット", systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 22)
                .padding(.vertical, 13)
                .background(Capsule().fill(SidebarPalette.fabBackground))
                .foregroundStyle(SidebarPalette.fabForeground)
                .shadow(color: .black.opacity(0.22), radius: 10, y: 6)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 20)
    }

    // MARK: - データ読み書き

    private func reload() {
        summaries = store.loadIndex()  // updatedAt 降順(ChatStore.loadIndex の契約)。
    }

    private func delete(_ id: UUID) {
        // ChatStore.delete は冪等(ファイルが無くても index から消す)。失敗しても一覧再読込は行う
        // (削除に失敗したら次の reload で「消えていない」ことが見えるので、握りつぶしても
        // ユーザーには状態が正しく反映される)。
        do {
            try store.delete(id: id)
        } catch {
            // 前版の print から Logger へ変更(軽微な指摘への追随。Features 層に専用 Logger を新設)。
            Self.logger.error("履歴の削除に失敗: \(String(reflecting: error), privacy: .public)")
        }
        reload()
    }

    // MARK: - フィルタ / サーバー判定

    /// title / preview の部分一致(大文字小文字無視)でローカルフィルタ。空クエリなら全件。
    /// preview は行表示からは消えたが検索対象としては残す(実装メモ3・ボツ案メモ(d))。
    private var filteredSummaries: [ChatSessionSummary] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return summaries }
        return summaries.filter {
            $0.title.localizedCaseInsensitiveContains(normalizedQuery)
                || $0.preview.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    /// 複数サーバーに接続歴があるときだけ真(実装メモ5)。一覧全体で判定し、真なら全行に chip を出す
    /// (行ごとの出し分けだと一部だけ chip 無しが欠落に見えるため)。
    private var showsServerChip: Bool {
        Set(summaries.map { serverShortName($0.serverURL) }).count > 1
    }

    // MARK: - 表示ヘルパ

    /// 相対時刻フォーマッタ(実装メモ4)。生成コストが高いため static let でキャッシュ。
    /// dateTimeStyle = .named で「昨日」「たった今」等の自然な表現が出る(手本の「6分前」「昨日」)。
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter
    }()

    private func relativeTime(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// サーバー URL の host 先頭ラベル(caldav.gigun-dev.workers.dev → "caldav")。ChatHomeView と同ロジック。
    private func serverShortName(_ url: URL) -> String {
        guard let host = url.host else { return "MCP" }
        return host.split(separator: ".").first.map(String.init) ?? host
    }
}

/// サイドバー専用パレット(sidebar-v2.html の CSS 変数を移植)。
///
/// 【Assets カタログ不使用の判断(タスク前提)】このプロジェクトに .xcassets は無い。
/// モックの実装メモは Assets の light/dark カラーペア(Paper/PaperSubtle/PillActive/
/// FabBG/FabFG)を前提にしているが、Assets を新設せず Swift の `Color(uiColor:)` +
/// `UIColor { traitCollection in ... }` の動的プロバイダで代替する(コード内完結・
/// カタログ管理の手間が無い)。値は sidebar-v2.html の `:root` / `.theme-light` /
/// `.theme-dark` の Hex をそのまま写経(出典: 同ファイル 43-66 行)。
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
