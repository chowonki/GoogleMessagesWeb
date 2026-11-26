# Google 메시지 웹 (WebView 앱)

[Google 메시지 웹 버전](https://messages.google.com/web/)을 시스템 WebView(Windows: WebView2, macOS: WKWebView)로 감싼
데스크톱 앱입니다. Google 계정 로그인은 WebView 안에서 그대로 진행됩니다.

## 기능

- **트레이**: 닫기 버튼으로 트레이에 숨기기, Windows 시작 시 자동 실행, 항상 위에 표시. 메뉴 맨 아래에 앱 버전 표시
- **부드러운 스크롤** (Windows): 휠 스크롤을 미끄러지듯 움직이게 하고(`--enable-smooth-scrolling`), 터치패드의 작은 이동도 버리지 않음
- **알림**: 웹 알림을 Windows 알림으로 표시, 클릭하면 해당 대화 열기
- **작업 표시줄**: 안 읽은 개수 배지, 새 알림 시 깜빡임 (macOS: Dock 배지, 창이 뒤에 있으면 Dock 아이콘 튕김)
- **우클릭 메뉴**: 대화 목록·말풍선·대화 상단 막대를 우클릭하면 그 항목의 ⋮ 메뉴를 마우스 위치에 표시
- **라이브 텍스트**
  - 말풍선 글과 이미지 속 글자에서 전화번호·계좌번호·인증번호·이메일·운송장 번호를 인식해 표시, 클릭하면 복사
  - 이미지 속 글자는 드래그로 선택 가능
  - 이미지 글자 인식은 Windows 내장 OCR(`Windows.Media.Ocr`), macOS 내장 Vision 으로 이 컴퓨터 안에서만 처리
- **연락처 번호**: 저장된 연락처는 이름 아래에 전화번호를 함께 표시 (대화 목록, 대화 머리말)
- **이미지 확대 보기**: 휠(확대/축소), 더블클릭(2.5배 ↔ 원래 크기), 끌기(이동), `+` `-` `0` 키
  - 아래 막대의 **텍스트 인식** 단추(`T` 키)를 누르면 이미지를 어둡게 하고 글자 줄만 강조 표시. 이때만 글자 선택·번호 복사가 되고, 안 누르면 일반 이미지 보기
- **창 단추** (Windows): 제목 표시줄을 따로 두지 않고 최소화·최대화·닫기 단추를 화면 머리말 위에 바로 얹음.
  Google 메시지의 테마(밝게·어둡게·시스템 기본값·고대비)를 따라 단추와 창 테두리 색이 바뀌고, 머리말의 빈 곳을
  끌면 창이 움직이며 두 번 누르면 최대화됨
- **Windows 11**: 다크 모드를 따르는 트레이 메뉴, 링크 주소 미리보기(상태 표시줄) 숨김
- **하드웨어 가속**: 화면을 GPU 로 그린다(기본). 그래픽 드라이버 문제로 화면이 깨지거나 깜빡이면
  트레이(macOS: 메뉴 막대) 메뉴의 "하드웨어 가속 사용"을 끈다. Windows 는 바꾸면 앱이 다시 시작되고,
  macOS 는 페이지만 새로 불러온다
- **macOS**: 한글 메뉴 막대, `⌘W` 로 창 닫기(메뉴 막대에 남아 알림을 계속 받음)

## 구조

| 경로 | 내용 |
|---|---|
| `lib/main.dart` | 창·트레이·알림·배지, WebView 설정, OCR 보조 프로그램 호출 |
| `lib/window_controls.dart` | Windows 창 단추, 위쪽 가장자리 크기 조절, 창 테두리 밝기 |
| `assets/js/theme.js` | 머리말 색·높이 → 창 단추, 머리말을 끌어 창 옮기기 |
| `assets/js/notification.js` | 웹 알림 → 앱 연결 |
| `assets/js/context_menu.js` | 우클릭 → ⋮ 메뉴 |
| `assets/js/live_text.js` | 라이브 텍스트, 이미지 확대 보기 |
| `assets/js/contact_number.js` | 저장된 연락처 이름 아래에 전화번호 표시 |
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

# 4) (선택) MSI → dist\GoogleMessagesWeb-<버전>.msi  (WiX 5: dotnet tool install --global wix --version 5.0.2)
wix build installer\windows.wxs -arch x64 -d Version=<버전> -o dist\GoogleMessagesWeb-<버전>.msi
```

MSI 는 회사 일괄 배포용입니다. 현재 사용자 범위로 `%LOCALAPPDATA%\Programs\GoogleMessagesWeb` 에 설치되고
(exe 설치본과 다른 폴더), 시작 메뉴 바로 가기만 만듭니다. 자동 실행은 앱의 트레이 메뉴에서 켭니다.
exe 로 설치했던 것을 MSI 로 바꾸려면 exe 설치본을 먼저 제거하세요.

버전은 `pubspec.yaml` 의 `version` 과 `installer/windows.iss` 의 `AppVersion` 두 곳을 함께 올립니다.
(Actions 빌드는 `pubspec.yaml` 의 버전을 설치 파일에 넘기므로 둘이 달라도 릴리스 파일은 `pubspec.yaml` 을 따릅니다)

## 빌드 (macOS)

필요한 것: Flutter, Xcode.

```bash
tools/build_macos.sh          # → dist/GoogleMessagesWeb-<버전>.dmg
tools/build_macos.sh --open   # 빌드 뒤 바로 실행
```

개발자 인증서 없이 임시 서명(ad-hoc)을 하므로, 다른 Mac 에서 처음 열 때는 Finder 에서 앱을 우클릭 → **열기**로 한 번 허용해야 합니다.

## 릴리스 (GitHub Actions)

1. `pubspec.yaml` 의 `version` (과 `installer/windows.iss` 의 `AppVersion`) 을 올린다.
2. `../.github/release-notes.md` 에 이번 릴리스 설명을 쓴다.
3. main 에 합친다. `Release` 워크플로가 Windows(exe·msi)·macOS(dmg)를 빌드해 `v<버전>` 태그와 릴리스를 만든다.
   같은 버전 태그가 이미 있으면 건너뛴다. Actions 화면에서 수동으로 실행할 수도 있다.

## 참고

- 실행 중인 앱은 `google_messages_web.exe --quit` 으로 끝낼 수 있습니다.
- 시작·종료가 느릴 때는 환경 변수 `GM_TRACE=1` 로 실행하면 임시 폴더의 `gm_web_trace.log` 에 단계별 시간(ms)이
  남습니다. `GM_TRACE_QUIT_AFTER=<초>` 를 함께 주면 그 시간 뒤에 스스로 끝내 종료 시간을 잴 수 있습니다.
- 안 읽은 개수 배지는 페이지 제목의 `(3)` 같은 표기를 읽습니다.
- 연락처 번호는 Google 메시지가 이 컴퓨터에 저장해 두는 연락처 캐시에서 읽습니다. 캐시에 아직 없는 연락처는
  번호가 표시되지 않습니다.
- 우클릭 메뉴와 라이브 텍스트는 Google 메시지 웹의 화면 구조(요소 이름)에 기대고 있어, Google 이 화면을
  바꾸면 `assets/js` 의 선택자를 고쳐야 할 수 있습니다.
- macOS 에서는 "Windows 시작 시 자동 실행" 메뉴가 없습니다. 로그인할 때 열려면 시스템 설정 → 일반 → 로그인 항목에 앱을 추가하세요.
- macOS 메뉴 막대 아이콘은 누르면 메뉴가 뜹니다(열기·새로고침·항상 위에 표시·하드웨어 가속·종료).
