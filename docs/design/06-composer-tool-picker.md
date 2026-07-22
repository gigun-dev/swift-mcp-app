# Composer tool picker（提案・未合意）

> **状態:** 2026-07-23 read-only監査を反映した設計案。UI方針はユーザー合意前であり、未実装。
> 接続securityの前提（広告したtoolだけmodel executorが実行可能）は本UIと独立して先に修正する。

## 1. 分ける状態

- 設定のserver toggleは永続的な**自動接続**。OFFなら切断する。
- composer pickerは**このチャットで使用**するmodel-visible toolの選択。接続自体は切らない。
- v1はchat単位とし、最初の送信時にtool集合をfreezeする。1ターン限定・永続tool defaultは将来slice。
- stable keyは`ToolKey(serverID, originalToolName)`。renameや64字短縮で変わるslug/wire名を保存keyにしない。

## 2. 一貫性の必須条件

同じ選択済みmodel-visible集合から、次を原子的に生成する。

1. LLMへ送る`ToolDefinition`
2. `MultiServerToolExecutor`が許可する明示route
3. `uiResourceURIs`とcard attribution
4. 実行時server表示名・元tool名

広告していないtoolはexecutorでも拒否する。`app` visibilityだけのtoolはmodel選択対象にせず、
既存カード内部の`AppsServerProxy`経由では引き続き実行可能にする。

最初の送信後に選択を変える場合は、実行中chatを差し替えず「この選択で新しいチャット」を確認する。
履歴にはoptionalなtool snapshotを保存し、当時モデルへ何を公開したか再現できる形を推奨する。

## 3. iPhone wireframe

```text
┌ composer ────────────────────────────┐
│ [slider.horizontal.3  5] [メッセージ…] [↑] │
└──────────────────────────────────────┘

sheet: ツール                               [完了]
  このチャットで使用  5個
  ┌ caldav                 [接続済み] [ON] ┐
  │ 3/8 を使用                              │
  │ ▾ list-todos                       [ON] │
  │   create-todo                      [ON] │
  │   delete-todo                     [OFF] │
  │   refresh-todos      [カード内部専用]   │
  └────────────────────────────────────────┘
  ┌ tdr-concierge          [要認証]          ┐
  │ 認証するとツールを選べます        [認証] │
  └────────────────────────────────────────┘
  [接続を管理…]
```

- 階層・説明・接続状態を持つためmenuでなくmedium/large sheetを使う。
- composer先頭buttonは44pt hit area、VoiceOverは「ツールを選択、5個使用中」。
- headerの異常indicatorとcomposer buttonは同じsheetを開き、server一覧を二重実装しない。
- `app` only toolはDisclosure内へread-only表示し、通常の選択数には含めない案を推奨する。

## 4. 合意が必要な選択

1. **選択の寿命:** chat単位freeze（推奨） / 1ターン限定 / 永続default。
2. **発話後の変更:** 選択後にnew chat確認（推奨） / pickerをread-only化。
3. **app-only tool:** 「カード内部専用」と補助表示（推奨） / 完全に隠す。
4. **履歴:** optional tool snapshotを保存（推奨） / 保存しない。

## 5. 実装・検証境界

- `ChatToolPickerView`を新設し、`ChatHomeView`がsheetを所有する。header/composerはpresentation要求だけ渡す。
- tool選択draftを保持したままpickerを開閉し、`ChatBodyView`の入力draftやsession IDを失わない。
- ready serverの表示/context順はregistry登録順に固定する。
- 純関数test: default all、server OFF→ONで子選択復元、model/app visibility、新規/消滅tool、0件。
- 統合test: `definitions == executor allowed routes == attribution keys`、unadvertised tool拒否、
  app-only card call維持、空chatだけ再構成可能、旧履歴decode互換。

