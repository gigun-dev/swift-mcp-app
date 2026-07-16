// MCP Apps(ext-apps 拡張)の method 文字列定数。
//
// 出典は ext-apps `src/spec.types.ts:814-843` の `*_METHOD` 定数群
// (CLAUDE.md「写経した契約には caldav 側の出典をコメントで残す」に倣い、ここでは一次資料の
// ext-apps 側の行番号を各定数に付す。2026-07-15 時点のチェックアウト)。
//
// 設計 §3-2 の最小集合ぶんだけ写経する。sandbox-proxy 系(ネイティブホストでは往復ごと省略・
// 設計 §0)や download-file / update-model-context / message はスパイク対象外なので、
// 必要になった時点で足す(可逆)。request-display-mode は P4-DM(displayMode ネゴシエーション)で
// 追加済み(設計 04)。
public enum AppsMethod {
    // ライフサイクル。
    // View→Host: 初期化リクエスト。spec.types.ts:838 INITIALIZE_METHOD
    public static let initialize = "ui/initialize"
    // View→Host: 初期化完了通知。この受信で状態機械が ready へ遷移する。
    // spec.types.ts:840 INITIALIZED_METHOD
    public static let initialized = "ui/notifications/initialized"

    // Host→View: ツール入力・結果・キャンセルの配送。
    // spec.types.ts:825 TOOL_INPUT_METHOD
    public static let toolInput = "ui/notifications/tool-input"
    // spec.types.ts:829 TOOL_RESULT_METHOD(params は CallToolResult を JSONValue で素通し)
    public static let toolResult = "ui/notifications/tool-result"
    // spec.types.ts:831 TOOL_CANCELLED_METHOD
    public static let toolCancelled = "ui/notifications/tool-cancelled"

    // View→Host: サイズ変更通知(高さ追従に使う・設計 §5)。
    // spec.types.ts:823 SIZE_CHANGED_METHOD
    public static let sizeChanged = "ui/notifications/size-changed"

    // Host→View: 破棄前のグレースフルシャットダウン要求(リクエスト)。
    // spec.types.ts:836 RESOURCE_TEARDOWN_METHOD
    public static let resourceTeardown = "ui/resource-teardown"

    // Host→View: hostContext の部分更新通知(幅変化などを View に伝える・設計 §5)。
    // spec.types.ts:833 HOST_CONTEXT_CHANGED_METHOD
    public static let hostContextChanged = "ui/notifications/host-context-changed"

    // View→Host: 外部リンクを開くリクエスト(実装は UIApplication.open 1行・設計 §3-2)。
    // spec.types.ts:814 OPEN_LINK_METHOD
    public static let openLink = "ui/open-link"

    // View→Host: displayMode 変更リクエスト(P4-DM・設計 04 §2 決定2/§5 H2)。
    // spec.types.ts:842 REQUEST_DISPLAY_MODE_METHOD
    public static let requestDisplayMode = "ui/request-display-mode"

    // --- 素通し(型を付けずに method 文字列でルーティングする系。設計 §3-3)---
    // これらは MCP 標準メソッドで ext-apps の *_METHOD 定数には無い。View→サーバーの
    // プロキシ対象として文字列だけ持っておく。
    public static let toolsCall = "tools/call"
    public static let resourcesRead = "resources/read"
    public static let ping = "ping"
}
