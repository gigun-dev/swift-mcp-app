// swift-tools-version:5.9
import PackageDescription

// このリポジトリのロジック層(Kernel/Services)をローカル SwiftPM パッケージとして切り出している。
// 理由: `swift test` が Xcode を経由せず CLI から直接回せるため、`make check` で
// ビルド/テストを CI いらずに高速検証できる(docs/next-directions.md 2026-07-15
// 「雛形: XcodeGen + Kernel/Services はローカル SwiftPM パッケージ」の決定)。
// アプリターゲット(MCPHost, SwiftUI)は XcodeGen(project.yml)側で定義し、
// このパッケージを `path: .` のローカル依存として取り込む。
// .xcodeproj 自体は生成物なので git 管理しない(.gitignore 参照。理由は project.yml のコメントへ)。
let package = Package(
    name: "MCPHostKernel",
    // iOS 17+ はこのアプリの最小 OS(next-directions.md で確定・授業指定なし前提)。
    // macOS 14+ を並記しているのは iOS シミュレータ/実機なしでも
    // `swift build` / `swift test` をこの Mac 上でそのまま実行できるようにするため
    // (SwiftPM はプラットフォームリストの先頭だけでなく実行環境に合うものを選ぶ)。
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "Kernel", targets: ["Kernel"]),
        .library(name: "Services", targets: ["Services"]),
    ],
    dependencies: [
        // MCP クライアント実装。0.12.1 は clone 済みローカルリポジトリ
        // (~/ghq/github.com/modelcontextprotocol/swift-sdk)で確認した最新タグ
        // (2026-07-15 時点)。`from:` にしているのでパッチ更新は自動追従する。
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.12.1"),
    ],
    targets: [
        // Kernel: MCP DTO の Codable・日付/繰り返し整形・セクショニングを置く純関数層。
        // caldav 側の ui/ 純関数群(docs/modeling/12 が契約の正)に対応づける想定なので、
        // ここには外部依存(swift-sdk・UIKit・SwiftUI)を一切持ち込まない
        // (CLAUDE.md「Kernel はプラットフォーム非依存」)。
        .target(name: "Kernel", dependencies: []),
        .testTarget(name: "KernelTests", dependencies: ["Kernel"]),

        // Services: MCP クライアント(接続・OAuth・tools/call)・LLM オーケストレータ・Keychain。
        // swift-sdk と Kernel に依存する(Kernel の DTO をそのまま MCP レスポンスのデコード先に使う)。
        .target(
            name: "Services",
            dependencies: [
                "Kernel",
                // package 引数は swift-sdk の Package.swift 内の宣言名(name: "mcp-swift-sdk")
                // ではなく、SwiftPM が `.package(url:)` から自動導出するパッケージ識別子
                // (リポジトリ URL の最終パスセグメント "swift-sdk")を指定する必要がある
                // (実際に "mcp-swift-sdk" を指定すると `swift build` が
                // "unknown package 'mcp-swift-sdk'" で失敗することを確認済み)。
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(name: "ServicesTests", dependencies: ["Services"]),
    ]
)
