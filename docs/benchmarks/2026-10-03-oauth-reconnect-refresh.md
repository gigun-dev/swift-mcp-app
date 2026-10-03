# OAuth再接続時のclientID復元（2026-10-03）

> 同日0010追補: SDKの503/timeout前clearを標準authorizer wrapperのshadow保存で保護した。
> 旧known issueは通常回帰へ変換。最新の実装・全チェック・残境界は末尾の0010追補が正。
> 前半の5 tests/known issue記録はclientIDだけを直した時点の履歴である。

access tokenはCalDAV既定で3600秒、refreshのgrant期限は既定30日で、refreshしてもgrant期限は延長されない。
この期限だけでは、起動や接続確認のたびに再認可する挙動を説明できない。

## 再現した原因と最小修正

`KeychainTokenStorage`はclientIDも保存する。しかし`MCPConnection.connect`は再接続時にも
`OAuthConfiguration.authentication`を`.none(clientID: "")`で構築し、SDKも保存clientIDを復元しない。
期限切れaccess tokenの401後にrefreshを送ると、空clientIDをCalDAVのOAuth providerが
401 `invalid_client`で拒否する。SDKは4xxをrefresh失敗として扱い、DCRとブラウザ再認可へ進む。

`MCPConnection.tokenEndpointAuthentication`で同じserver URLのstorageからtoken.clientIDを読み、
公開clientの`.none(clientID:)`へ復元するよう変更した。保存token不在なら従来どおり空で始める。
別のrefresh実装・SDK fork・CalDAV固有認証を導入していない。

## 実TCPのローカル回帰

`OAuthReconnectRefreshTests`はPython fake OAuth serverを`127.0.0.1`のport0へ起動する。
AS discovery、protected resource discovery、DCR、token requestを実URLSession/TCPで配送する。
SDKがASへHTTPSを要求するため、test専用URLProtocolはHTTPS loopback URLを同portのHTTPへ転送する。
外部接続とTLSの検証・緩和は行わない。fixtureの転送以外にSDKコードを差し替えていない。
server observationsにはrequest path、grant_type、fixture clientIDだけを記録する。

storageは一時fileを原子更新するfixture。seedを保存したinstanceを捨て、別instanceと新authorizerで再接続し、
交換後もさらに別instanceでtokenを読む。メモリcacheだけで通る試験ではない。
署名済みiOS Keychainの再起動後アクセスを証明するものではなく、その受入は実機に残る。

| 条件 | 期待と観測 |
| --- | --- |
| 旧空clientID＋期限切れtoken | 空clientIDのrefresh失敗、DCR実行、認可delegate1回。元の不備を再現 |
| 保存clientID復元＋期限切れtoken | clientID付きrefresh1回成功、DCR0、delegate0、Bearer新access token |
| 交換後の永続化 | 別storage instanceでrotated refresh tokenと同clientIDを復元 |
| 保存token不在 | 初回DCRと認可delegate1回、code交換成功 |
| 有効token | discovery/refresh/認可要求0、保存access tokenを認可ヘッダへ設定 |
| 正しいclientID＋token endpoint 503 | 認可delegate0でthrow、storageが消失する独立known issueを検出 |

`swift test --filter OAuthReconnectRefreshTests`は5 tests成功、known issue1件。
`make check`成功: Services 195 tests/27 suites（36.393秒、known issue1件）、
Kernel 136 tests/9 suites、SwiftFormat/SwiftLint違反0（180ファイル）。
`git diff --check`も成功。Services testsの全体時間を製品のOAuth/会話latencyと扱わない。

## 独立して残るSDKの一時失敗問題

SDK `OAuthAuthorizer.handleChallenge`は保存refresh tokenをローカル変数へ取った直後に
`tokenStorage.clear()`を呼び、その後discoveryとrefreshを試す。fixtureの503ではtoken交換がthrowし、
新tokenを保存する機会がないため、永続storageに旧refresh tokenが残らない。
これはclientID復元後にも起こり、次回接続では再認可が必要になる。

回帰では本来必要な「503後にも旧refresh tokenを保持」を`withKnownIssue`で検出し、成功扱いと解消を区別した。
今回の証拠は503であり、実回線切断/timeout/-1005を再現したものではない。

修正対象の候補はSDK側の401経路。新token保存成功までclearを遅らせ、一時失敗と恒久的なinvalid_grantの
扱いを分ける必要がある。TokenStorage.clear自体をホストで無視するとAS変更・恒久失効・削除の意味まで
壊すため採らない。SDKの内部実装をvendorせず、upstream修正または標準HTTPClientAuthorizer境界の
明示ラッパを別途検討する。今回このSDK問題は修正していない。

## 受入境界

既存dirtyと性能ベンチを保持。変更はMCPConnectionのclient auth初期値とコメント、追加回帰、専門docsとtodoのみ。
本番認可・実token・実機install/launch・commit・push・deployを操作していない。
端末unlock後に、認可済み接続のaccess期限をまたぐ再起動/再接続でブラウザが出ずMCP要求が成功する受入が残る。
refresh grantの30日期限・取消し・token不在では再認可が必要な仕様を維持する。

## 上書き更新・削除後の再install・再起動の区別

今回の実機配送はアプリ削除を伴わない上書きinstall。上書き更新と再起動・再接続では、
同じアプリ識別子/署名権限/接続URLでKeychainが読める場合に認可を保持するのが本アプリの既定動作。
それをDeviceCheckの端末ビットで代替しない。

現ソースの識別条件:

- `project.yml`のbundle IDは`dev.gigun.mcphost`、development teamは`KK42DL23GH`。
- OAuth Keychain queryはservice `dev.gigun.mcphost.oauth-token`、accountは接続先`serverURL.absoluteString`。
  独自の`kSecAttrAccessGroup`やKeychain Sharing entitlementの指定は確認できず、署名の既定groupで読む。
  署名権限が変わるbuildで既存itemが読めることは、このソース値だけでは保証できない。
- `AfterFirstUnlockThisDeviceOnly`を使用し、iCloud同期を行わない。初回unlock前の可用性や別端末移行は
  通常のアプリ再起動とは条件が違う。
- 起動時にOAuth tokenを一括削除する処理は確認されない。ServerRegistry初期化は旧選択キーの削除と
  未保存/破損時の登録簿seedを行うが、OAuth Keychainをclearしない。
- 接続OFF/再接続の`ConnectionsManager.disconnect`は状態と接続taskを破棄し、保存tokenをclearしない。
  設定のサーバー削除は`ServerRegistry.remove`がそのURLのtokenを明示clearする。
- サーバーURLを変更するとKeychain accountも変わる。`ServerRegistry.update`はtokenの移送を行わず、
  表示名だけの変更と認可先URLの変更は同じ扱いにならない。
- Keychain保存/更新失敗はメモリcacheで続行する。そのプロセス内で動いても、再起動後の保持成功を
  意味しない。保存失敗statusのログがその切り分け材料になる。

削除→再installではアプリの登録簿/UserDefaultsの復元条件も異なる。CalDAV既定URLはseedで戻るが、
任意の追加サーバーと設定は同じではない。Keychain itemの削除後残存を、認可保持の製品契約にはしない。
今回この端末削除試験は行っておらず、「上書きinstallで認可が消えた」原因をアプリ削除へ結び付けない。

[Apple DeviceCheck](https://developer.apple.com/documentation/devicecheck)はApple側に端末ごとの2bitを持ち、
特典利用済みや不正端末などの状態をサーバーから扱う仕組み。OAuthのaccess/refresh token、clientID、
期限・scope・認可先を保存する機構ではない。端末識別が再installをまたげてもOAuth grantの更新は別問題。

## 0010: 標準境界での一時失敗保護案（初回報告時）

`TokenStorage`単独の`save/load/clear`には削除理由・HTTP status・OAuth error・request終了の情報がない。
clearを常に無視すると、恒久失効/認可先の変更/明示削除を処理できない。保存のclassだけで安全に
503と`invalid_grant`を区別する案は採らない。

最小の検討案は標準`HTTPClientAuthorizer` decoratorと、SDK呼出中だけ使うtransactional TokenStorage。
SDKのclearをshadow状態へ適用し、永続層への確定をrequest結果まで遅延する。

| 結果/操作 | 必要な確定動作 |
| --- | --- |
| refresh成功、新token保存 | access/rotated refresh/clientID/expiryを一体でcommit |
| 真の`invalid_grant`後の再認可 | 旧token削除をcommit、既存needsAuth導線へ戻す |
| token endpoint 503/timeout | 永続層を変更せずrollback、SDKのエラーを呼出元へ返す |
| ユーザーの明示削除/ログアウト | SDKのtransaction外から即時clear、進行中更新から復活させない |

SDKが4xxを`false`へ畳むため、decoratorだけでOAuth error原文を取得することはできない。
また失敗した呼出のsnapshotを単純に再saveすると、並行refreshの新tokenや明示削除を上書きしかねない。
commit時の世代確認、明示clearとの共有境界、SDK呼出の直列化を含めて回帰検証が必要。
現KeychainTokenStorageはinstanceごとのcacheなので、別instanceからのclear検知も考慮する。
この案は親レビュー前であり、0010を完了扱いにせず、SDK・ホストをまだ変更していない。

## 同日0010実装・親レビュー後の検証

`PreservingOAuthAuthorizer`は標準`HTTPClientAuthorizer`を実装し、discovery/DCR/PKCE/token交換を
既存SDKへ委譲する。SDKへ渡す`OAuthTransactionalStorage`は呼出中だけshadowを読み書きし、
永続Keychainへのclear/saveを結果まで遅延する。503/URLSession timeout/取消しではshadowを捨てる。
旧snapshotを再saveするrollbackではないので、明示削除や別保存を復活・上書きしない。

同じserverURL.absoluteStringの`OAuthTokenStore`を接続と`ServerRegistry.remove`で共有し、save/clearごとに
世代を更新する。commitの世代が違えば`CancellationError`を呼出元へ伝播し、古い成功結果を保存しない。
同URLのSDK async呼出全体をmutationGateで直列化する。transport actor単独でsingle-flightとした
従来の説明はawait中の再入を見落としていたため、MCPConnectionコメントも訂正した。

ローカル回帰:

- 実loopback OAuth fixtureで503とtimeout後もfile永続層に旧refresh tokenが残る。
  timeout後の再試行では新access/rotated refresh/clientIDを保存し、認可delegateは呼ばれない。
- 真正`invalid_grant`では旧tokenを削除し、確立済みgateがneedsAuthを通知する。ブラウザは開かない。
- 初回認可、有効token、再接続時clientID復元をwrapperに通して非回帰を確認。
- pauseでSDK呼出を止め、同時の明示clear/別saveを挿入。成功commitの世代競合は取消しを伝播し、
  503/timeout rollbackも明示clearや別saveへ干渉しない。
- 同storeの二つのauthorizerはrotationを直列化し、二つ目が一つ目の新refresh tokenを読む。
- 登録簿removeが共有storeをclearし、instance cacheへtokenを残さない。

対象11 tests（parameter casesを含む15ケース）成功、known issue0。
`make check`成功: Services 201 tests/28 suites、Kernel 136 tests/9 suites、
SwiftFormat/SwiftLint違反0（183ファイル）。その後のコメント訂正も対象lintとdiff check成功。
SDK fork/vendoring、独自OAuth protocol、Keychain namespace/保存format変更はない。

保証範囲:

- SDKはrefreshの4xx原因をfalseに畳むため、wrapperは原文を取得できない。真正invalid_grantを確認したが、
  429など全4xxの再分類やbackend障害の自動backoffまで解消したとは扱わない。
- discovery失敗はSDKがHTTP statusを捨てるため原因を断定せず、旧tokenを残してエラーを返す。
- TokenStorage.saveはvoidであり、Keychain保存失敗は従来どおりログとメモリcacheに留まる。
  coordinatorのcommit成功は、署名済み実機でのKeychain永続化成功まで保証する値ではない。
- 明示削除の取消しが伝播した場合に新tokenを広告しないことは回帰で確認した。進行中token endpointが
  backend側で既に処理されたかは、このローカル保存境界だけでは取り消せない。
- DeviceCheckは導入していない。上書きinstall/再起動時の認可保持が目的であり、端末識別は不要。

## 同日実機反映と自動質問の境界

親レビュー後、ios-device-build skillの列挙/dry-runと同じ明示引数で有線iPhone17 morita
（UDID `00008150-000964443A88C01C`）へビルド、上書きinstall、launchがすべて成功した。
bundle IDは`dev.gigun.mcphost`、teamは既存の`KK42DL23GH`。アプリ削除、Keychain初期化、
接続先変更を行っていない。fresh DerivedDataは`ios-device-derived-data.Bf0P4G`。
build logはそのディレクトリの`device-build.log`、skill最終JSONは`status:ok`/`launched:true`だった。
このlaunch成功だけでOAuth/会話/カードのE2E成功とは扱わない。

`DeviceReadOnlyChatUITests`を追加し、保存済み設定の通常composerに「今日の予定（Asia/Tokyo）」と
「未完了todo」を作成/変更/削除なしで入力し、履歴出現・応答settle・スクリーンショット・再起動を
採取する実機UI試験を準備した。新UIファイルのformat/lint違反0。

同じ実機に対するxcodebuild testは2026-10-03 16:55:53 JST、runner起動前のdeviceprepで
`Code=-3` / `Unlock iPhone17 morita to Continue` / `device is locked`となった。
所有xcodebuildの待機だけを中断した。質問はまだ送信されず、アプリ/Keychainを消す代替操作もしていない。
詳細ログは`/tmp/swift-oauth-device-readonly-20261003.log`。
その後のユーザー指示により、実機自動UI試験は再開しない。ビルド・上書きinstall・launchで配送は完了し、
UX/実利用は本人が任意に確認する。ロック解除の維持や同じ質問の再試験は要求しない。
0011の残条件は本人による任意実利用確認と、取得できた予定・todoの機能OTel/サーバー結果照合である。
自動UI試験の質問は未送信であり、準備済みテストの存在だけではOAuth保持や予定・todo取得成功を断定しない。

## OAuth単位の隔離検証

2026-10-03、origin/mainと一致する `8c185895a62a10a519724d948069c247bc3ad684` を基に、
OAuthの製品4 files・回帰2 files・本書とdesign/08の計8 filesだけを隔離cloneへ移した。
他のResponses/OTel/性能/UI/MapPreviewのdirty、台帳、AGENTS変更は含めていない。
OAuth fixtureのPOST body読取helperはfixture内へ移し、既存dirty LLM回帰への依存を除去した。
`make verify` はServices158 tests/22 suites、Kernel131 tests/9 suites、lint155 files違反0、
iOS generic Simulator全体build成功。ログは `/tmp/swift-oauth-isolated-verify-20261003.log`。
HEAD範囲が小さいため前節の全dirty checkout検証とはテスト総数が異なる。
これは独立commit候補のbuild/test証拠であり、再配送・実機利用・UI試験は行っていない。
