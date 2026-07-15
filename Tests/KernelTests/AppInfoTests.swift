// swift-testing を使う(CLAUDE.md「テストは Tests/KernelTests/, Tests/ServicesTests/
// (swift-testing を使用)」の指定)。XCTest ではなく @Test マクロベースの新フレームワーク。
import Testing
@testable import Kernel

@Test("AppInfo.name はホストアプリ名 MCPHost を返す")
func appInfoNameIsMCPHost() {
    #expect(AppInfo.name == "MCPHost")
}
