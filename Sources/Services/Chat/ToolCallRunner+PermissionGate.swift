// R4 許可ゲート(HITL)の判定を ToolCallRunner 本体から分離する。
//
// なぜ別ファイルか: 本体(ToolCallRunner.swift)の type body が肥大しないよう、ゲート特有の分岐
// (annotations 評価・確認 UI への問い合わせ・deny の Execution 生成)をここへ寄せる。判定の中身は
// Kernel の純関数 ToolPermissionPolicy.evaluate に委ね、ここは「context のマップから材料を引き、
// confirm closure を await し、拒否なら failed Execution を返す」配線だけを担う。
//
// 正典: caldav docs/modeling/15 §A(HITL はホスト責務・annotations は untrusted hint・既定は確認側)。
import Foundation
import Kernel

extension ToolCallRunner {
    /// 許可ゲートを適用する。実行してよければ nil、拒否(deny または確認で拒否)なら failed Execution を返す。
    ///
    /// wire 名 → 決定の同一性は「serverURL × originalToolName」で固定する(ToolPermissionStore 参照)。
    /// 「常に許可(allowAlways)」の応答はここで store へ `.allow` を永続化する。
    static func permissionGateDenial(
        call: ToolCall,
        index: Int,
        arguments: JSONValue,
        context: ExecutionContext
    ) async -> Execution? {
        let wireName = call.function.name
        let originalName = context.originalToolNamesByTool[wireName] ?? wireName
        let serverURL = context.serverURLsByTool[wireName]
        let annotations = context.annotationsByTool[wireName]
        let decision = context.permissionStore.decision(serverURL: serverURL, toolName: originalName)

        // trusted: true を渡す理由: 現状 ServerRegistry のサーバーは全てユーザーが明示的に
        // 追加 + OAuth 認証したもの = trusted(design/09 信頼モデル)。将来ディレクトリ発見の
        // 未認証サーバー(claude.ai の「コネクタの検出」的なもの)を扱うようになったら、ここを
        // context 経由の per-server 信頼判定へ差し替える(annotations だけで安全を決めない）。
        switch ToolPermissionPolicy.evaluate(annotations: annotations, decision: decision, trusted: true) {
        case .proceed:
            return nil  // 確認不要(allow、または ask だが readOnly 申告あり)。そのまま実行へ。
        case .deny:
            // ユーザーが per-tool に拒否したツール。副作用を起こさず failed の Execution を返す。
            // LLM へは role:"tool" で「拒否された」旨が返るので、モデルは別手段を選べる(黙って握りつぶさない)。
            return deniedExecution(call: call, index: index, arguments: arguments)
        case .confirm:
            // 確認を UI へ問い合わせ、応答を await する(並行 tool call はそれぞれ独立に待つ)。
            // argumentsJSON は LLM が返した生の引数文字列をそのまま使う(再エンコード不要 —
            // ここで JSON を作り直すと optional_data_string_conversion 等の余計な変換が要る)。
            let request = ToolCallConfirmationRequest(
                toolName: originalName,
                serverName: context.serverNamesByTool[wireName],
                annotations: annotations,
                argumentsJSON: call.function.arguments
            )
            switch await context.confirm(request) {
            case .allowOnce:
                return nil  // 今回だけ許可。保存しない。
            case .allowAlways:
                // 「常に許可」を永続化(以後このツールは確認しない)。
                context.permissionStore.setDecision(.allow, serverURL: serverURL, toolName: originalName)
                return nil
            case .deny:
                return deniedExecution(call: call, index: index, arguments: arguments)
            }
        }
    }

    /// 許可ゲートで拒否(deny)されたときの Execution。failed=true で「実行しなかった」ことを表し、
    /// content は LLM が読んでも分かる拒否メッセージにする(モデルが結果を捏造しないよう明示的に伝える)。
    /// result=nil なのでカードも起こらない(makeCards は failed/result nil を除外する)。
    private static func deniedExecution(call: ToolCall, index: Int, arguments: JSONValue) -> Execution {
        Execution(
            index: index,
            toolCallId: call.id,
            toolName: call.function.name,
            content: "ユーザーがこのツールの実行を拒否しました。実行されていません。",
            failed: true,
            result: nil,
            arguments: arguments
        )
    }
}
