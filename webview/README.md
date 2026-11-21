# Google 메시지 웹 (WebView 앱)

[Google 메시지 웹 버전](https://messages.google.com/web/)을 시스템 WebView(Windows: WebView2)로 감싼
데스크톱 앱입니다. Google 계정 로그인은 WebView 안에서 그대로 진행됩니다.

## 기능

- **트레이**: 닫기 버튼으로 트레이에 숨기기, Windows 시작 시 자동 실행, 항상 위에 표시
- **알림**: 웹 알림을 Windows 알림으로 표시, 클릭하면 해당 대화 열기
- **작업 표시줄**: 안 읽은 개수 배지, 새 알림 시 깜빡임
- **우클릭 메뉴**: 대화 목록·말풍선·대화 상단 막대를 우클릭하면 그 항목의 ⋮ 메뉴를 마우스 위치에 표시
- **라이브 텍스트**
  - 말풍선 글과 이미지 속 글자에서 전화번호·계좌번호·인증번호·이메일·운송장 번호를 인식해 표시, 클릭하면 복사
  - 이미지 속 글자는 드래그로 선택 가능
  - 이미지 글자 인식은 Windows 내장 OCR(`Windows.Media.Ocr`)로 이 PC 안에서만 처리
- **이미지 확대 보기**: 휠(확대/축소), 더블클릭(2.5배 ↔ 원래 크기), 끌기(이동), `+` `-` `0` 키
- **Windows 11**: 제목 표시줄 Mica 재질, 다크 모드를 따르는 트레이 메뉴, 링크 주소 미리보기(상태 표시줄) 숨김

## 구조

| 경로 | 내용 |
|---|---|
| `lib/main.dart` | 창·트레이·알림·배지, WebView 설정, OCR 보조 프로그램 호출 |
| `assets/js/notification.js` | 웹 알림 → 앱 연결 |
| `assets/js/context_menu.js` | 우클릭 → ⋮ 메뉴 |
| `assets/js/live_text.js` | 라이브 텍스트, 이미지 확대 보기 |
| `ocr/GmOcr.cs` | 이미지 글자 인식 보조 프로그램 소스 (`assets/ocr/gm_ocr.exe` 로 빌드) |
| `windows/runner/` | Mica 제목 표시줄, 다크 모드 메뉴 |
| `../packages/flutter_inappwebview_windows` | 상태 표시줄을 끄도록 한 줄 고친 플러그인 사본 |

## 빌드 (Windows)

필요한 것: Flutter, Visual Studio(C++ 데스크톱), Inno Setup 6.

```powershell
# 1) OCR 보조 프로그램 (GmOcr.cs 를 고쳤을 때만. Windows SDK 필요)
powershell -ExecutionPolicy Bypass -File ocr\build.ps1

# 2) 앱 — 증분 빌드는 WebView 플러그인에서 실패하므로 매번 build\windows 를 지운다
Remove-Item -Recurse -Force build\windows -ErrorAction SilentlyContinue
flutter build windows --release

# 3) 설치 파일 → dist\GoogleMessagesWeb-Setup-<버전>.exe
& "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" installer\windows.iss
```

버전은 `pubspec.yaml` 의 `version` 과 `installer/windows.iss` 의 `AppVersion` 두 곳을 함께 올립니다.

## 참고

- 안 읽은 개수 배지는 페이지 제목의 `(3)` 같은 표기를 읽습니다.
- 우클릭 메뉴와 라이브 텍스트는 Google 메시지 웹의 화면 구조(요소 이름)에 기대고 있어, Google 이 화면을
  바꾸면 `assets/js` 의 선택자를 고쳐야 할 수 있습니다.
- macOS 폴더는 Flutter 기본 틀만 있고 빌드·확인하지 않았습니다.
