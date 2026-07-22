// MCP endpoint の build configuration 差を Features の一箇所に閉じ込める。
//
// Kernel の MCPEndpointPolicy は Debug/Release を知らない純関数であり、平文 loopback を許すかは
// 呼び出し側が明示注入する。ここを唯一の組み立て地点にすることで、フォームだけ緩めて接続境界が
// 拒否する、または Release まで誤って緩める、といった設定ドリフトを防ぐ。
import Foundation
import Kernel

enum MCPHostBuildPolicy {
    /// Simulator から Mac 上の開発 MCP へ接続する用途だけに使う。
    /// Release ではコンパイル時に false となり、実行時設定や UserDefaults で上書きできない。
    static let allowInsecureLoopback: Bool = {
        #if DEBUG
            true
        #else
            false
        #endif
    }()

    static func resolveEndpoint(_ urlString: String) -> Result<URL, MCPEndpointPolicy.Rejection> {
        MCPEndpointPolicy.resolve(
            urlString: urlString,
            allowInsecureLoopback: allowInsecureLoopback
        )
    }
}
