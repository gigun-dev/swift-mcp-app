// Services の骨格として P0 で置く最小の実体。
// swift-sdk (`MCP` モジュール)を実際に import し、この Services ターゲットが
// swift-sdk への依存を含めてビルドできることを確認するためのプレースホルダ。
// 実際の接続処理(HTTPClientTransport + OAuth 2.1 フルフロー)は
// P1「接続(MVP フェーズ1)」で実装する(docs/next-directions.md)。
import Kernel
import MCP

public enum MCPHostServices {
    /// swift-sdk の `Client` 型(actor)を実際に参照できることのビルド時保証。
    /// P1 でここに接続用の Client 生成・保持ロジックを組み込んでいく。
    public static func makeClient() -> Client {
        Client(name: AppInfo.name, version: "0.1.0")
    }
}
