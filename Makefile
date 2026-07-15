# P0 雛形の作業コマンド集。
#
# `make check` は「ロジック層(Kernel/Services)が壊れていないか」を素早く見る用途で、
# Xcode/xcodebuild を経由しない(swift build/test の方が xcodebuild よりずっと速く、
# CI 導入前の手元検証ループとして十分。CI 導入は授業の提出形態が決まってから — CLAUDE.md)。
# `make app` は逆にアプリターゲット(SwiftUI + XcodeGen 生成物)まで含めた
# 実機/シミュレータ相当のビルド確認に使う。
.PHONY: check gen app

check:
	swift build
	swift test
	@if command -v swiftformat >/dev/null 2>&1; then \
		echo "==> swiftformat --lint"; \
		swiftformat --lint .; \
	else \
		echo "==> swiftformat not installed: skipping (brew install swiftformat)"; \
	fi
	@if command -v swiftlint >/dev/null 2>&1; then \
		echo "==> swiftlint"; \
		swiftlint; \
	else \
		echo "==> swiftlint not installed: skipping (brew install swiftlint)"; \
	fi

# .xcodeproj は git 管理しない生成物なので、Xcode で開く/ビルドする前に
# 必ずこのコマンドで最新化する(project.yml が正・.xcodeproj は使い捨て)。
gen:
	xcodegen generate

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
