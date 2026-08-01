---
name: ios-e2e-verify
description: iOS シミュレータで MCPHost を E2E 検証する手順とハマりどころ。ビルド〜起動〜画面操作〜ログ裏取りの一連、スパイクハーネス(MCPHOST_SPIKE)の使い分け、実credentialと使い捨てtest credentialの安全な扱い、OAuthのagent入力、タップ座標系、入力・削除のfallback、caldav本番のデプロイ状態確認まで。「シミュレータで確認して」「E2E 検証して」「実機未検証を消化して」「アプリを動かして」と言われたとき、および画面を見て挙動を確かめる必要があるときに読む。
---

# iOS シミュレータ E2E 検証

MCPHost をシミュレータで動かして挙動を確かめるときの手順書。**推測で報告しないための道具立て**が主眼で、
「何をどう叩けば事実が取れるか」と「過去に踏んだ落とし穴」を残す。

> **本スキルは MCPHost 固有分だけを持つ。** 汎用の規律 —— 複数 Booted の事故・`idb ui tap` の
> 無言失敗・座標系(pt = px ÷ scale)・IME 化けと `simctl pbcopy`・スクショの出力先・
> 状態の env 注入・WKWebView をブラウザへ引き剥がす判断 —— は**すべて共有スキル `ios-simulator`
> (personal scope・`ios-skills` プラグイン)が原典**で、ここには重複させない。
> 特に「**WKWebView の中身はブラウザで検証する**」は、**カード HTML の描画・DOM 操作を
> 確かめたくなった時点で**読むこと —— Simulator 操作そのものが要らなくなることがある。

## 0. 前提の確認 — **1 から順に、Simulator に最初の1手を撃つ前に**

> **⚠️ この節は「読む」ものではなく「実行する」もの。** 2026-08-02 の実走行で、
> エージェントは上のポインタを読んだうえで **1 を飛ばし、7分目にプロキシ問題へ突っ込んだ**
> (本人の弁: *「していれば1分目に気づいていた」*)。原因は3つあり、すべてこの節の構造の問題だった:
> **①チェックがコマンドではなくポインタだった**(実行するのに別スキルをロードする一手が要り、
> 時間に追われると「後回しにできるもの」に読める)/ **②「前提」を名乗る節の中身が
> 別の前提(deploy 状況)だけだった**ので、それをやって「前提は満たした」と感じた /
> **③失敗のシグネチャ(`-1200` / `Proxyman`)が本文に無く grep で当たらなかった**。
> → だから **1 をこの節の先頭に、コマンドごと**置いてある。ポインタに戻さないこと。

### 1. 🔴 ホストのシステムプロキシ(飛ばすと以降の観測が全部無効になる)

```bash
scutil --proxy | grep -E 'HTTPSEnable|HTTPSProxy|HTTPSPort'
#   HTTPSEnable : 1  かつ  HTTPSProxy : 127.0.0.1  なら → 全 Simulator の HTTPS が MITM される
pgrep -lf 'Proxyman|Charles|mitmproxy'
defaults read com.apple.iphonesimulator ConnectHardwareKeyboard   # 1 ならソフトキーボードが出ない
```

**新品/CA 未投入の Simulator はそのルート CA を信頼していないので、HTTPS だけが静かに落ちる。**
この失敗はこう見える(**この文字列で grep できるように原文のまま置く**):

```
無言接続 失敗 https://caldav.gigun-dev.workers.dev/mcp:
  NSURLErrorDomain Code=-1200 "A TLS error caused the secure connection to fail."
# Safari で開くと: 接続はプライベートではありません / サーバの識別情報を検証できません
```

対処は**その端末にだけ CA を入れる**(ホストのプロキシ設定は触らない。切ると進行中のキャプチャが死ぬ):

```bash
<ios-simulator スキル>/scripts/sim-trust-ca.sh --udid <UDID>    # 冪等・--dry-run あり
# 素で撃つなら: xcrun simctl keychain <UDID> add-root-cert "$HOME/Library/Application Support/com.proxyman.NSProxy/app-data/proxyman-ca.pem"
```

⚠️ **`make run` が成功してアプリが起動しても、ネットワーク信頼については何も分からない。**
ビルドが緑なことが「順調だ」という誤った手応えを作る(実走行でまさにこれが起きた)。
⚠️ **CA はローテーションする。更新されると、以前 CA を入れた端末が全部だまって無効になる**
(2026-07-23 に OAuth を完了した端末が今回 `要認証` に戻っていたのは、おそらくこれ)。

### 2. caldav 本番のデプロイ状態

ホスト側が正しくてもサーバーが該当 HTML を配信していなければカードは出ない。
Cloudflare Workers Builds の MCP ツールで照会する:

1. `workers_list`(account: gigun-dev = `4b00d8d779cdc4e8fbc1840248d21722`)で worker の id を取る
2. `workers_builds_set_active_worker` → `workers_builds_list_builds`
3. 最新ビルドの `commitHash` が caldav ローカルの HEAD と一致するか、`buildOutcome` が success か

caldav は push すれば Workers Builds が自動デプロイする。ローカルに未 push のコミットがあれば
それは本番に無い。

### 3. 🔴 タップは1コマンドにまとめる(往復がコスト。idb は速い)

**実測: `idb ui tap` は 0.08 秒、`describe-all` は 0.14〜0.28 秒、5連続タップを1コマンドで 0.46 秒。**
遅いのは idb ではなく**ツール呼び出しの往復**。1タップごとに Bash を1往復すると、
**3タップで数分**が溶ける(実走行で「idb が 110 秒/タップ」と報告されたが、
これは実測ではなく往復コストの誤帰属だった —— 再測定で否定済み)。

```bash
# ✅ 画面遷移のひとまとまりを1コマンドで撃ち、最後に1枚撮って結果を見る
U=<UDID>
idb ui tap --udid "$U" 201 337 && sleep 0.4 && \
idb ui tap --udid "$U" 201 420 && sleep 0.4 && \
idb ui tap --udid "$U" 180 512 && sleep 0.4 && \
xcrun simctl io "$U" screenshot ~/tmp-sim/after.png
```

> ⚠️ **座標を変数に入れて回すループは zsh で壊れる。** `for c in "201 337"; do idb ui tap $U $c` は
> bash なら2引数に割れるが、**zsh は引用符なしの変数展開を単語分割しない**ので `"201 337"` が
> 1引数のまま渡り、タップが実行されない。しかも **stderr を捨てていると無言で失敗したように見え、
> 「座標が古くなった」と誤診する**(実際にこのセッションで起きた)。
> 座標を配列で回すなら `coords=(201 337 201 420)` のように**数値を平坦に**持ち、2つずつ取り出すこと。

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

> **タップで状態を作りそうになったら**、共有スキルの `references/state-provisioning.md` §1 を先に読む
> (env 注入の一次資料・URL スキーム・「env が効いたと誤認する落とし穴」= フラグを外して
> 同じ結果にならないことを A/B で取れ、まで書いてある)。下の env 表は MCPHost 側の実装分。

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

## 4. 画面操作の落とし穴(MCPHost 固有分)

汎用の落とし穴(タップの無言失敗・`frame:{0,0,0,0}`・IME 化け・キーボードが出ない・
デバイス所有権の衝突)は共有スキル `ios-simulator` の「★最重要ハマりどころ」を読むこと。
ここに残すのは**このアプリでしか踏まないもの**だけ。

### 座標系: 固定の除数(2.284)を信じない

`tap`/`swipe` は **402pt 幅**の空間だが、スクショは環境によって 918px だったり 920px だったりする
(元解像度 1206px の端末で実測)。**表示幅 / 402 をその都度計算する**か、共有スキルの
`scripts/sim-shot.sh`(pixel 実寸・point 実寸・scale を毎回出す)に出させる。
> 2026-07-23: 「918px / 2.284 固定」と思い込んで外した。**倍率は端末・表示スケールで変わる**ので、
> このスキルに固定値を書き戻さないこと(それが誤誘導の元だった)。

### semantic snapshot は「画面に出ていない要素」も target に混ぜる

XcodeBuildMCP のスナップショットは、**閉じた drawer の検索欄**のような非表示要素まで返す。
`text-field` のような曖昧 pattern で撃つと背後の要素へ入力してしまう。composer を狙うなら
placeholder の `メッセージを入力…` まで含めて特定し、操作後は必ず画面か値を再取得して確認する。
(操作 backend の優先順 —— semantic ref → `describe-all` の label/frame → 座標 —— は
共有スキルの「棲み分け」表が原典。)

### LLM への発話は最初から英語で組み立てる

IME 化けの回避策(`pbcopy` / Caps Lock / ASCII プローブ)は共有スキル側。**MCPHost 固有の判断**は、
検証発話は意味が通れば十分なので日本語を通すコストに見合わない、ということ。
一方**カード内の日本語入力(TODO タイトル等)は値そのものが検証対象**なので `pbcopy` で正確に入れる。

### 入力を消せない backend を踏んだときの逃げ道

既存の入力を削除できないときは、**サーバー詳細画面の「このサーバーを削除」でエントリごと作り直す**
のが最短(接続設定は再入力しても数秒)。長押しで選択メニューを狙うより成功率が高い。

### 待機に素の `sleep` を使わない(エージェント実行環境の制約)

Claude Code の harness は素の `sleep` を弾く。`d=0; until [ $d -eq 1 ]; do sleep N; d=1; done`
の形にする(共有スキルのコード例は素の `sleep` で書かれているが、**この環境ではそのままでは通らない**)。
ポーリング待ちが要るだけなら共有スキルの `scripts/sim-wait.py` を使うほうが速い。

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

### tap は idb を使う(`xcrun simctl ui` に tap は無い)

`xcrun simctl ui <udid>` のサブコマンドは appearance / increase_contrast / content_size だけで、
**tap / text は存在しない**(usage を出して終了コード0で成功したように見えるのが罠)。
座標タップとASCII入力は `idb ui tap --udid <udid> <x> <y>` / `idb ui text --udid <udid> "..."` を使う。
`simctl ... || idb ...` のフォールバック連結は「simctl が静かに usage を吐いて成功扱い」になる
場合に idb が呼ばれず空振りするので、最初から idb を書く。

> **Why not 共有スキルへ委譲しないか**: これは MCPHost 固有ではなく汎用の罠だが、
> 2026-08-02 時点の共有スキル `ios-simulator` にこの記述が**無い**ので、ここに置いたままにする。
> 共有スキル側に入ったら**本節は消してポインタに畳むこと**(重複させない)。

### OAuth 同意フローの実測(2026-07-23・Harness A で一発完走)

「認証して接続」→ ASWebAuthenticationSession で同意ページ(読み込み〜4秒)→ password 欄は
**自動 focus 済み**なので `idb ui text` で即入力できる → 「許可する」タップ → コールバック復帰 →
🔴 **ただし「許可する」の座標を、パスワード入力の前に取ってはいけない**(2026-08-02 実測)。
**入力でキーボードが出るとページがスクロールし、ボタンが pt(66,498) → pt(66,436) へ動く。**
入力を終えてから座標を取り直すこと。取り直さないと1タップ空振りする(実際に踏んだ)。
座標を読み直してから撃つのは `sim-nav.py` が構造的にやっていることでもある。
ログ `対話接続 成功 ... tools=N` で完走確認。全体約1分・人手ゼロ。
(このとき踏んだスクショ倍率の罠は §4「座標系」へ集約した。)

> **⚠️ 「Harness A は OAuth 済みなので無言再接続できる」と読まないこと(2026-08-02 訂正)。**
> 上は**2026-07-23 時点の記録**。同じ端末が 2026-08-02 には `要認証` に戻っていた
> (Keychain の token が無効化されていた。§0-1 の CA ローテーションが原因と見ている)。
> 実走行では、この記述を根拠に「トークンはあるはず」と見込んで進み、
> **残り時間を使い切ってから OAuth が必要だと分かった**。
> → **無言再接続を当てにしない。** 起動直後にログで `無言接続 成功` / `要認証` の
> どちらが出るかを見て、**同意フローの4タップ+入力ぶんの時間を最初から予算に入れる**。
> 記録自体は消さない(手順は今も正しい)。**変わるのは端末の状態のほうなので、
> 「いつ時点の観測か」を必ず添える。**
