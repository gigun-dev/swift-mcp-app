# MCPHost のOTA配布検証

2026-10-03、共通ota-deploy plugin 0.1.0を使用。Release archiveとrelease-testing exportが成功した。IPAは9.8MiB、bundle IDはdev.gigun.mcphost、teamは既存KK42DL23GH。埋め込みad-hoc profileに対象iPhone17のUDIDがあり、get-task-allow=false、期限は2027-02-13。

配布ページ: https://pro.tailbf83fe.ts.net/swift-mcp-app/

MacのTailscale Serveから127.0.0.1:18787を配信する。VMからページとmanifestのHTTPS 200を確認。端末は同じtailnetへの接続が必要。ユーザーがiPhoneのSafariで「Install iOS」を押して上書きインストールし、起動と既存認証保持を確認する。端末でのOTAインストール成功はまだ確認していない。

端末固有設定はGit外の ~/.config/ota-deploy/swift-mcp-app.conf。配布サーバーはユーザーLaunchAgent dev.gigun.ota-deploy、RunAtLoad/KeepAlive。Macログイン中に継続し、Mac停止中は配信できない。上流のnohupのみでは実行環境の終了時にサーバーが消えたため、公開HTTPSの確認後にLaunchAgentへ切り替えた。配布物とbuild番号は ~/.ota-deploy に保存。

Mac miniにも同じIPAを配置し、manifestとページのホストをmini.tailbf83fe.ts.netへ置換。配布URLは https://mini.tailbf83fe.ts.net/swift-mcp-app/ 。同じLaunchAgentとServeを起動し、Pro（tag:admin-device）からHTTPS 200を確認。IPAのSHA-256はPro・VMダウンロード・mini配置の3箇所で一致（28bfd10ac5d256d878f8d332cd135fbf834e4d57eccae7a5387f1bb8e722a3d2）。VM（tag:server）からmini（tag:storage）へのHTTPSはタイムアウトするため、この経路の許可を仮定しない。Mac miniは今回は既存IPAの配布だけで、署名buildはProで実施。
