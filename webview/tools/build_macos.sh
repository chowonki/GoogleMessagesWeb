#!/bin/bash
# macOS 앱을 빌드해 서명하고 설치용 .dmg 를 만든다. (Flutter, Xcode 필요)
#   tools/build_macos.sh        → dist/GoogleMessagesWeb-<버전>.dmg
#   tools/build_macos.sh --open → 빌드 뒤 앱 실행
set -e
cd "$(dirname "$0")/.."
export PATH="$PATH:$HOME/flutter/bin:$HOME/development/flutter/bin:$HOME/Documents/flutter/bin:/opt/homebrew/bin:/usr/local/bin"
command -v flutter >/dev/null || { echo "Flutter 를 찾지 못했습니다 (PATH 확인)"; exit 1; }

VERSION=$(grep '^version:' pubspec.yaml | sed 's/version: *//; s/+.*//')
flutter pub get
flutter build macos --release
APP="build/macos/Build/Products/Release/Google Messages Web.app"

# 개발자 인증서가 없으므로 이 Mac 에서 쓰는 임시 서명(ad-hoc)을 한다
codesign --force --deep --sign - "$APP"
codesign --force --sign - --entitlements macos/Runner/Release.entitlements "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p dist
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "dist/GoogleMessagesWeb-$VERSION.dmg"
hdiutil create -volname "Google Messages Web" -srcfolder "$STAGE" -ov -format UDZO \
  "dist/GoogleMessagesWeb-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
echo "완료: $APP"
echo "설치 파일: dist/GoogleMessagesWeb-$VERSION.dmg"
[ "$1" = "--open" ] && open "$APP"
exit 0
