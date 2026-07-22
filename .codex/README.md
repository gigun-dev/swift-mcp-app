# Claude Code / Codex 共有ハーネス

Claude Code 側を正典にし、同じ内容を表現できる Codex surface は symlink で共有する。

| Codex | 正典 | 方式 |
| --- | --- | --- |
| `AGENTS.md` | `CLAUDE.md` | symlink |
| `.agents/skills/ios-e2e-verify` | `.claude/skills/ios-e2e-verify` | symlink |
| `Sources/AGENTS.md` / `Tests/AGENTS.md` | `.claude/rules/comments.md` | symlink |
| `.codex/hooks/session-start.sh` | `.claude/hooks/session-start.sh` | symlink |

`ios-simulator`(user plugin)は Simulator の汎用 CLI 操作、`ios-e2e-verify`(project skill)は
MCPHost 固有のビルド・起動・認証回避・ログ裏取りを担当する。重複ではないため両方を残す。

次の2ファイルは Claude Code と Codex で設定形式が異なるため、薄い Codex 専用 adapter として管理する。

- `.codex/hooks.json`: Claude の SessionStart hook を Codex の lifecycle hook 形式で呼ぶ。
- `.codex/config.toml`: hook の有効化と `xcode-mcp@gigun` 内の `xcrun mcpbridge` を定義する。

## 保守

- 共通 instruction、skill、コメント規約、hook script は `.claude` 側だけを編集する。
- `.claude/settings.json` の hook matcher や Xcode plugin の MCP 定義を変えた場合は、Codex adapter にも同じ意図を反映する。
- Codex は新規または変更された project hook を初回実行前に信頼確認する。必要なら Codex CLI の `/hooks` で確認する。
- `.claude/settings.local.json` のローカル permission allowlist は移植しない。Codex の permission profile / sandbox は実行環境側で管理する。
- セッションの現在地は `docs/next-directions.md` の最初の `session-head-end` までを注入する。
  詳細履歴は同ファイル後段と `docs/log.md` を必要時だけ読む。Claude project memory 自体は
  機械依存なので symlink せず、恒久化すべき内容だけを repository の instructions/docs/skills に昇格する。
