# Google 메시지 (데스크톱)

[Google Messages for Web](https://messages.google.com/web)을 Windows·macOS 데스크톱 앱으로 감싼 Flutter 프로그램입니다.

## 구조
- **화면**: Flutter 위젯으로 직접 그린 네이티브 UI (대화 목록 · 대화창 · 입력창). 웹페이지를 띄우지 않습니다.
- **통신**: `native/gmbridge` — [mautrix-gmessages](https://github.com/mautrix/gmessages)의 `libgm`(Go)을 C 공유 라이브러리로 빌드해 `dart:ffi`로 호출합니다. Google 메시지 웹과 같은 비공식 프로토콜이라 Google이 바꾸면 libgm 버전을 올려야 합니다.
- **로그인**: 앱 안 로그인 창(WebView)은 Google 계정 쿠키를 얻는 데만 쓰고, 이후 휴대폰에서 이모티콘을 눌러 페어링합니다.

## 기능
- Google 계정 로그인 + 이모티콘 페어링, 세션 저장(재실행 시 자동 연결)
- 대화 목록(검색, 보관함/스팸 폴더, 보관·삭제), 새 대화(연락처 검색/번호 입력)
- 대화창: 문자/RCS 송수신, 사진·파일 첨부 및 열기, 답장, 반응, 삭제, 전송 상태(전달됨·읽음), 입력 중 표시
- OS 기본 알림(클릭 시 해당 대화 열기), 안 읽은 수 표시, 읽음 처리 동기화
- 트레이 상주, 창 크기·위치 기억, 다크 모드, Windows 중복 실행 방지

## 단축키 (Mac은 Ctrl 대신 ⌘)
새 대화 Ctrl+N · 대화 검색 Ctrl+F/K · 대화 안 검색 Ctrl+Shift+F · 대화 이동 Ctrl+↑/↓ · 첨부 Ctrl+O · 사진 붙여넣기 Ctrl+V · 설정 Ctrl+, · 창 숨기기 Ctrl+W · 종료 Ctrl+Q · 취소/닫기 Esc

## 라이선스 참고
libgm은 AGPL-3.0입니다. 이 앱의 바이너리를 다른 사람에게 배포하려면 소스도 같은 라이선스로 공개해야 합니다(개인 사용은 무관).

## 빌드
GitHub Actions(`.github/workflows/build.yml`)가 `flutter create`로 플랫폼 폴더를 채운 뒤
Windows 설치 파일(.exe, Inno Setup)과 macOS `.dmg`를 만듭니다. `google-messages` 브랜치에 푸시하면 `pubspec.yaml` 버전으로 `gm-v<버전>` 릴리스까지 자동 게시됩니다.

로컬 빌드:
```
flutter create --platforms=windows,macos --org com.chowonki --project-name google_messages .
flutter build windows   # 또는 flutter build macos
```

Windows는 Microsoft Edge WebView2 런타임(Windows 10/11 기본 포함)을 사용합니다.
