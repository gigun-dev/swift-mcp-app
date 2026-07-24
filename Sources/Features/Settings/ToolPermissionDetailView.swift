// 画面3: 1ツールの許可詳細(design/09 S2・「詳細プッシュ」型の末端)。
//
// 役割: 3択(常に許可 / 承認が必要 / ブロック)を縦積みのラジオ相当で出し、現在値にチェックを付け、
// 選択で即保存する。その下にツールの description と(破壊的なら)警告を出す。
//
// 【チェック位置が corrected モデル(stored ?? defaultDecision)と一致する理由】
// 画面2の状態ラベルと同じ理屈: runtime ゲートは `stored ?? defaultDecision(annotations:trusted:)` で
// 実効決定を組む。詳細画面の「今どれが有効か」もこの式で出す:
//   - stored != nil → その decision の択にチェック(ユーザーの明示選択を尊重)。
//   - stored == nil → defaultDecision(annotations, trusted:true) の択にチェックし、そこに「(既定)」注記。
// これで「表示 = runtime 挙動」を Kernel 純関数の共有で保証する(判定の正典を二重化しない)。
//
// 【.ask も明示保存する理由】store.setDecision は 3 値すべて(allow/ask/deny)をキーとして永続化する
// (ToolPermissionStore の 2026-07-24 refactor)。「承認が必要」を選ぶと .ask がキー付きで保存され、
// storedDecision が nil でなくなる。これが無いと、readOnly closed trusted なツールを明示的に
// 「承認が必要」にしても gate の defaultDecision が .allow へ昇格させ、明示選択が無視される
// (= readOnly でも承認が必要にできる、という UX がここで初めて効く)。
//
// 【trusted:true 固定の根拠】画面2と同じ(ユーザー追加 + OAuth = trusted・design/09 信頼モデル)。
import SwiftUI
import Kernel      // ToolPermissionPolicy・ToolPermissionDecision・ToolAnnotations
import Services    // ToolPermissionStore

/// 1ツールの許可詳細(画面3)。決定は (serverURL, toolName=originalToolName) をキーに読み書きする。
struct ToolPermissionDetailView: View {
    let serverURL: URL
    // 決定のキーになる生ツール名(originalToolName)。表示名(displayName)とは別に必ず生 name を持つ。
    let toolName: String
    let displayName: String
    let toolDescription: String?
    let annotations: ToolAnnotations?

    private let store = ToolPermissionStore()

    // 明示保存されている decision(未保存なら nil)。onAppear で読み込み、選択・リセットで更新する。
    // @State で持つのは ToolPermissionStore が @Observable でない(UserDefaults 直読み)ため——
    // この画面内の即時反映は @State で完結させ、画面2側は pop 時の onAppear 再読込で拾う(最小反映)。
    @State private var stored: ToolPermissionDecision?

    var body: some View {
        Form {
            choicesSection
            descriptionSection
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 生の永続値を読み込む(未保存なら nil)。以後の選択はこの @State を即時更新して反映する。
            stored = store.storedDecision(serverURL: serverURL, toolName: toolName)
        }
    }

    // MARK: - 3択(ラジオ相当)

    /// 未保存時に既定でチェックが付く択(defaultDecision と同じ分岐)。「(既定)」注記の対象でもある。
    private var defaultDecision: ToolPermissionDecision {
        ToolPermissionPolicy.defaultDecision(annotations: annotations, trusted: true)
    }

    /// いまチェックが付くべき実効決定(corrected モデル)。stored 優先・無ければ既定。
    private var effective: ToolPermissionDecision {
        stored ?? defaultDecision
    }

    private var choicesSection: some View {
        Section {
            // 縦積みで allow → ask → deny の順(claude.ai と同じ「緩い→厳しい」順)。
            choiceRow(.allow, title: "常に許可", symbol: "checkmark.circle",
                      caption: "確認せずに実行します。")
            choiceRow(.ask, title: "承認が必要", symbol: "hand.raised",
                      caption: "実行前に毎回確認します。")
            choiceRow(.deny, title: "ブロック", symbol: "nosign",
                      caption: "このツールの実行を拒否します。")
        } header: {
            Text("許可")
        } footer: {
            // 「既定に戻す」は明示保存があるときだけ出す(未保存は既に既定なので出す意味がない)。
            if stored != nil {
                Button("既定に戻す", role: .destructive) {
                    // 明示決定を消す = 未保存へ戻す(annotations 由来の既定に従うようになる)。
                    store.clearDecision(serverURL: serverURL, toolName: toolName)
                    stored = nil
                }
                .font(.footnote)
            }
        }
    }

    @ViewBuilder
    private func choiceRow(
        _ decision: ToolPermissionDecision,
        title: String,
        symbol: String,
        caption: String
    ) -> some View {
        // 未保存で、かつこの択が既定択のとき「(既定)」を添える(annotations 由来であることの明示)。
        let isDefaultUnset = (stored == nil && decision == defaultDecision)
        Button {
            // 選択で即保存。.ask も明示保存される(ファイル冒頭「.ask も明示保存する理由」)。
            store.setDecision(decision, serverURL: serverURL, toolName: toolName)
            stored = decision
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).foregroundStyle(.primary)
                        if isDefaultUnset {
                            Text("(既定)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                // チェックは実効決定(stored ?? default)に付ける。未保存でも既定択に付くので、
                // 「今この設定だとどう動くか」が常に1つ選ばれて見える(空選択にしない)。
                if effective == decision {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 説明 + 破壊警告

    @ViewBuilder
    private var descriptionSection: some View {
        Section {
            if let toolDescription, !toolDescription.isEmpty {
                Text(toolDescription).font(.callout).foregroundStyle(.secondary)
            } else {
                Text("このツールには説明がありません。").font(.callout).foregroundStyle(.tertiary)
            }
            // 破壊的(未申告は true=破壊的とみなす・isLikelyDestructive)なら取り消し不能の注意を出す。
            // これは警告表示にだけ使い、許可の緩和には一切使わない(性悪説・ToolPermissionPolicy 参照)。
            if annotations?.isLikelyDestructive == true {
                Label(
                    "この操作は取り消せない変更を行う可能性があります。",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        } header: {
            Text("説明")
        } footer: {
            // 決定キーが生ツール名であることを技術的に隠さず示す(displayName と別なら特に有用)。
            Text("ツール名: \(toolName)").font(.caption.monospaced()).textCase(nil)
        }
    }
}
