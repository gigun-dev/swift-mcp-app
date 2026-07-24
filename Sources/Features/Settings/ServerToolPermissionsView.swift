// 画面2: コネクタ詳細のツール許可一覧(design/09 S2・「詳細プッシュ」型の中段)。
//
// 役割: 1つの MCP サーバーが接続中(.ready)なら、その tools/list を名前順に並べ、各行に
// 「ツール名 + 状態ラベル + chevron」を出す。行タップで画面3(ToolPermissionDetailView)へ push。
// 行内に切替コントロールは置かない —— モバイル幅ではツール名の表示幅を優先する(design/09 決定1)。
//
// 【状態ラベルが corrected モデル(stored ?? defaultDecision)と一致する理由】
// runtime のゲートは `evaluate(decision: stored ?? defaultDecision(annotations:trusted:))` で確認要否を
// 決める(ToolCallRunner+PermissionGate)。設定画面の「見え方」も**同じ式**で出さなければ、表示と
// 実挙動がズレる(「常に許可」と出ているのに確認が出る等)。そこで:
//   - stored != nil → その decision をそのまま文言化(ユーザーの明示選択を無条件に尊重)。
//   - stored == nil → `autoAllowsWhenUnset(annotations, trusted:true)` が true なら「常に許可(自動)」、
//     でなければ「確認する」。これは defaultDecision(.allow/.ask)と同じ分岐を Kernel 純関数で共有する。
// 「(自動)」の注記は annotations 由来(サーバーが hint を変えれば変わりうる)であって、ユーザーが
// 明示保存した `.allow` とは別物であることを薄く示す(design/09「既定表示の写像」)。
//
// 【trusted:true 固定の根拠】このホストは全サーバーがユーザー自身の URL 追加 + OAuth 認証で入る。
// その行為自体が trust シグナル(design/09 信頼モデル)。将来ディレクトリ発見の未認証サーバーを
// 足すときだけ false を渡す軸を残すが、今は常に true。runtime ゲート側も同じ trusted=true を注入して
// いるので、ここも true に揃えないと表示と挙動がズレる。
//
// 【中立性(CLAUDE.md ビジョン2)】caldav 固有語を混ぜない。任意 MCP サーバーで同じ画面が成立する。
import SwiftUI
import Kernel      // ToolPermissionPolicy(autoAllowsWhenUnset)・ToolAnnotations・ToolPermissionDecision
import Services    // ReadyConnection・Tool・kernelAnnotations・ToolPermissionStore

/// 1サーバーのツール許可一覧(画面2)。接続状態は home 経由で観測し、.ready のときだけ権限行を出す。
struct ServerToolPermissionsView: View {
    let entry: MCPServerEntry
    var home: ChatHomeViewModel

    // 決定の読み書き口。ToolPermissionStore は UserDefaults 実装で状態を持たない(同じ永続データを見る)
    // ので、makeReady が proxy に注入するインスタンスと別インスタンスでも決定は一致する
    // (ConnectionsManager.makeReady と同じ判断)。画面ごとに新規生成でよい。
    private let store = ToolPermissionStore()

    // 詳細画面で保存/リセットして戻ってきたとき、行ラベルを取り直すためのトークン。
    // ToolPermissionStore は @Observable でない(UserDefaults 直読み)ので、SwiftUI は決定変更を
    // 自動追跡できない。onAppear(= 詳細から pop で戻ったとき発火)でこの値を進め、body 再評価を
    // 強制して storedDecision を読み直す(最小の反映手段・過剰な再設計をしない)。
    @State private var refreshToken = 0

    var body: some View {
        Form {
            headerSection
            content
        }
        .navigationTitle("ツールの権限")
        .navigationBarTitleDisplayMode(.inline)
        // pop で戻るたびに行ラベルを取り直す(上の refreshToken コメント参照)。
        .onAppear { refreshToken &+= 1 }
    }

    // MARK: - ヘッダ(コネクタ名 + URL)

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name).font(.callout.weight(.medium))
                Text(entry.url.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: - 本体(接続時はツール行・未接続時はプレースホルダ)

    @ViewBuilder
    private var content: some View {
        let state = home.connections.state(for: entry.id)
        if case .ready(let ready) = state {
            toolsSection(ready)
        } else {
            // 未接続(.ready でない)サーバーは tools を列挙できない。権限行は出さず、現在の接続状態と
            // 「接続すると設定できる」旨だけ示す(design/09・タスク指示のプレースホルダ)。
            placeholderSection(state)
        }
    }

    private func toolsSection(_ ready: ReadyConnection) -> some View {
        // name 昇順に並べる(design/09 画面2)。生 tools/list の順はサーバー任せなので安定させる。
        let sorted = ready.tools.sorted { $0.name < $1.name }
        return Section {
            ForEach(Array(sorted.enumerated()), id: \.offset) { _, tool in
                NavigationLink {
                    ToolPermissionDetailView(
                        serverURL: entry.url,
                        toolName: tool.name,
                        displayName: displayName(for: tool),
                        toolDescription: tool.description,
                        annotations: kernelAnnotations(from: tool.annotations)
                    )
                } label: {
                    toolRow(tool)
                }
            }
        } header: {
            Text("ツールの権限")
        } footer: {
            Text("「(自動)」はツールの申告(read-only 等)から導いた既定です。"
                + "行を開くと常に許可 / 承認が必要 / ブロックを選べます。")
        }
    }

    @ViewBuilder
    private func placeholderSection(_ state: ConnectionsManager.State) -> some View {
        Section {
            HStack {
                Text("状態")
                Spacer()
                ServerStateBadge.forState(state)
            }
        } footer: {
            Text("接続するとツールの権限を設定できます。行を戻ってサーバーを有効化・認証してください。")
        }
    }

    // MARK: - 1行(ツール名 + 状態ラベル + chevron は NavigationLink が付与)

    private func toolRow(_ tool: Tool) -> some View {
        HStack(spacing: 8) {
            Text(displayName(for: tool))
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            statusLabel(for: tool)
        }
    }

    /// 状態ラベル(corrected モデル: stored ?? default)。ファイル冒頭コメントの写像に一致させる。
    @ViewBuilder
    private func statusLabel(for tool: Tool) -> some View {
        let stored = storedDecision(for: tool)
        if let stored {
            // ユーザーが明示保存した決定は無条件に尊重して表示(hint 緩和で握りつぶさない)。
            Text(label(for: stored))
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            // 未保存 → annotations 由来の既定表示。trusted:true 固定(ファイル冒頭の根拠)。
            let annotations = kernelAnnotations(from: tool.annotations)
            let autoAllows = ToolPermissionPolicy.autoAllowsWhenUnset(annotations: annotations, trusted: true)
            Text(autoAllows ? "常に許可(自動)" : "確認する")
                .font(.footnote)
                // 「自動」は薄めの三次色で、明示保存(secondary)と視覚的にも区別する。
                .foregroundStyle(.tertiary)
        }
    }

    /// 生の永続値を読む薄いラッパ。body 評価中に refreshToken(@State)を読むことで SwiftUI の依存を
    /// 張り、詳細から pop で戻って onAppear が refreshToken を進めたとき、この行が再評価されて
    /// storedDecision を読み直す(ToolPermissionStore は @Observable でないための最小反映手段)。
    private func storedDecision(for tool: Tool) -> ToolPermissionDecision? {
        _ = refreshToken  // 依存注入(値は使わない・再評価トリガのため)。
        return store.storedDecision(serverURL: entry.url, toolName: tool.name)
    }

    /// 明示保存済み decision の日本語文言(design/09 画面2)。
    private func label(for decision: ToolPermissionDecision) -> String {
        switch decision {
        case .allow: return "常に許可"
        case .ask: return "確認する"
        case .deny: return "ブロック"
        }
    }

    /// 行に出す表示名。annotations.title があればそれ(サーバーが付けた人間可読名)、無ければ生 name。
    /// 決定のキーは常に生 name(originalToolName)なので、表示だけ title に寄せる(識別性は保つ)。
    private func displayName(for tool: Tool) -> String {
        if let title = tool.annotations.title, !title.isEmpty { return title }
        return tool.name
    }
}
