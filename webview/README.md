# Google 메시지 웹 (WebView 앱)

[Google 메시지 웹 버전](https://messages.google.com/web/)을 시스템 WebView(Windows: WebView2, macOS: WKWebView)로 감싼
데스크톱 앱입니다. Google 계정 로그인은 WebView 안에서 그대로 진행됩니다.

## 기능

- **트레이**: 닫기 버튼으로 트레이에 숨기기, Windows 시작 시 자동 실행, 항상 위에 표시
- **알림**: 웹 알림을 Windows 알림으로 표시, 클릭하면 해당 대화 열기
- **작업 표시줄**: 안 읽은 개수 배지, 새 알림 시 깜빡임 (macOS: Dock 배지, 창이 뒤에 있으면 Dock 아이콘 튕김)
- **우클릭 메뉴**: 대화 목록·말풍선·대화 상단 막대를 우클릭하면 그 항목의 ⋮ 메뉴를 마우스 위치에 표시
- **라이브 텍스트**
  - 말풍선 글과 이미지 속 글자에서 전화번호·계좌번호·인증번호·이메일·운송장 번호를 인식해 표시, 클릭하면 복사
  - 이미지 속 글자는 드래그로 선택 가능
  - 이미지 글자 인식은 Windows 내장 OCR(`Windows.Media.Ocr`), macOS 내장 Vision 으로 이 컴퓨터 안에서만 처리
- **이미지 확대 보기**: 휠(확대/축소), 더블클릭(2.5배 ↔ 원래 크기), 끌기(이동), `+` `-` `0` 키
- **창 단추** (Windows): 제목 표시줄을 따로 두지 않고 최소화·최대화·닫기 단추를 화면 머리말 위에 바로 얹음.
  Google 메시지의 테마(밝게·어둡게·시스템 기본값·고대비)를 따라 단추와 창 테두리 색이 바뀌고, 머리말의 빈 곳을
  끌면 창이 움직이며 두 번 누르면 최대화됨
- **Windows 11**: 다크 모드를 따르는 트레이 메뉴, 링크 주소 미리보기(상태 표시줄) 숨김

## 구조

| 경로 | 내용 |
|---|---|
| `lib/main.dart` | 창·트레이·알림·배지, WebView 설정, OCR 보조 프로그램 호출 |
| `lib/window_controls.dart` | Windows 창 단추, 위쪽 가장자리 크기 조절, 창 테두리 밝기 |
| `assets/js/theme.js` | 머리말 색·높이 → 창 단추, 머리말을 끌어 창 옮기기 |
| `assets/js/notification.js` | 웹 알림 → 앱 연결 |
| `assets/js/context_menu.js` | 우클릭 → ⋮ 메뉴 |
| `assets/js/live_text.js` | 라이브 텍스트, 이미지 확대 보기 |
| `ocr/GmOcr.cs` | 이미지 글자 인식 보조 프로그램 소스 (`assets/ocr/gm_ocr.exe` 로 빌드) |
| `windows/runner/` | 다크 모드 메뉴 |
| `macos/Runner/AppDelegate.swift` | 이미지 글자 인식(Vision), Dock 아이콘 다시 열기·튕김 |
| `tools/build_macos.sh` | macOS 빌드·서명·.dmg 만들기 |
| `../packages/flutter_inappwebview_windows` | 상태 표시줄을 끄도록 한 줄 고친 플러그인 사본 |

## 빌드 (Windows)

필요한 것: Flutter, Visual Studio(C++ 데스크톱), Inno Setup 6.

```powershell
# 1) OCR 보조 프로그램 (GmOcr.cs 를 고쳤을 때만. Windows SDK 필요)
powershell -ExecutionPolicy Bypass -File ocr\build.ps1

# 2) 앱 — 증분 빌드는 WebView 플러그인에서 실패하므로 매번 build\windows 를 지운다.
#    저장소 경로가 길면 MSB3501 로 실패하므로, 그때는 짧은 경로(mklink /J 로 만든 연결 등)에서 빌드한다
Remove-Item -Recurse -Force build\windows -ErrorAction SilentlyContinue
flutter build windows --release

# 3) 설치 파일 → dist\GoogleMessagesWeb-Setup-<버전>.exe
& "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" installer\windows.iss
```

버전은 `pubspec.yaml` 의 `version` 과 `installer/windows.iss` 의 `AppVersion` 두 곳을 함께 올립니다.

## 빌드 (macOS)

필요한 것: Flutter, Xcode.

```bash
tools/build_macos.sh          # → dist/GoogleMessagesWeb-<버전>.dmg
tools/build_macos.sh --open   # 빌드 뒤 바로 실행
```

개발자 인증서 없이 임시 서명(ad-hoc)을 하므로, 다른 Mac 에서 처음 열 때는 Finder 에서 앱을 우클릭 → **열기**로 한 번 허용해야 합니다.

## 참고

- 안 읽은 개수 배지는 페이지 제목의 `(3)` 같은 표기를 읽습니다.
- 우클릭 메뉴와 라이브 텍스트는 Google 메시지 웹의 화면 구조(요소 이름)에 기대고 있어, Google 이 화면을
  바꾸면 `assets/js` 의 선택자를 고쳐야 할 수 있습니다.
- macOS 에서는 "Windows 시작 시 자동 실행" 메뉴가 없습니다. 로그인할 때 열려면 시스템 설정 → 일반 → 로그인 항목에 앱을 추가하세요.
- macOS 메뉴 막대 아이콘은 누르면 메뉴가 뜹니다(열기·새로고침·항상 위에 표시·종료).
