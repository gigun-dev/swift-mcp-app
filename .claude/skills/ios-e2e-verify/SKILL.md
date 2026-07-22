---
name: ios-e2e-verify
description: iOS シミュレータで MCPHost を E2E 検証する手順とハマりどころ。ビルド〜起動〜画面操作〜ログ裏取りの一連、スパイクハーネス(MCPHOST_SPIKE)の使い分け、実credentialと使い捨てtest credentialの安全な扱い、OAuthのagent入力、タップ座標系、入力・削除のfallback、caldav本番のデプロイ状態確認まで。「シミュレータで確認して」「E2E 検証して」「実機未検証を消化して」「アプリを動かして」と言われたとき、および画面を見て挙動を確かめる必要があるときに読む。
---

# iOS シミュレータ E2E 検証

MCPHost をシミュレータで動かして挙動を確かめるときの手順書。**推測で報告しないための道具立て**が主眼で、
「何をどう叩けば事実が取れるか」と「過去に踏んだ落とし穴」を残す。

## 0. 前提の確認(ここを飛ばすと無駄足になる)

**caldav 本番のデプロイ状態**を先に確認する。ホスト側が正しくてもサーバーが該当 HTML を
配信していなければカードは出ない。Cloudflare Workers Builds の MCP ツールで照会できる:

1. `workers_list`(account: gigun-dev = `4b00d8d779cdc4e8fbc1840248d21722`)で worker の id を取る
2. `workers_builds_set_active_worker` → `workers_builds_list_builds`
3. 最新ビルドの `commitHash` が caldav ローカルの HEAD と一致するか、`buildOutcome` が success か

caldav は push すれば Workers Builds が自動デプロイする。ローカルに未 push のコミットがあれば
それは本番に無い。

## 1. ビルドと起動

Xcode プロジェクトは XcodeGen 生成物で git 管理外。無ければ `xcodegen generate`(`make gen`)。

iOS Simulator MCP の `build` は `project_path` に `.xcodeproj`、`scheme` は `MCPHost`。
ビルド完了は `build_status` をポーリングするか、返ってきたログパスを
`until grep -qE "BUILD (SUCCEEDED|FAILED)" <log>; do sleep 5; done` で待つ。

**ユーザーに画面を見せるなら `attach` を先に**呼ぶ(ビルド前でよい。booted なら即開く)。

## 2. 環境変数の渡し方 — `--setenv` は使えない

この環境の `simctl launch` は `--setenv` を受け付けず `Invalid device: --setenv` になる。
**`SIMCTL_CHILD_` プレフィックス**を使う:

```bash
SIMCTL_CHILD_MCPHOST_SPIKE=reparent xcrun simctl launch --terminate-running-process <udid> dev.gigun.mcphost
```

複数渡すときは `SIMCTL_CHILD_A=1 SIMCTL_CHILD_B=2 ...` と並べる。

### 使える環境変数(`Sources/Features/MCPHostApp.swift` / `LLMSettingsStore.swift`)

| 変数 | 効果 |
| --- | --- |
| `MCPHOST_SPIKE` | `transport` / `todos` / `reparent` のハーネスへ直行 |
| `MCPHOST_LLM_KEY` | LLM API キー。**env > Keychain > 空** の優先順で読む |
| `MCPHOST_LLM_BASEURL` / `MCPHOST_LLM_MODEL` | 同上(env > UserDefaults > 既定) |
| `MCPHOST_AUTOCONNECT` | 自動接続(M2 以降は無言自動接続が既定なので通常は不要) |
| `MCPHOST_SIDEBAR_OPEN` | 起動時サイドバー展開 |

## 3. 資格情報を安全に扱う

credentialを一律に人手へ戻さない。次の境界で判断する。

- **入力してよい**: ユーザーが値と用途を明示した、失効可能なtest fixture / disposable credential。
  現在のcaldav OAuth E2Eでは`changeme`を検証用passwordとしてagentが入力してよい。
- **入力しない**: 実パスワード、個人credential、LLM API key、用途や環境が不明な値。
  env / Keychain経路を使うか、値を扱う1操作だけユーザーへ依頼する。
- test credentialでも必要なfieldへだけ入力し、最終報告やスクリーンショットへ値を転載しない。
  「test credentialを入力可」を「任意の秘密を入力可」へ拡大解釈しない。

- **`make run` が最短**(推奨)。`.env`(gitignore 済み)に `MCPHOST_LLM_KEY=sk-...` を
  1度書いておけば、ビルド → install → **鍵入りで launch** まで一発。人手も貼り付けも要らない。
  `MCPHOST_SPIKE=todos` のようにスパイク指定も `.env` に書ける。専用端末でのE2Eは名前でなく
  **`make run SIMULATOR_UDID=<udid>`** を使い、build/install/launchの配送先を同じUDIDへ固定する。
  同名Simulatorが複数ある状態で名前指定すると`make run`は候補を表示して停止する。
  `make app`はgeneric無署名buildだが、`make run`はKeychain entitlementを使えるよう署名する。
  runを無署名化するとtoken保存が`-34018`となり、再起動後の無言接続を誤って失敗させる。
  値が空の変数は渡さない実装になっている点が重要 — `LLMSettingsStore` は
  `env[...] ?? Keychain ?? ""` の順で**空文字も「値あり」と見なす**ため、空を渡すと
  Keychain 保存済みの鍵が無視される。手で `simctl launch` するときも同じ罠を踏まないこと。
  人間のターミナルでは `.envrc`(direnv)が `.env` を自動で取り込む。
- **LLM API キー(手動で渡す場合)**: `SIMCTL_CHILD_MCPHOST_LLM_KEY=sk-...` で起動すれば貼り付け不要。
  設定画面のキー欄に値が入った状態で立ち上がる(2026-07-22 にダミーキーで実証済み)。
  ただし env は `init` でしか読まれないので**起動ごとに渡す**必要がある
  (設定画面で「保存」を押せばその時点の値が Keychain に入る)。
  キーを含むコマンドはユーザー自身に実行してもらうこと。
- **シミュレータへのペースト**: どうしても貼り付けたいなら
  `echo -n "<値>" | xcrun simctl pbcopy <udid>` でホストのペーストボードを流し込める。
  ただしシェル履歴に残るので機密には向かない。env 経路を優先する。
- **OAuth**: caldavは同意画面でpasswordを求める。E2Eではsemantic snapshot / accessibility treeで
  password fieldを特定し、明示されたtest fixture `changeme`をagentが入力してsubmitまで進める。
  callbackでMCPHostへ復帰してreadyになること、実tool call、terminate / relaunch後にブラウザを
  出さずKeychain tokenで**無言自動接続**することまで確認して初めてOAuth完走とする。
  `tdr-concierge` は **OAuth 不要**なので、認証を挟まない2台目検証の相方に使える。

## 4. 画面操作の落とし穴

### 座標系が2つある

`screenshot` は **918px 幅**で返るが、`tap`/`swipe` は **402x874 ポイント空間**。
スクリーンショット上の座標を **約 2.284 で割って**渡す。これを忘れると明後日の場所を叩く。

### 操作backendを能力順に選ぶ

1. XcodeBuildMCPが使える場合はsemantic snapshotのelement refと`tap` / `type-text` /
   `key-press` / `key-sequence`を優先する。画面遷移後はrefを使い回さずsnapshotを更新する。
2. semantic treeが隠れたNavigationStackを混ぜる、またはWKWebView内を十分に露出しない場合は
   `idb ui describe-all`の表示中labelとframeへfallbackする。
3. 最後にscreenshotとpoint座標を使う。固定座標だけを成功根拠にしない。

XcodeBuildMCPのsnapshotは、閉じたdrawerの検索欄など**画面上は非表示の要素もtargetへ混ぜる**。
`text-field`のような曖昧patternは使わず、composerならplaceholderの`メッセージを入力…`まで含める。
操作後は必ず画面または値を再取得し、背後の要素へ誤入力していないことを確認する。

旧Simulator `control` backendだけを使う場合、actionは attach / launch / screenshot / tap / swipe /
touch_path / touch2_path / text / button / open_url / detach に限られる。

**`key` も `double_click` も `triple_click` も `zoom` も無い**。
待機は `wait` ではなく Bash 側で `until false; do sleep N; break; done`(素の `sleep` は harness に弾かれる)。

### 日本語が打てない + かな入力モードに化ける

`text` は **printable ASCII と改行しか送れない**。日本語を渡すと "0 文字入力(19 文字を drop)" になる。

さらに厄介なのは、シミュレータのキーボードが**日本語入力モードだと ASCII すらローマ字変換される**こと。
`What are...` と送ると「うぁたれてぇ…」になる。回避策:

- 変換候補バーをタップして確定する(**スペースは失われる**が、LLM 相手なら意味は通る)
- 日本語を入れたいなら `echo -n "文字列" | xcrun simctl pbcopy <udid>` でクリップボード経由
  (ただし長押しペーストのメニューを出すのが難しい)
- 検証用の発話は**最初から英語で組み立てる**のが結局いちばん速い

### backendによってはテキストを削除できない

旧`control.text`はカーソル位置に**挿入**するだけでbackspaceを送れない。XcodeBuildMCPの
`key-press` / `key-sequence`で削除・全選択・置換を先に試し、使えない場合だけ次へfallbackする:

- そのエントリを削除して作り直す(詳細画面に「このサーバーを削除」がある)
- `touch_path` の長押しで選択メニューを狙う(成功率は低い)
- ユーザーに1操作だけ頼む

なお `ConnectHardwareKeyboard` が false でもソフトキーボードが画面に出ないことがある。
**focus は当たっていて `text` は通る**ので、キーボードが見えないことを「入力できない」と誤認しないこと
(2026-07-22 にこれを誤認して遠回りした)。

## 5. スパイクハーネス — LLM も認証も無しで検証できる範囲

チャット経由(LLM がツールを叩く)は API キーが要るが、スパイクは要らない。**まずスパイクで済むか考える。**

| `MCPHOST_SPIKE` | 何が検証できるか | MCP 接続 |
| --- | --- | --- |
| `reparent` | fullscreen 昇格の reparent 順序・JS 状態保持(「右上ズレ」の根因) | **不要** |
| `todos` | caldav 本番の実カード描画・カード内操作の往復 | 要(Keychain トークン) |
| `transport` | postMessage ブリッジの疎通 | 不要 |

### reparent スパイクの読み方

判定は「**同一 WebView が reparent されたか**」= JS 状態の連続性。
自動 tick は 100ms 毎に進み**リロードで 0 に戻る**ので、これが決定的な証拠になる。

合格の形: `probe(inline)` → 未コミット入力を足す → 昇格 → **sheet 直前と直後の tick が同値**
(リロードが挟まっていない)→ sheet 内で操作 → dismiss 後にその操作が inline に残っている。

スパイク画面は FullscreenCoordinator を持たないので、カードの ⊕ は
**inline フォールバックになるのが正しい**(昇格しないことを不具合と誤認しない)。
「⊕ が常時 fullscreen 昇格する」ことの確認は通常チャットでしかできない。

## 6. ログで裏取りする

画面だけで判断せず unified log を突き合わせる。subsystem は `dev.gigun.mcphost`:

```bash
xcrun simctl spawn <udid> log show --predicate 'subsystem == "dev.gigun.mcphost"' --last 10m --style compact
```

カテゴリ例: `reparent-spike`(PROBE 行に JS 状態が出る)、`llm-settings`、`open-link`。

fullscreen作成flowは`appssession`の`request-display-mode`と`host-context-changed mode=fullscreen`を
時系列で確認する。成功応答後のfocusだけでなく、実WKWebView reparent後もkeyboard accessoryまたは
入力focusが安定して残ることを確認する。show直後にhideする場合はカードDOMを疑う前に、ホストが
display modeの成功を実presentationより先に返していないかを調べる。

## 7. 報告の作法

- スクリーンショットは証拠。**数値やバッジの文言をそのまま引用**して報告する。
- 「検証した」と書けるのは実際に叩いた経路だけ。スパイクで見たなら
  「器の側を確認した / 実カードは未確認」と範囲を明示する。
- 区切りごとに `docs/next-directions.md`(正典・打ち消し線 + `> 日付 更新:` を積層)と
  `docs/log.md`(追記専用)を更新する。**誤って書いた事実は撤回を明記して直す**。
