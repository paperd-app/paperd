#!/bin/bash
# 配布用ビルド: Releaseビルド → Developer ID署名（Hardened Runtime）→ notarization → zip
#（→ docs/01 7節）
#
# 必要な環境変数:
#   CODESIGN_IDENTITY  例: "Developer ID Application: Taro Yamada (TEAMID1234)"
#                      未設定ならad-hoc署名（配布不可・動作確認用）
#   NOTARY_PROFILE     notarytoolのkeychainプロファイル名（事前に
#                      `xcrun notarytool store-credentials` で登録）。未設定ならnotarization省略
set -euo pipefail
cd "$(dirname "$0")/.."

PAPERD_BUILD_CONFIG=release scripts/make-app.sh
APP=".build/Paperd.app"
IDENTITY="${CODESIGN_IDENTITY:--}"
ENTITLEMENTS="scripts/release-entitlements.plist"

# 内側から順に署名する（--deepは使わない: Appleの非推奨）
echo "→ 署名: $IDENTITY"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" \
  "$APP/Contents/Helpers/paperd-mcp"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" \
  "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [[ -n "${NOTARY_PROFILE:-}" && "$IDENTITY" != "-" ]]; then
    echo "→ notarization"
    ZIP=".build/Paperd-notarize.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm "$ZIP"
fi

VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
DIST=".build/paperd-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$DIST"
echo "✅ 配布物: $DIST"

# Homebrew cask定義の生成（自前tap用 → docs/01 7節）。
# GitHubリポジトリは PAPERD_REPO で指定（既定: paperd-app/paperd）
SHA256=$(shasum -a 256 "$DIST" | cut -d' ' -f1)
REPO="${PAPERD_REPO:-paperd-app/paperd}"
mkdir -p dist/Casks
cat > dist/Casks/paperd.rb <<CASK
cask "paperd" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/$REPO/releases/download/v#{version}/paperd-#{version}.zip"
  name "paperd"
  desc "Paper manager with local AI semantic search and MCP integration for Claude"
  homepage "https://github.com/$REPO"

  # Pythonワーカーの実行に必要（→ docs/01 3.3節）
  depends_on formula: "uv"
  depends_on macos: ">= :sonoma"

  app "Paperd.app"

  zap trash: [
    "~/Library/Application Support/paperd",
    "~/Library/Preferences/jp.paperd.app.plist",
  ]
end
CASK
echo "✅ cask定義: dist/Casks/paperd.rb（tapリポジトリ homebrew-paperd/Casks/ へコピーしてpush）"

if [[ "$IDENTITY" == "-" ]]; then
    echo "⚠ ad-hoc署名です。配布にはCODESIGN_IDENTITY（Developer ID）とNOTARY_PROFILEを設定してください。"
fi
