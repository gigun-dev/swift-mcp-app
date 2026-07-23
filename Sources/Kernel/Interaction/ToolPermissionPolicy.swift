// per-tool の許可ゲート(R4・HITL = Human In The Loop)を、UI・ネットワーク・永続化から切り離して
// 「annotations(untrusted hint)+ ユーザーの保存済み決定」だけから確認要否を決める純関数群。
//
// 【なぜホスト責務なのか(正典: caldav docs/modeling/15 §A・queue 7)】
// MCP の `tool.annotations`(readOnlyHint 等)は **サーバーが自己申告する hint** であり、
// 悪意あるサーバーは destructive なツールを readOnly と偽れる。したがって MCP spec は
// 「クライアントは annotations だけで tool 実行の可否を決めてはならない(untrusted hint)」と釘を刺す
// (swift-sdk Tools.swift:33 のコメントにも同趣旨)。そこで境界の設計を**性悪説**に倒す:
//   - 既定(ask)は「確認する」側に倒す。annotations が無い/読めないツールは必ず確認。
//   - annotations で確認を**弱められる**のは「readOnlyHint == true を申告したツールの確認を省く」
//     という **唯一の緩和** だけ。destructiveHint 等は確認を**強める**方向(表示の警告)にしか使わない
//     ——申告の有無で確認を省くことは絶対にしない(偽装で確認を飛ばされないように)。
// この方針は claude.ai カスタムコネクタの境界(常に許可 / 毎回確認(既定)/ 拒否)と同じ。
//
// 【なぜ Kernel の純関数なのか】判定は「annotations と決定 → 確認要否」の写像でしかなく、
// プラットフォーム非依存(CLAUDE.md アーキ方針)。swift-testing で境界(未申告/readOnly/deny)を
// 高速に固定できる。UI(確認シート)も永続化(UserDefaults)も Services/Features 側の責務。
import Foundation

/// ツールの annotations(MCP `tool.annotations`)を Kernel へ additive に持ち込む純データ型。
///
/// 出典: MCP spec 2025-06-18 schema.ts `ToolAnnotations` / swift-sdk `Tool.Annotations`
/// (Tools.swift:35-88)。全フィールドが hint で optional。**未申告(nil)と明示 false を区別する**
/// ため optional のまま持つ(既定値の当てはめは表示用アクセサでだけ行い、判定の生値は歪めない)。
///
/// destructiveHint/openWorldHint の「未指定時の実装既定は true」は spec のとおりだが(性悪説)、
/// **確認要否の判定には使わない**(唯一の緩和は readOnlyHint == true のみ・下の evaluate 参照)。
/// これらは確認シートの警告表示(destructive なら「取り消せない操作かもしれません」等)にだけ使う。
public struct ToolAnnotations: Codable, Equatable, Sendable {
    public var title: String?
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    public var idempotentHint: Bool?
    public var openWorldHint: Bool?

    public init(
        title: String? = nil,
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil
    ) {
        self.title = title
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }

    /// 表示用の「破壊的か」。未申告は spec の実装既定(true)へ倒す = 性悪説
    /// (判定には使わず、確認シートの警告文の出し分けにだけ使う)。readOnlyHint==true のときは
    /// destructiveHint は無意味(spec)なので破壊的ではないと解釈する。
    public var isLikelyDestructive: Bool {
        if readOnlyHint == true { return false }
        // 未申告は true 既定(spec)。申告があればそれに従う。
        return destructiveHint ?? true
    }
}

/// ユーザーが per-tool に保存する境界決定(claude.ai カスタムコネクタと同じ三択)。
///
/// String raw を持つのは UserDefaults へそのまま永続化するため(Services の ToolPermissionStore)。
/// 既定は `.ask`(毎回確認)——性悪説の既定。ストアに保存が無いツールは常に `.ask` として扱う。
public enum ToolPermissionDecision: String, Codable, Equatable, Sendable, CaseIterable {
    /// 常に許可(確認を出さず即実行)。ユーザーが「常に許可」を選んだツールだけがここへ来る。
    case allow
    /// 毎回確認(既定)。annotations が readOnly を申告していれば確認を省ける(唯一の緩和)。
    case ask
    /// 拒否(実行させない)。モデル発でもカード発でもハードブロックする。
    case deny
}

/// ゲート判定の結果。Services(ToolCallRunner)がこれを見て「即実行 / 確認を await / 拒否」を分岐する。
public enum ToolGateOutcome: Equatable, Sendable {
    /// 確認なしで実行してよい(decision == .allow、または ask だが readOnly 申告あり)。
    case proceed
    /// ユーザーへ確認を出し、その応答を待ってから実行/中止を決める(decision == .ask かつ非 readOnly)。
    case confirm
    /// 実行させない(decision == .deny)。
    case deny
}

/// per-tool 許可ゲートの中核判定(純関数)。
public enum ToolPermissionPolicy {
    /// annotations(untrusted hint)とユーザーの保存済み決定から、確認要否を決める。
    ///
    /// 分岐(性悪説・上のファイルコメント参照):
    ///  - `.deny`  → `.deny`(annotations に関係なくハードブロック)。
    ///  - `.allow` → `.proceed`(ユーザーが明示的に常時許可したので確認しない)。
    ///  - `.ask`   → readOnlyHint == true のツールだけ `.proceed`(唯一の緩和)。それ以外
    ///               (未申告・readOnlyHint == false/nil・destructive 申告あり等すべて)は `.confirm`。
    ///
    /// **なぜ readOnlyHint だけを信頼するか**: readOnly を「偽って false/未申告にする」インセンティブは
    /// 攻撃者に無い(むしろ確認を増やすだけ)。逆に「破壊的なのに readOnly と偽る」攻撃はありうるが、
    /// それは「ユーザーが自分でこのツールを ask のまま使っている」時点で、readOnly 申告を信じて確認を
    /// 省くリスクをユーザーが受容している範囲。destructive を隠す方向の偽装は確認を**省けない**
    /// (readOnlyHint を true にしない限り confirm のまま)ので、緩和は readOnlyHint==true に限定する。
    public static func evaluate(
        annotations: ToolAnnotations?,
        decision: ToolPermissionDecision
    ) -> ToolGateOutcome {
        switch decision {
        case .deny:
            return .deny
        case .allow:
            return .proceed
        case .ask:
            // 唯一の緩和: readOnly を明示申告したツールだけ確認を省く。未申告(nil)は省かない。
            return annotations?.readOnlyHint == true ? .proceed : .confirm
        }
    }
}

/// 確認 UI へ渡す要求(Runner → Features)。純データ型(Kernel)なので Services も Features も共有できる。
///
/// `id` は SwiftUI の確認キュー(並行 tool call で複数同時に積まれうる)を識別し、応答を正しい
/// continuation へ返すため。`toolName` は表示名(originalToolName・ユーザーが読む名前)、
/// `argumentsJSON` は引数の要約表示に使う生 JSON(Features 側で数行に丸めて出す)。
public struct ToolCallConfirmationRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let toolName: String
    public let serverName: String?
    public let annotations: ToolAnnotations?
    public let argumentsJSON: String

    public init(
        id: UUID = UUID(),
        toolName: String,
        serverName: String?,
        annotations: ToolAnnotations?,
        argumentsJSON: String
    ) {
        self.id = id
        self.toolName = toolName
        self.serverName = serverName
        self.annotations = annotations
        self.argumentsJSON = argumentsJSON
    }
}

/// 確認 UI の応答(Features → Runner)。
public enum ToolCallConfirmationResponse: Equatable, Sendable {
    /// 今回だけ許可(保存しない)。
    case allowOnce
    /// 常に許可(ストアへ `.allow` を保存し、以後このツールは確認しない)。
    case allowAlways
    /// 拒否(この実行を中止。保存はしない——次回はまた確認する)。
    case deny
}
