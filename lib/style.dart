import 'dart:io';

/// Windows·macOS 모두 One UI 스타일을 쓴다.
const bool oneUi = true;

/// 단축키 표시용 보조 키 (macOS 는 ⌘, Windows 는 Ctrl+)
final String kMod = Platform.isMacOS ? '⌘' : 'Ctrl+';

/// 대화창을 접었을 때(목록만 보일 때)의 기본 창 너비
const double kListWindowWidth = 396;

/// 대화창을 펼쳤을 때 대화창 쪽 기본 너비
const double kChatDefaultWidth = 620;

