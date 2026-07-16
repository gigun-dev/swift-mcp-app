// チャット履歴サイドバー(T6 後半・モック chat-v1.html「3. チャット履歴サイドバー」)。
//
// モック対応(chat-v1.html:292-327):
//  - .sidebar-head(h2「チャット」+ .search-field)→ タイトル + 検索フィールド。
//  - .new-chat(＋ 新規チャット)→ 上部の新規チャット行。
//  - .history-section(今日 / 昨日 / …)→ List の Section ヘッダ(日付グループ)。
//  - .history-item(title 太字 + preview 薄字 + meta「14:02 · caldav」)→ 各行。
//  - .history-item.active(現在表示中セッションを accent 背景でハイライト)→ activeSessionID で判定。
//
// このサイドバーは**表示専用**(タスク指示 B)。ChatStore を受け取り、一覧の読み込み・削除は
// ここで直接行う(サイドバーは「一覧を読む・行を消す」以上の責務を持たない薄い表示なので、
// VM に薄いラッパを重ねるより素直 — ChatHomeViewModel.chatStore の公開理由と同じ)。選択・新規は
// 親(ChatHomeView)へコールバックで通知し、実際のセッション切替(store.load →
// displayMode 遷移)は VM 側に委ねる(副作用ゼロの読み取り専用復元は VM の責務・設計 §5)。
import SwiftUI
import Kernel   // ChatSessionSummary
import Services // ChatStore

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
    @State private var query: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            newChatRow
            Divider()
            listOrEmpty
        }
        .background(Color(.systemBackground))
        // 初回表示で一覧を読む。サイドバーは開くたびに再マウントされる想定(drawer の
        // offset 表示ではなく条件付き生成にしているため)なので、開くたびに最新の index を読む。
        .task { reload() }
    }

    // MARK: - ヘッダ(タイトル + 検索)

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("チャット")
                .font(.title2.bold())
            // 検索フィールド(モックの .search-field)。角丸の薄い箱 + 虫眼鏡。
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("検索", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    // MARK: - 新規チャット行(モックの .new-chat)

    private var newChatRow: some View {
        Button {
            onNewChat()
            onClose()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.accentColor.opacity(0.14)))
                    .foregroundStyle(Color.accentColor)
                Text("新規チャット")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 一覧 / 空状態

    @ViewBuilder
    private var listOrEmpty: some View {
        let filtered = filteredSummaries
        if filtered.isEmpty {
            // 空状態(タスク指示)。検索で0件か、そもそも履歴が無いかで文言を分ける
            //(「検索に一致しない」と「まだ何も無い」は原因が違うので握りつぶさず区別する)。
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: query.isEmpty ? "clock" : "magnifyingglass")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text(query.isEmpty ? "まだ履歴がありません" : "一致する履歴がありません")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List {
                // 日付グループ(設計 §5・モックの .history-section)。Calendar で「今日/昨日/…」を判定。
                ForEach(groupedSummaries(filtered), id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.items, id: \.id) { summary in
                            historyRow(summary)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func historyRow(_ summary: ChatSessionSummary) -> some View {
        Button {
            onSelect(summary.id)
            onClose()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title.isEmpty ? "新規チャット" : summary.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !summary.preview.isEmpty {
                    Text(summary.preview)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(metaLine(summary))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())  // 余白部分のタップも拾う。
        }
        .buttonStyle(.plain)
        // 現在表示中のセッションを accent 背景でハイライト(モックの .history-item.active)。
        .listRowBackground(summary.id == activeSessionID ? Color.accentColor.opacity(0.12) : Color(.systemBackground))
        // スワイプ削除(タスク指示)。削除後は一覧を読み直す。
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                delete(summary.id)
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
    }

    // MARK: - データ読み書き

    private func reload() {
        summaries = store.loadIndex()  // updatedAt 降順(ChatStore.loadIndex の契約)。
    }

    private func delete(_ id: UUID) {
        // ChatStore.delete は冪等(ファイルが無くても index から消す)。失敗しても一覧再読込は行う
        // (削除に失敗したら次の reload で「消えていない」ことが見えるので、握りつぶしても
        // ユーザーには状態が正しく反映される)。原因追跡のため失敗時はコンソールへ。
        do {
            try store.delete(id: id)
        } catch {
            // Features 層に Logger を新設せず、削除失敗は print で最小限に留める(履歴削除は
            // 致命ではなく、失敗しても reload で実状態が見える。詳細ログが要るなら VM 側に寄せる)。
            print("履歴の削除に失敗: \(String(reflecting: error))")
        }
        reload()
    }

    // MARK: - フィルタ / グループ化

    /// title / preview の部分一致(大文字小文字無視)でローカルフィルタ。空クエリなら全件。
    private var filteredSummaries: [ChatSessionSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return summaries }
        return summaries.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.preview.localizedCaseInsensitiveContains(q)
        }
    }

    /// 日付グループの1塊(セクション見出し + その配下の項目)。
    private struct DateGroup {
        let title: String
        let items: [ChatSessionSummary]
    }

    /// updatedAt を基準に「今日 / 昨日 / 今週 / それ以前」へ振り分ける(設計 §5・Calendar で判定)。
    /// 入力は updatedAt 降順(loadIndex の契約)なので、各グループ内も自然に新しい順に並ぶ。
    ///
    /// 【グループ粒度の判断(設計に固定の粒度指定なし・こう解釈)】モックは「今日 / 昨日 / 7月前半」
    /// のように月単位の細かいラベルも出すが、月ラベルは月境界で意味が変わり実装が複雑化する。
    /// タスク指示の例示「今日 / 昨日 / それ以前 等」に沿い、Calendar で機械的に判定できる
    /// 「今日 / 昨日 / 今週 / それ以前」の4段に留める(可逆な調整値)。
    private func groupedSummaries(_ items: [ChatSessionSummary]) -> [DateGroup] {
        let calendar = Calendar.current
        let now = Date()

        var today: [ChatSessionSummary] = []
        var yesterday: [ChatSessionSummary] = []
        var thisWeek: [ChatSessionSummary] = []
        var older: [ChatSessionSummary] = []

        for item in items {
            if calendar.isDateInToday(item.updatedAt) {
                today.append(item)
            } else if calendar.isDateInYesterday(item.updatedAt) {
                yesterday.append(item)
            } else if let days = calendar.dateComponents([.day], from: item.updatedAt, to: now).day, days < 7 {
                thisWeek.append(item)
            } else {
                older.append(item)
            }
        }

        // 空グループはセクションごと出さない(空見出しでスペースを食わない)。
        var groups: [DateGroup] = []
        if !today.isEmpty { groups.append(DateGroup(title: "今日", items: today)) }
        if !yesterday.isEmpty { groups.append(DateGroup(title: "昨日", items: yesterday)) }
        if !thisWeek.isEmpty { groups.append(DateGroup(title: "今週", items: thisWeek)) }
        if !older.isEmpty { groups.append(DateGroup(title: "それ以前", items: older)) }
        return groups
    }

    // MARK: - 表示ヘルパ

    /// meta 行「14:02 · caldav」(モックの .meta)。今日なら時刻、それ以外は M/d。
    private func metaLine(_ summary: ChatSessionSummary) -> String {
        let when: String
        if Calendar.current.isDateInToday(summary.updatedAt) {
            when = summary.updatedAt.formatted(date: .omitted, time: .shortened)
        } else {
            when = summary.updatedAt.formatted(.dateTime.month(.defaultDigits).day())
        }
        return "\(when) · \(serverShortName(summary.serverURL))"
    }

    /// サーバー URL の host 先頭ラベル(caldav.gigun-dev.workers.dev → "caldav")。ChatHomeView と同ロジック。
    private func serverShortName(_ url: URL) -> String {
        guard let host = url.host else { return "MCP" }
        return host.split(separator: ".").first.map(String.init) ?? host
    }
}
