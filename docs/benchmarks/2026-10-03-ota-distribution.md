# MCPHost のOTA配布検証

固定ページは https://install.097969.xyz/swift-mcp-app/ 、アプリ一覧は https://install.097969.xyz/ 。共通ota-deploy plugin 0.2.0でgigun-devのWorkerと非公開R2から配信する。Macが停止しても公開済みIPAの取得には影響しない。ページはCloudflare Access本人ログイン、インストーラー向けmanifestとIPAは対象パス限定・10分有効の署名URLで取得する。SafariのCookieをインストーラーへ引き継ぐ前提にしない。

2026-10-04に本人ログイン後のページ表示、manifestとIPAのHTTP 200、HEADの長さ、Rangeの206と内容、署名なし・期限切れ・対象変更の403を確認した。現在の配布版4のIPAはSHA-256が8c02b081e85740d0f5488190ba2fd251e253b51a131bf58ebfd626fc5bb4c73d、10,087,552 bytesでmini生成物・転送先・HTTPS取得の内容が一致する。Barkへ既存AES暗号化経路でSafari用リンクと通常HTTPSリンクを送信し、サーバー受付を確認した。同日、本人がBark通知の受信、通知タップからSafariへの遷移、iPhoneへのインストール成功を確認した。Tailscaleを切った状態での利用・起動・既存認証保持は未確認。

公開したIPAはminiのログイン済みGUIセッションでRelease archiveとrelease-testing exportが成功した版4。アプリ機能の変更はない。bundle IDはdev.gigun.mcphost、teamはKK42DL23GH、CFBundleVersionは4。埋め込みad-hoc profileは対象iPhone17とiPad mini7を含み、get-task-allow=false、期限は2027-02-13。新しい端末はUDID登録とprofileを含む再exportが必要。

端末固有設定はGit外の ~/.config/ota-deploy/swift-mcp-app.conf。Cloudflare Worker設定は ~/.config/ota-deploy/cloudflare.json 、Accessポリシーはdotfilesのtofu/ota.tf、署名用秘密鍵はsecrets/ota-env.ageで管理する。発行・アップロード手順は共通pluginのREADMEを参照。アップロード完了後だけlatestを更新し、成功後にBark通知する。

Tailscale版は https://mini.tailbf83fe.ts.net/swift-mcp-app/ と https://pro.tailbf83fe.ts.net/swift-mcp-app/ に残す。各MacのLaunchAgent dev.gigun.ota-deployから127.0.0.1:18787をServeへ配信するため、Macの停止中は使えない。Cloudflare向け生成物は別ディレクトリに置き、既存ローカル配布を上書きしない。

mini本体はghq取得・XcodeGenによるproject.ymlからの生成・Xcode 26.3での署名archiveとAd Hoc exportまで確認済み。XcodeでDevelopment証明書を追加した後もSSH直接実行はキーチェーンを利用できなかったが、gui/501の一時LaunchAgentでは署名が成功した。証明書の失効や権限緩和は行わず、一時job・plist・scriptは削除済み。具体的な運用条件はdotfilesのdocs/mini-vm.mdを参照。

本人確認はTailscaleを切ったiPhoneのSafariで固定ページを開き、ログイン、インストール、起動、既存認証保持の順に行う。BarkのSafariリンクが開けなければ本文のHTTPSリンクからSafariで開く。これらの実機確認は未完了。
