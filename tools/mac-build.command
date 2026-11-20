#!/bin/bash
# Mac 에서 Google 메시지 앱을 빌드해 실행한다. (Flutter, Xcode 필요. Go 는 없으면 내려받는다)
set -e
cd "$(dirname "$0")/.."
export PATH="$PATH:$HOME/flutter/bin:$HOME/development/flutter/bin:/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin:$HOME/go-sdk/go/bin"
command -v flutter >/dev/null || { echo "Flutter 를 찾지 못했습니다 (PATH 확인)"; exit 1; }
if ! command -v go >/dev/null; then
  echo "Go 내려받는 중…"
  mkdir -p "$HOME/go-sdk" && curl -fsSL "https://go.dev/dl/go1.25.4.darwin-$( [ "$(uname -m)" = arm64 ] && echo arm64 || echo amd64 ).tar.gz" | tar -xz -C "$HOME/go-sdk"
fi
flutter create --platforms=macos --org com.chowonki --project-name google_messages . >/dev/null
sed -i '' -E 's/keyEquivalent="[,fgej]"/keyEquivalent=""/g' macos/Runner/Base.lproj/MainMenu.xib
( cd native/gmbridge
  export CGO_ENABLED=1 MACOSX_DEPLOYMENT_TARGET=10.15
  go get go.mau.fi/mautrix-gmessages@105163a43ebe81bdec5f313c13ca213d89f45e5e && go mod tidy
  go build -buildmode=c-shared -ldflags "-s -w" -o libgmbridge.dylib .
  install_name_tool -id @rpath/libgmbridge.dylib libgmbridge.dylib )
flutter pub get
flutter build macos --release
APP="$(ls -d build/macos/Build/Products/Release/*.app | head -1)"
cp native/gmbridge/libgmbridge.dylib "$APP/Contents/Frameworks/"
codesign --force --deep --sign - "$APP"
codesign --force --sign - --entitlements macos/Runner/Release.entitlements "$APP"
echo "완료: $APP"
open "$APP"
