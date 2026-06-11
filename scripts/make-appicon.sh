#!/bin/bash
# アプリアイコン（星座ネットワーク案）の再生成: design/AppIcon.icns を作る。
# デザイン変更時は design/AppIconGenerator.swift を編集してこれを再実行する。
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf design/AppIcon.iconset
swift design/AppIconGenerator.swift design/AppIcon.iconset
iconutil -c icns design/AppIcon.iconset -o design/AppIcon.icns
rm -rf design/AppIcon.iconset
echo "✅ design/AppIcon.icns を生成しました"
