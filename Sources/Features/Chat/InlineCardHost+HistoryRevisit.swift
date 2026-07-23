// 履歴再訪カードの鮮度ギャップ修正(2026-07-24)。InlineCardView.swift が 400 行上限に達したため、
// この一機能だけ別ファイルへ切り出す(機能単位で分けるのは file_length 対策の常道・実装は同一 host のまま)。
import Kernel    // CardEmbed・JSONValue
import Services  // AppsBridgeSession

extension InlineCardHost {
    /// tool-input(引数)→ tool-result(structuredContent)の順で初期ペイロードを配送する。
    /// build() から呼ばれる初回配送。sendToolResult 部分は下の履歴再 push と同じ「SWR 発火条件」を成す。
    ///
    /// 【履歴 revalidation gate 撤去後の姿(2026-07-23・queue 2)】
    /// 以前はここに「履歴由来なら _meta へ hint を載せて gate を arm し、成功完了までカードを触らせない」
    /// 経路があった。その gate/hint 機構は caldav 側裁定で撤去した(caldavリポジトリ docs/modeling/15・SWR):
    /// ホスト固有の `_meta` hint はサードパーティカードを全滅させ・RFC 5861(stale-while-revalidate)に
    /// 逆行し・ext-apps に足場が無い。鮮度は caldav 側 SWR(structuredContent 内 generatedAt の 60 秒判定)が
    /// 担い、その発火条件は「host が履歴復元時に保存済み toolResult をカードへ再 push すること」だけ。
    /// よってライブ・履歴を問わず、保存済み structuredContent を素直に tool-result として送る
    /// (この再 push こそが SWR の発火条件なので必ず残す)。
    func sendInitialPayload(card: CardEmbed, session: AppsBridgeSession) async {
        await session.sendToolInput(arguments: card.arguments ?? .object([:]))
        await session.sendToolResult(card.structuredContent ?? .null)
    }

    /// 履歴再訪で **既に build 済みの host を再表示した**ときだけ呼ぶ、保存済み toolResult の再 push。
    ///
    /// 【なぜ必要か】
    /// ext-apps / OpenAI Apps SDK とも「新データは tool 呼び出し完了時にだけ流入・自動リフレッシュしない」。
    /// 履歴再訪で live island(host 再利用)すると buildIfNeeded は no-op(guard buildTask == nil)で
    /// sendInitialPayload が走らず、caldav カード側 SWR(tool-result 受信時の generatedAt 60 秒判定)が
    /// 発火する機会が無い(E2E ログ裏取り: 再オープンで bridge トラフィックゼロ)。そこで再表示時に
    /// 保存済み structuredContent を tool-result として1回だけ再送し、SWR に revalidate の機会を与える。
    ///
    /// tool-input は再送しない(SWR の発火条件は tool-result 受信・タスク指示)。caldav SWR は generatedAt
    /// 60 秒判定で dedup するので多少 eager でも over-fetch はしないが、bridge スパムは避け「再表示1回=1回」に
    /// 留める(この1回制御は呼び出し側 InlineCardView の .task 単位で担保する・HistoryCardRepushDecision)。
    func republishToolResultForHistoryRevisit(card: CardEmbed) async {
        // build 未完(session 未生成)・build 失敗時は何もしない。build 中に呼ばれた場合(session はまだ
        // nil)も同様にスキップされ、build 側 sendInitialPayload の push に一本化される(二重送信の縮退)。
        guard let session else { return }
        await session.sendToolResult(card.structuredContent ?? .null)
    }
}
