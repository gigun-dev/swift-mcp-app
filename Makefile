# P0 雛形の作業コマンド集。
#
# `make check` は「ロジック層(Kernel/Services)が壊れていないか」を素早く見る用途で、
# Xcode/xcodebuild を経由しない(swift build/test の方が xcodebuild よりずっと速く、
# CI 導入前の手元検証ループとして十分。CI 導入は授業の提出形態が決まってから — CLAUDE.md)。
# 静的解析だけを再実行できる `make lint` も用意する。高速gateの`make check`は
# build・test・lintのすべてが通ったときだけ成功する。
# `make app` は逆にアプリターゲット(SwiftUI + XcodeGen 生成物)まで含めた
# 実機/シミュレータ相当のビルド確認に使い、push前の最終gate`make verify`が両方を束ねる。
#
# 【環境の方針(2026-07-22 に調査して確定)】
# ツール(xcodegen / swiftformat / swiftlint)は**ユーザー環境(dotfiles の nix)で宣言的に
# 用意する**前提。この Makefile は素の PATH を見るだけで、環境を自前で組み立てない。
#
# 一度 project-scope の flake devShell + `direnv exec` にしたが撤回した。iOS では
# `pkgs.mkShell` が nix の macOS SDK を DEVELOPER_DIR/SDKROOT に注入し xcrun まで
# 差し替えるため(実測・NixOS/nixpkgs#355486)、Apple の xcodebuild と食い違って壊れる。
# coder-desktop-macos や ghostty は escape hatch(mkShellNoCC + unset + PATH 掃除)で
# 回避しているが、それは「devShell に入った上で nix のツールチェインを全部無効化する」構成で、
# 得られるのはツール3つ。ユーザー環境が既に宣言的ならそちらに入れる方が単純で事故らない。
# 経緯の全文は .envrc のコメント、調査の出典は docs/next-directions.md。
#
# CI を入れる段になったら devShell + escape hatch を再検討する。なお iOS では
# `nix build` / `nix flake check` でアプリをビルドする道は無い(Xcode はライセンス上
# パッケージ化できず、derivation 内はネットワーク無効で SwiftPM の依存解決ができない)。
# 「nix はツールの供給、make はタスクランナー」という分業が定説で、make は残す。
#
# 秘密(API キー)だけは .envrc(direnv)が .env から読む。こちらは PATH と違って
# シェルに自動で入らないので、`make run` の中で明示的に direnv へ取りに行く。

.PHONY: check lint gen app verify hooks doctor

# clone直後に1回だけ実行し、git管理される.githooksをこのrepositoryのhookとして有効化する。
# Git標準の`git push --no-verify`は、検証を意図的に迂回する非常口としてそのまま使える。
hooks:
	git config core.hooksPath .githooks
	@echo "core.hooksPath = .githooks（mainへのpush前にmake verify）"

# ツールが揃っているかの確認。何かおかしいと思ったらまずこれ。
# 「無いなら無いと言う」ことが目的なので、1つ足りなくても最後まで走って全部報告する。
doctor:
	@for t in xcodegen swiftformat swiftlint; do \
		if command -v $$t >/dev/null 2>&1; then \
			echo "==> $$t: $$($$t --version 2>&1 | head -1)"; \
		else \
			echo "!! $$t: 見つかりません（dotfiles の nix に追加するか nix profile install nixpkgs#$$t）"; \
		fi; \
	done
	@if command -v direnv >/dev/null 2>&1; then \
		if direnv exec . sh -c '[ -n "$$MCPHOST_LLM_KEY" ]' 2>/dev/null; then \
			echo "==> MCPHOST_LLM_KEY: 設定あり"; \
		else \
			echo "!! MCPHOST_LLM_KEY: 未設定（.env に OPENAI_API_KEY か MCPHOST_LLM_KEY を書く）"; \
		fi; \
	else \
		echo "!! direnv: 見つかりません（.env から鍵を読むのに使っています）"; \
	fi

# Kernel/Servicesを素早く確認するgate。個別のbuild/test結果とlint診断は出力上で分かれるが、
# check全体は3工程のどれか1つでも失敗すれば失敗する。
check:
	swift build
	swift test
	$(MAKE) lint

# swiftformat/swiftlint が無いときは **skip せず lint target を落とす**。
# 旧実装は「未インストールなので skipping」と出して緑で終わっていたため、
# **lint が一度も走っていないのに通ったように見える**状態を長く見逃していた
# (2026-07-22 に発覚)。`swift build`/`swift test`は単独実行できる一方、
# 完了判定の`make check`ではlint tool不在・違反も見逃さない。
lint:
	@command -v swiftformat >/dev/null 2>&1 || { echo "!! swiftformat が無い。make doctor を見よ" >&2; exit 1; }
	@echo "==> swiftformat --lint"
	@swiftformat Sources Tests Package.swift --lint --config .swiftformat --cache ignore
	@command -v swiftlint >/dev/null 2>&1 || { echo "!! swiftlint が無い。make doctor を見よ" >&2; exit 1; }
	@echo "==> swiftlint"
	@swiftlint lint --config .swiftlint.yml --strict --no-cache

# .xcodeproj は git 管理しない生成物なので、Xcode で開く/ビルドする前に
# 必ずこのコマンドで最新化する(project.yml が正・.xcodeproj は使い捨て)。
#
# 【xcodegen が無いときの扱い】無条件に落とすと xcodegen 未導入の環境で何もできなくなり、
# 逆に黙って既存 .xcodeproj を使うと **project.yml を編集したのに再生成されず、古い定義で
# ビルドが通ってしまう**(過去にこの分岐を置いていて危険だった)。
# → タイムスタンプで判定する。project.yml の方が新しければ再生成が必須なので落とし、
#   そうでなければ既存の生成物で続行してよい。これなら「導入するまで何もできない」も
#   「気づかないうちに古い定義でビルド」も両方避けられる。
gen:
	@if command -v xcodegen >/dev/null 2>&1; then \
		xcodegen generate; \
	elif [ ! -d MCPHost.xcodeproj ]; then \
		echo "!! xcodegen が無く MCPHost.xcodeproj も無いのでビルドできません。" >&2; \
		echo "   dotfiles の nix に xcodegen を追加するか nix profile install nixpkgs#xcodegen" >&2; \
		exit 1; \
	elif [ project.yml -nt MCPHost.xcodeproj ]; then \
		echo "!! project.yml が MCPHost.xcodeproj より新しいのに xcodegen がありません。" >&2; \
		echo "   古い定義でビルドすると気づけないので中断します。xcodegen を導入してください。" >&2; \
		exit 1; \
	else \
		echo "==> xcodegen 未導入: 既存の MCPHost.xcodeproj を使う（project.yml は変更されていない）"; \
	fi

# iOS Simulator 汎用 destination(実機の UDID や特定機種名に依存しないため、
# どの Mac でも同じコマンドで通る)。シミュレータは署名不要なので
# CODE_SIGNING_ALLOWED=NO をコマンドラインで明示し、署名周りの状態に
# 左右されず常に通るようにしておく(実機は `make device` を使う)。
# 2026-07-15: project.yml 側は Team 設定(自動署名)に切り替えたが、
# シミュレータビルドではこの NO 指定が優先されるので挙動は変わらない。
app: gen
	xcodebuild build \
		-project MCPHost.xcodeproj \
		-scheme MCPHost \
		-destination 'generic/platform=iOS Simulator' \
		CODE_SIGNING_ALLOWED=NO

# push前の最終gate。SwiftPMでKernel/Servicesのbuild・test・lintを確認した後、
# SwiftUIを含むiOSアプリターゲット全体もgeneric Simulator向けにコンパイルする。
verify: check app

# シミュレータへ install + launch まで一気にやる(検証ループ用)。
#
# 【なぜ作ったか】BYOK の API キーを毎回シミュレータの設定画面に手で貼るのが苦痛で、
# そもそもエージェントは資格情報をフィールドに入力しない運用なので、検証のたびに
# 人間の手を1回借りる必要があった。アプリは MCPHOST_LLM_KEY 等の環境変数を
# Keychain より優先して読む(Sources/Features/Settings/LLMSettingsStore.swift)ので、
# .env に1度書いておけば以後は `make run` だけで鍵入りのアプリが立ち上がる。
#
# 秘密は .env(.gitignore 済み・書式は素の KEY=value)に書き、**読むのは .envrc だけ**。
# ここでは `direnv exec .` の結果として既に環境に入っているものを SIMCTL_CHILD_* へ移すだけ
# (OPENAI_API_KEY → MCPHOST_LLM_KEY の読み替えも .envrc 側の責務)。
#   MCPHOST_LLM_KEY=sk-...       あるいは OPENAI_API_KEY=sk-...
#   MCPHOST_LLM_MODEL=gpt-5.4-mini
#   MCPHOST_SPIKE=todos          # スパイク画面へ直行したいときだけ
#
# 【SIMCTL_CHILD_ 前置の理由】この環境の simctl は `--setenv` を受け付けず
# "Invalid device: --setenv" になる。simctl は SIMCTL_CHILD_* を剥がして
# 子プロセス(= アプリ)の環境変数として渡す仕様なので、そちらを使う。
#
# 【空文字を渡してはいけない】LLMSettingsStore は `env[...] ?? Keychain ?? ""` の順で、
# **空文字も「値がある」と見なす**。未設定の変数をそのまま渡すと空文字が勝って
# Keychain 保存済みの鍵が無視される。よって値が空のものは export しない。
# export 経由にしているのは、コマンドライン引数だと ps で鍵が覗けてしまうため。
SIMULATOR ?= iPhone 17
BUNDLE_ID := dev.gigun.mcphost
DERIVED := .build/xcode

.PHONY: run
run: gen
	xcodebuild build \
		-project MCPHost.xcodeproj \
		-scheme MCPHost \
		-destination 'platform=iOS Simulator,name=$(SIMULATOR)' \
		-derivedDataPath $(DERIVED) \
		CODE_SIGNING_ALLOWED=NO
	@SIMULATOR_UDID="$$(xcrun simctl list devices available | awk -v target='$(SIMULATOR)' '{ \
		line=$$0; sub(/^[[:space:]]*/, "", line); \
		if (index(line, target " (") == 1) { rest=substr(line, length(target) + 3); split(rest, fields, ")"); print fields[1]; exit } \
	}')"; \
	if [ -z "$$SIMULATOR_UDID" ]; then echo "!! Simulator '$(SIMULATOR)' が見つかりません" >&2; exit 1; fi; \
	xcrun simctl boot "$$SIMULATOR_UDID" 2>/dev/null || true; \
	xcrun simctl install "$$SIMULATOR_UDID" $(DERIVED)/Build/Products/Debug-iphonesimulator/MCPHost.app; \
	if command -v direnv >/dev/null 2>&1; then RUNNER="direnv exec ."; \
	else echo "==> direnv が無いので鍵を渡せません（アプリは設定画面の Keychain 値で動きます）"; RUNNER="env"; fi; \
	$$RUNNER sh -c '\
	for v in MCPHOST_LLM_KEY MCPHOST_LLM_BASEURL MCPHOST_LLM_MODEL MCPHOST_SPIKE MCPHOST_AUTOCONNECT MCPHOST_SIDEBAR_OPEN; do \
		eval "val=\$$$$v"; \
		if [ -n "$$val" ]; then export "SIMCTL_CHILD_$$v=$$val"; fi; \
	done; \
	xcrun simctl launch --terminate-running-process "$$1" $(BUNDLE_ID)' sh "$$SIMULATOR_UDID"

# 実機ビルド(自動署名・Team は project.yml の DEVELOPMENT_TEAM)。
# インストール・起動まで含めた実機デプロイは ios-device-build スキルの
# devicectl フローを使う(ここではビルドが通ることの確認まで)。
.PHONY: device
device: gen
	xcodebuild build \
		-project MCPHost.xcodeproj \
		-scheme MCPHost \
		-destination 'generic/platform=iOS' \
		-allowProvisioningUpdates
