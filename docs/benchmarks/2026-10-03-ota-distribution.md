# MCPHost のOTA配布検証

固定ページは https://install.097969.xyz/swift-mcp-app/ 、アプリ一覧は https://install.097969.xyz/ 。共通ota-deploy plugin 0.2.0でgigun-devのWorkerと非公開R2から配信する。Macが停止しても公開済みIPAの取得には影響しない。ページはCloudflare Access本人ログイン、インストーラー向けmanifestとIPAは対象パス限定・10分有効の署名URLで取得する。SafariのCookieをインストーラーへ引き継ぐ前提にしない。

2026-10-04に本人ログイン後のページ表示、manifestとIPAのHTTP 200、HEADの長さ、Rangeの206と内容、署名なし・期限切れ・対象変更の403を確認した。IPAのSHA-256は28bfd10ac5d256d878f8d332cd135fbf834e4d57eccae7a5387f1bb8e722a3d2、10,229,989 bytesで配布元と一致する。Barkへ既存AES暗号化経路でSafari用リンクと通常HTTPSリンクを送信し、サーバー受付を確認した。端末での受信・Safari指定・インストール成功とは区別する。

公開したIPAは前版と同じ内容。Release archiveとrelease-testing exportはMacBook Proで成功済み。bundle IDはdev.gigun.mcphost、teamはKK42DL23GH、CFBundleVersionは1。埋め込みad-hoc profileは対象iPhone17とiPad mini7を含み、get-task-allow=false、期限は2027-02-13。新しい端末はUDID登録とprofileを含む再exportが必要。

端末固有設定はGit外の ~/.config/ota-deploy/swift-mcp-app.conf。Cloudflare Worker設定は ~/.config/ota-deploy/cloudflare.json 、Accessポリシーはdotfilesのtofu/ota.tf、署名用秘密鍵はsecrets/ota-env.ageで管理する。発行・アップロード手順は共通pluginのREADMEを参照。アップロード完了後だけlatestを更新し、成功後にBark通知する。

Tailscale版は https://mini.tailbf83fe.ts.net/swift-mcp-app/ と https://pro.tailbf83fe.ts.net/swift-mcp-app/ に残す。各MacのLaunchAgent dev.gigun.ota-deployから127.0.0.1:18787をServeへ配信するため、Macの停止中は使えない。Cloudflare向け生成物は別ディレクトリに置き、既存ローカル配布を上書きしない。

mini本体ではghq取得・XcodeGenによるproject.ymlからの生成・Xcode 26.3の依存解決まで成功した。archiveはロックされたloginキーチェーンへの証明書書き込みで失敗（DVTSecErrorDomain -61）。本人の解除後に署名archiveとAd Hoc exportを再検証する。具体的な操作はdotfilesのdocs/mini-vm.mdを参照。

本人確認はTailscaleを切ったiPhoneのSafariで固定ページを開き、ログイン、インストール、起動、既存認証保持の順に行う。BarkのSafariリンクが開けなければ本文のHTTPSリンクからSafariで開く。これらの実機確認は未完了。
