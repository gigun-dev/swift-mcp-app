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
    /// ZStack 下層に常時 mount されるため、画面の appear ではなく実際の pane 開閉を親から受け取る。
    let isPresented: Bool

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
    // 長押しメニューから開く破壊操作/文字入力は、即時実行せず native confirmation/prompt を挟む。
    // 対象 ID と入力値を明示的に保持し、List の並べ替え後も別行へ作用しないようにする。
    @State private var deleteTargetID: UUID?
    @State private var showingDeleteConfirmation = false
    @State private var renameTargetID: UUID?
    @State private var renameTitle = ""
    @State private var showingRenamePrompt = false

    private static let logger = Logger(subsystem: "dev.gigun.mcphost", category: "sidebar")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            listOrEmpty
        }
        .background(SidebarPalette.paper)
        // mount 時に一度プライムする。ZStack 下層に常時 mount されるが、List の行 View は初回の
        // reveal まで build されず、ドラッグで開き始めた瞬間に空→中身の pop と行 layout が走って
        // 「最初のドラッグだけガクつく」原因になっていた。起動時に index を読んで行を用意しておけば、
        // 初回オープンのドラッグ中にはもう中身が居る(2026-07-23 初回ドラッグのガクつき修正の一環)。
        .task { reload() }
        // turn settlement 後に初めて pane を開いた場合も最新 index を見せるため、pane を開くたびに
        // 読み直す(.task の初回プライムに加え、false→true の transition で鮮度を保つ)。
        .onChange(of: isPresented) { _, presented in
            if presented { reload() }
        }
        .alert("名前を変更", isPresented: $showingRenamePrompt) {
            TextField("チャット名", text: $renameTitle)
            Button("キャンセル", role: .cancel) {}
            Button("保存") { commitRename() }
                // 空白だけの名前は ChatStore も拒否するが、UI でも実行前に理由が見える形にする。
                .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("履歴に表示する名前を入力してください。")
        }
        .confirmationDialog(
            "チャットを削除しますか？",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) { commitDelete() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この操作は取り消せません。")
        }
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
            // 実装メモ1: 日付グループ(groupedSummaries)は廃止。ただしピン留めだけは
            // 「最近の項目」と混ぜず独立セクションにする(loadIndex はピン留めを先頭へ
            // ソートするが、それを単一「最近の項目」見出しの下に置くと、見出しと中身が
            // 食い違って見える — ピン留めは "最近" ではなく "固定" だから別見出しにする)。
            // セクション内の並びは loadIndex の契約順(ピン内も通常内も updatedAt 降順)をそのまま使う。
            let pinned = filtered.filter { $0.isPinned }
            let recent = filtered.filter { !$0.isPinned }
            List {
                // 実装メモ2: 小見出しは「ピン留め」「最近の項目」の2種。日付グループ見出しは廃止のまま。
                // ピン留めが0件のときは見出しごと出さない(空セクションの見出しは意味の無い余白になる)。
                if !pinned.isEmpty {
                    sectionHeader("ピン留め")
                    ForEach(pinned, id: \.id) { summary in
                        row(for: summary)
                    }
                }

                if !recent.isEmpty {
                    sectionHeader("最近の項目")
                    ForEach(recent, id: \.id) { summary in
                        row(for: summary)
                    }
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

    /// セクション小見出し行(モックの .recent-label と同一スタイル)。ピン留め/最近の項目で共用。
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
            .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 4, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(SidebarPalette.paper)
    }

    /// 抽出した ChatHistoryRow(表示+操作)へ、親が所有する状態(active 判定・server chip 出し分け)と
    /// 副作用(select/pin/rename/delete。いずれも store 直読みや @State を触る)をクロージャで束ねる薄い factory。
    /// 行 View 自体は状態を持たず、ここで「何をするか」だけを注入する(責務抽出の結果・2026-07-23)。
    private func row(for summary: ChatSessionSummary) -> some View {
        ChatHistoryRow(
            summary: summary,
            isActive: summary.id == activeSessionID,
            serverName: showsServerChip ? serverShortName(summary.serverURL) : nil,
            onSelectTap: { select(summary.id) },
            onTogglePin: { togglePinned(summary) },
            onRename: { beginRename(summary) },
            onRequestDelete: { requestDelete(summary.id) }
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

    private func select(_ id: UUID) {
        onSelect(id)
        onClose()
    }

    private func requestDelete(_ id: UUID) {
        deleteTargetID = id
        showingDeleteConfirmation = true
    }

    private func commitDelete() {
        guard let id = deleteTargetID else { return }
        deleteTargetID = nil
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

    private func togglePinned(_ summary: ChatSessionSummary) {
        do {
            try store.setPinned(id: summary.id, isPinned: !summary.isPinned)
        } catch {
            Self.logger.error("履歴のピン留め変更に失敗: \(String(reflecting: error), privacy: .public)")
        }
        // pin の変更は並び順も変えるため、ローカル配列の部分更新でなく store の契約順を再読込する。
        reload()
    }

    private func beginRename(_ summary: ChatSessionSummary) {
        renameTargetID = summary.id
        renameTitle = summary.title
        showingRenamePrompt = true
    }

    private func commitRename() {
        guard let id = renameTargetID else { return }
        renameTargetID = nil
        do {
            try store.rename(id: id, title: renameTitle)
        } catch {
            Self.logger.error("履歴の名前変更に失敗: \(String(reflecting: error), privacy: .public)")
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

    /// サーバー URL の host 先頭ラベル(caldav.gigun-dev.workers.dev → "caldav")。ChatHomeView と同ロジック。
    private func serverShortName(_ url: URL) -> String {
        guard let host = url.host else { return "MCP" }
        return host.split(separator: ".").first.map(String.init) ?? host
    }
}
