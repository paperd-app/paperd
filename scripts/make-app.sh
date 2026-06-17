#!/bin/bash
# 開発用の Paperd.app バンドルを作る（→ docs/01 4節・6節・7節のバンドル構成に準拠）。
#
# swift run はバンドルなしの素のプロセスとして起動するため、macOSのアプリ統合が不完全になる
# （キーボードフォーカス・URLスキーム・Dock表示等）。動作確認はこのスクリプトで作った
# .app を使うのが確実:
#
#   scripts/make-app.sh           # ビルドして .build/Paperd.app を生成
#   scripts/make-app.sh --open    # 生成して起動まで行う
#
# 生成物には paperd-mcp が Contents/Helpers/ に同梱され、設定画面の
# 「MCP設定スニペットをコピー」が実パスを指すようになる。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${PAPERD_BUILD_CONFIG:-debug}"
swift build -c "$CONFIG"

BIN=".build/$CONFIG"
APP=".build/Paperd.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

cp "$BIN/Paperd" "$APP/Contents/MacOS/Paperd"
cp "$BIN/paperd-mcp" "$APP/Contents/Helpers/paperd-mcp"
# アプリアイコン（再生成は scripts/make-appicon.sh）
if [ -f design/AppIcon.icns ]; then
  cp design/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# Claudeスキル・エージェントの同梱（設定 > 連携 からインストール → docs/07 6.1, 6.2節）
cp -R skills "$APP/Contents/Resources/skills"
cp -R agents "$APP/Contents/Resources/agents"
# ワーカーソースの同梱（配布時は初回起動でApplication Supportへ展開 → docs/01 3.3節）
mkdir -p "$APP/Contents/Resources/worker"
cp worker/pyproject.toml "$APP/Contents/Resources/worker/"
cp -R worker/src "$APP/Contents/Resources/worker/src"
# UIローカリゼーション: String Catalogを .lproj/Localizable.strings へコンパイルして
# app Resources直下に置き、Bundle.main で解決できるようにする（→ docs/09 10.1節）。
# swift build（CLI）はxcstringsを素通しコピーするだけでコンパイルしないため、ここで行う
xcrun xcstringstool compile Sources/Paperd/Localizable.xcstrings \
  --output-directory "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>ja</string>
	<!-- UI対応言語（→ docs/09 10節） -->
	<key>CFBundleLocalizations</key>
	<array>
		<string>ja</string>
		<string>en</string>
	</array>
	<key>CFBundleExecutable</key>
	<string>Paperd</string>
	<key>CFBundleIdentifier</key>
	<string>jp.paperd.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>paperd</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.2.1</string>
	<key>CFBundleVersion</key>
	<string>3</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<!-- paperd:// URLスキーム（→ docs/01 6節） -->
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>jp.paperd.app</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>paperd</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
PLIST

# ad-hoc署名（ローカル実行用。配布はDeveloper ID + notarization → docs/01 7節）
codesign --force --deep --sign - "$APP"

echo "✅ $APP を生成しました"
if [[ "${1:-}" == "--open" ]]; then
    open "$APP"
fi
