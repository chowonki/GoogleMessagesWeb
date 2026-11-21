# Google 메시지 웹 (데스크톱 앱)

[Google 메시지 웹 버전](https://messages.google.com/web/)을 Windows·macOS 데스크톱 앱으로 감싼 Flutter 프로그램입니다.

| 경로 | 내용 |
|---|---|
| [`webview/`](webview/) | 앱 본체. 기능·구조·빌드 방법은 [webview/README.md](webview/README.md) 참고 |
| `packages/local_notifier` | Windows 알림 패키지 사본 |
| `packages/flutter_inappwebview_windows` | 링크 주소 미리보기(상태 표시줄)를 끄도록 한 줄 고친 WebView 플러그인 사본 |

libgm(Go) 기반이던 이전 앱(v1.0.14 까지)은 저장소 기록에 남아 있습니다.
