// Services の骨格として P0 で置く最小の実体。
// swift-sdk (`MCP` モジュール)を実際に import し、この Services ターゲットが
// swift-sdk への依存を含めてビルドできることを確認するためのプレースホルダ。
// 実際の接続処理(HTTPClientTransport + OAuth 2.1 フルフロー)は
// P1「接続(MVP フェーズ1)」で実装する(docs/next-directions.md)。
import Kernel

// `@_exported import` で MCP の公開シンボルを Services 経由でも見えるようにしておく。
// Features(XcodeGen の iOS アプリターゲット)は project.yml 上 swift-sdk を直接の
// パッケージ依存として宣言していない(Kernel/Services の2 product しかリンクしていない)ため、
// `OAuthAuthorizationDelegate` や `Tool` など MCP の型を Features 側の
// LoopbackOAuthAuthorizationDelegate / ConnectionView で使うには、Services が MCP を
// 再エクスポートしてリンク上も型解決上も透過にしておく必要がある
// (SwiftPM のライブラリ product は依存先を推移的にリンクするため、シンボル解決さえ
// 通れば実行時に問題は起きない。あくまで `import` 可否だけの話)。
@_exported import MCP

public enum MCPHostServices {
    /// swift-sdk の `Client` 型(actor)を実際に参照できることのビルド時保証。
    /// P1 でここに接続用の Client 生成・保持ロジックを組み込んでいく。
    public static func makeClient() -> Client {
        Client(name: AppInfo.name, version: "0.1.0")
    }
}
