// Services が swift-sdk に依存した状態でテスト実行できることの確認。
// Client は actor なので name/version の中身検証には await が必要になり P0 では過剰なため、
// ここでは「インスタンス生成が例外なく成功する」ことだけを確認する。
import Testing
@testable import Services

@Test("MCPHostServices.makeClient は swift-sdk の Client を生成できる")
func makeClientSucceeds() {
    _ = MCPHostServices.makeClient()
}
