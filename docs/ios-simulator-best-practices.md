# iOS Simulator 検証 — どれをいつ読むか(索引)

> **この文書の役割(2026-08-02 に全面縮小):** 以前はここに「Codex 非依存化の判断」と
> 「Simulator 操作の標準手順」が同居していた。後者は**共有スキルと project skill に同じことが
> 書いてあり**、2026-08-01 の実走行では agent が最初の生産的な操作へ到達する前に
> **約 37,600 tokens** の重複資料を読んでいた(しかも一部は古く、誤った手段へ誘導した)。
> → **操作手順は本文書に持たない。** ここは**行き先だけ**を示す索引にする。
> 退避先: 判断記録は
> [`archive/ios-agent-harness-codex-independence-2026-07-23.md`](archive/ios-agent-harness-codex-independence-2026-07-23.md)。

## 行き先(上から順に、必要になった時点でだけ読む)

| いつ | 何を読む |
| --- | --- |
| **Simulator に最初の1手を撃つ前**(`idb`/`simctl` を叩く前) | 共有スキル **`ios-simulator`**(personal scope・`ios-skills` プラグイン)の**「事前チェック」**。システムプロキシとソフトキーボードを確認せずに始めると、以降の観測がすべて無効になる |
| **「Simulator を触らずに済ませられないか」を決める時** | 同スキルの**「棲み分け」表** + `references/state-provisioning.md`(env 注入・`simctl clone`)。状態はタップで作らない |
| **カード HTML の描画・DOM 操作を確かめたい時** | 同スキル `references/webview-offload.md`。WKWebView の中身は**ブラウザへ引き剥がす**のが速い |
| **MCPHost を E2E 検証する時**(ビルド・env・資格情報・スパイク・ログ裏取り) | project skill **`.claude/skills/ios-e2e-verify/SKILL.md`**。MCPHost 固有分の正典 |
| **画面操作を実際に回す時** | `.claude/agents/simulator-operator.md`(sonnet)へ委譲。main のコンテキストをスクショで汚さない |
| **ツールの採否・版を変えたくなった時**(Codex plugin / XcodeBuildMCP / Apple Xcode MCP) | [`archive/ios-agent-harness-codex-independence-2026-07-23.md`](archive/ios-agent-harness-codex-independence-2026-07-23.md)(判断の Why)、実測は [`ios-agent-harness-benchmark.md`](ios-agent-harness-benchmark.md)、出典は [`codex-plugin-and-ios-agent-audit.md`](codex-plugin-and-ios-agent-audit.md) |
| **未検証の製品挙動が何か知りたい時** | [`next-directions.md`](next-directions.md) の「実操作チェックリスト」(残件の正典はここ一箇所) |

## ここだけに書く repo 標準(1行ずつ)

- 配送先は**必ず UDID 固定**: `make run SIMULATOR_UDID=<UDID>`(build / install / launch を同じ端末へ)。
  名前指定は一意に解決できる時だけ。`make app` は無署名 generic build、`make run` は署名する
  (無署名だと Keychain が `-34018` になり、再起動後の無言接続を誤って失敗と判定する)。
- push 前 gate は `make verify`。**build / test だけで目的を満たすなら Simulator を操作しない。**
- 日常利用中の Simulator を erase しない。検証は専用端末で行う。

> **Why not すべてを skill へ寄せないか:** 上の3行は CLAUDE.md「技術スタック」にも書いてある
> (常時ロードされる側が正)。ここに残しているのは**索引だけの文書にすると
> 「結局どのコマンドで動かすんだっけ」で CLAUDE.md へ戻る往復が1回増える**ため。
> 逆に、操作手順・座標系・IME・状態注入は**絶対にここへ書き戻さない** —— それが
> 6本の情報源に分裂した経緯そのもの。
