// View→Host メッセージの2レーン分類(設計 §3-3)。
//
// ブリッジは「ホストが解釈する ui/*(typed レーン)」と「サーバーへ素通しする MCP 標準系
// (passthrough レーン)」を分けて扱う。typed に載せるのは設計 §3-2 の最小集合のうち
// View→Host 方向のものだけ(initialize / initialized / size-changed / open-link)。
// 残り(tools/call・resources/read・ping・未実装の ui/message 等)はすべて passthrough に
// 落ちる。将来 ui/update-model-context などを typed に昇格させるのは、classify の分岐を
// 1本足すだけで済む(可逆)。

/// typed レーン: ホストが型として解釈する View→Host メッセージ。
public enum TypedViewMessage: Sendable {
    // リクエスト(応答が要る)。id を保持して応答に使う。
    case initialize(id: RequestID, InitializeParams)
    case openLink(id: RequestID, OpenLinkParams)
    // 通知(応答不要)。
    case initialized
    case sizeChanged(SizeChangedParams)
}

/// View から届いたメッセージの分類結果。
public enum IncomingViewMessage: Sendable {
    case typed(TypedViewMessage)
    // passthrough レーン: サーバーへ素通しする。id が nil なら通知、非 nil ならリクエスト。
    case passthrough(method: String, id: RequestID?, params: JSONValue?)
    // View からの応答(ホストが投げた ui/resource-teardown 等への返答)。method を持たず
    // 上の2レーンと構造が違うので独立ケースにする。
    case response(JSONRPCResponse)

    /// 生の JSON-RPC メッセージを2レーンに振り分ける。ブリッジの受信ディスパッチの入口。
    /// typed の params デコードに失敗したら throw(malformed は上位で onerror 相当に回す)。
    public static func classify(_ message: JSONRPCMessage) throws -> IncomingViewMessage {
        switch message {
        case .response(let response):
            return .response(response)

        case .request(let request):
            switch request.method {
            case AppsMethod.initialize:
                // params 省略はプロトコル上ありえない(appInfo 等が必須)ので、空だと decode が失敗する。
                let params = try (request.params ?? .object([:])).decode(InitializeParams.self)
                return .typed(.initialize(id: request.id, params))
            case AppsMethod.openLink:
                let params = try (request.params ?? .object([:])).decode(OpenLinkParams.self)
                return .typed(.openLink(id: request.id, params))
            default:
                // tools/call・resources/read・ping・未実装 ui/* リクエストはここへ。
                return .passthrough(method: request.method, id: request.id, params: request.params)
            }

        case .notification(let notification):
            switch notification.method {
            case AppsMethod.initialized:
                return .typed(.initialized)
            case AppsMethod.sizeChanged:
                // size-changed は params 省略可(width/height とも optional)。空でも decode 成功する。
                let params = try (notification.params ?? .object([:])).decode(SizeChangedParams.self)
                return .typed(.sizeChanged(params))
            default:
                return .passthrough(method: notification.method, id: nil, params: notification.params)
            }
        }
    }
}
