// Kernel の骨格として P0 で置く最小の実体。
// 実際の契約 DTO(MCP レスポンスの Codable 型など)は P1 以降、caldav 側の
// server.ts / docs/modeling/12 を出典として写経しながら追加していく(CLAUDE.md 参照)。
// このファイルは「Kernel ターゲットがビルド・テスト可能であること」自体を確認する
// プレースホルダで、将来削除して構わない。
public struct AppInfo: Sendable, Equatable {
    /// このホストアプリの名称。project.yml の ContentView にも同じ文字列を表示し、
    /// XcodeGen 生成後のアプリが正しく起動していることを目視確認できるようにしている。
    public static let name = "MCPHost"

    public init() {}
}
