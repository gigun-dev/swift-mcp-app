// ナビゲーション中央のモデル名と MCP サーバー状態メニュー。
// ChatHomeView は画面ルーティング、ここはサーバー状態の説明と操作だけを担当する。
import SwiftUI
import Services

struct ServerStatusMenu: View {
    let settings: LLMSettingsStore
    let registry: ServerRegistryStore
    let home: ChatHomeViewModel
    let onOpenSettings: () -> Void

    var body: some View {
        Menu {
            ForEach(registry.servers) { entry in serverMenuRow(entry) }
            Divider()
            Button(action: onOpenSettings) {
                Label("サーバーを管理・設定", systemImage: "gearshape")
            }
        } label: {
            HStack(spacing: 3) {
                // 平時はモデル名だけ。異常は形でも識別できる三角アイコンを1つ添える。
                if let banner = attentionBanner {
                    Image(systemName: banner.symbol).font(.caption).foregroundStyle(banner.tint)
                }
                Text(settings.model).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(attentionBanner.map { "\($0.accessibilityLabel)。モデル \(settings.model)" }
                ?? "モデル \(settings.model)。タップしてサーバー一覧を開く")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func serverMenuRow(_ entry: MCPServerEntry) -> some View {
        let state = home.connections.state(for: entry.id)
        Button {
            // 認証・失敗は直接復帰を試し、それ以外は設定で管理する。
            switch state {
            case .needsAuth, .failed:
                home.connectInteractively(serverID: entry.id)
            case .ready, .connecting, .disconnected:
                onOpenSettings()
            }
        } label: {
            Label(menuLabel(for: entry, state: state), systemImage: menuIcon(for: entry, state: state))
        }
    }

    private func menuLabel(for entry: MCPServerEntry, state: ConnectionsManager.State) -> String {
        if !entry.enabled { return "\(entry.name)(無効)" }
        switch state {
        case .ready: return entry.name
        case .connecting: return "\(entry.name)(接続中…)"
        case .needsAuth: return "\(entry.name)(要認証・タップ)"
        case .failed: return "\(entry.name)(接続失敗・タップで再試行)"
        case .disconnected: return entry.name
        }
    }

    private func menuIcon(for entry: MCPServerEntry, state: ConnectionsManager.State) -> String {
        if !entry.enabled { return "circle.slash" }
        switch state {
        case .ready: return "checkmark.circle.fill"
        case .connecting: return "hourglass"
        case .needsAuth: return "exclamationmark.circle"
        case .failed: return "xmark.circle"
        case .disconnected: return "circle"
        }
    }

    /// 正常状態は常設表示せず、ユーザー操作が必要なときだけ作る警告モデル。
    private struct AttentionBanner {
        let symbol: String
        let tint: Color
        let accessibilityLabel: String
    }

    private var attentionBanner: AttentionBanner? {
        let enabled = registry.servers.filter(\.enabled)
        // 有効サーバー0件はツールが使えない理由が会話側から分からないため、サイレントにしない。
        if enabled.isEmpty {
            return AttentionBanner(
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                accessibilityLabel: "MCP サーバーが登録されていません。タップして設定を開く"
            )
        }
        var needsAuth = 0
        var failed = 0
        for entry in enabled {
            switch home.connections.state(for: entry.id) {
            case .needsAuth: needsAuth += 1
            case .failed: failed += 1
            case .ready, .connecting, .disconnected: break
            }
        }
        let total = needsAuth + failed
        guard total > 0 else { return nil }
        let voice: String
        if failed == 0 {
            voice = "\(total) 件のサーバーが要認証。タップして一覧を開く"
        } else if needsAuth == 0 {
            voice = "\(total) 件のサーバーが接続失敗。タップして一覧を開く"
        } else {
            voice = "\(total) 件のサーバーが要対応。タップして一覧を開く"
        }
        return AttentionBanner(
            symbol: "exclamationmark.triangle.fill",
            tint: .orange,
            accessibilityLabel: voice
        )
    }
}
