import SwiftUI
import Services

/// 入力下書き・送信可否・利用量表示をまとめるチャット composer。
struct ChatComposerView: View {
    let chatVM: ChatViewModel
    @Binding var draft: String
    @FocusState.Binding var inputFocused: Bool
    let haptics: ChatHapticsController

    // MARK: - 入力バー(モックの .composer)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // エラー(赤字・タスク指示)。次の送信で ChatViewModel 側が消す。
            if let error = chatVM.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }

            // コスト表示(モックの .cost-hint)。T7 前なのでトークン数だけ($ は出さない)。
            costHint

            HStack(alignment: .bottom, spacing: 8) {
                TextField("メッセージを入力…", text: $draft, axis: .vertical)
                    .lineLimit(1 ... 4)
                    .focused($inputFocused)  // キーボード dismiss を制御するため focus を束ねる。
                    // UITest から掴むための識別子(既存の "home.root" と同じ命名規則)。
                    // 2026-08-01: 入力欄の長押し(ペースト/選択)でキーボードが落ちる不具合の
                    // 回帰テスト(SmokeUITests.testLongPressInComposerKeepsKeyboard)で使う。
                    .accessibilityIdentifier("chat.composer.input")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
                    .disabled(chatVM.isRunning)

                Button(action: sendDraft) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(canSend ? Color.accentColor : Color.gray))
                }
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// コスト表示行。lastUsage(このターン)と cumulativeUsage(累計)を控えめに出す。
    /// 未計上(まだ1ターンも走っていない)なら何も出さない(嘘の 0 を見せない)。
    /// T7: 分かるときだけ ≈ $X を続けて出す(chatVM.lastCostUSD/cumulativeCostUSD が nil =
    /// 未知モデル or pricing 未ロードのときはコストを一切出さない——トークン数のみ表示は従来どおり。
    /// 設計 §6「嘘の金額を出さない」を厳守。"—" のような偽の埋め草も出さない=単に無い)。
    @ViewBuilder
    private var costHint: some View {
        if let usage = chatVM.lastUsage {
            let total = usage.totalTokens ?? (usage.promptTokens + usage.completionTokens)
            let cumulative = chatVM.cumulativeUsage
            let cumulativeTotal = cumulative?.totalTokens
                ?? cumulative.map { $0.promptTokens + $0.completionTokens }
            HStack(spacing: 8) {
                Text("このターン ≈ \(total.formatted()) tok")
                if let lastCost = chatVM.lastCostUSD {
                    Text(Self.formatUSD(lastCost))
                }
                if let cumulativeTotal {
                    Text("· 累計 \(cumulativeTotal.formatted()) tok")
                }
                if let cumulativeCost = chatVM.cumulativeCostUSD {
                    Text(Self.formatUSD(cumulativeCost))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }

    /// 小額($0.0000 まで見える程度)を出すためのフォーマット。トークン単価は $0.000001/token 級が
    /// 普通(例 gpt-4o-mini 出力 6e-7)なので、NumberFormatter の通貨書式(小数2桁止め)では
    /// ほぼ常に "$0.00" に潰れて情報にならない。`String(format:)` で小数4桁固定にする
    /// (タスク指示「4〜5桁」・4桁を採用: gpt-4o-mini 級の1ターン数百〜数千トークンなら
    /// $0.0001 オーダーまで見えれば十分実用。5桁だと末尾が常に丸めノイズになりやすいため4桁で妥協
    /// ——設計に桁数の明記は無いのでこう解釈)。
    private static func formatUSD(_ value: Double) -> String {
        String(format: "≈ $%.4f", value)
    }

    /// 送信可能条件: 実行中でなく、下書きが空白でない。
    private var canSend: Bool {
        !chatVM.isRunning && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        inputFocused = false  // 送信したらキーボードを閉じる(応答を見やすく・出っぱなし対策)。
        haptics.sent()  // 送信確定の軽い合図(タスク指示 2)。
        // ChatViewModel.submit は throw しない(内部の send が errorMessage に載せる)。VM 自身が
        // Task を保持する形にしたので、View 側は Task { } で包まない(監査 2026-07-18 MEDIUM)。
        chatVM.submit(text)
    }
}
