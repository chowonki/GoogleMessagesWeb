// 창 단추(최소화·최대화·닫기)와 창 가장자리. 제목 표시줄을 따로 두지 않고
// 페이지 머리말 위에 창 단추를 바로 얹는다 (assets/js/theme.js 와 짝).
import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

const double kCaptionButtonWidth = 30;

/// 창 단추의 높이. Windows 의 창 단추처럼 창 맨 위에 붙여 놓는다.
const double kCaptionHeight = 30;

/// 창 단추 세 개의 너비. 페이지는 머리말 오른쪽 끝을 이만큼 비워 둔다.
const double kCaptionWidth = kCaptionButtonWidth * 3;

/// 페이지 머리말의 모습 (theme.js 가 알려 준다).
@immutable
class PageChrome {
  const PageChrome(
    this.color, [
    this.headerHeight = 0,
    this.spans = const [],
    this.splash = false,
  ]);

  static const light = PageChrome(Color(0xFFFFFFFF));
  static const dark = PageChrome(Color(0xFF131314));

  /// 창 단추 자리의 배경색
  final Color color;

  /// 머리말을 찾지 못한 화면(로그인 등)에서는 0
  final double headerHeight;

  /// 머리말에서 누를 것이 없는 가로 구간: [왼쪽, 오른쪽, 왼쪽, 오른쪽, …]
  final List<double> spans;

  /// Google 메시지의 시작 화면(머리말이 아직 없다)
  final bool splash;

  bool get isDark => _isDark(color);

  /// 창을 끌어 옮기는 손잡이의 높이: 머리말 전체 (머리말이 없으면 맨 위 띠)
  double get dragHeight =>
      headerHeight > 0 ? headerHeight.clamp(32.0, 72.0) : 40;

  /// 창을 끌어 옮기는 손잡이로 쓸 구간들: (왼쪽, 너비)
  Iterable<(double, double)> get dragSpans sync* {
    for (var i = 0; i + 1 < spans.length; i += 2) {
      if (spans[i + 1] > spans[i]) yield (spans[i], spans[i + 1] - spans[i]);
    }
  }

  static const _prefsKey = 'pageChrome';

  /// 마지막으로 본 색과 높이. 없으면 Windows 설정을 따른다.
  static PageChrome load(SharedPreferences prefs, Brightness system) {
    final v = prefs.getStringList(_prefsKey);
    final color = v != null && v.length == 2 ? int.tryParse(v[0]) : null;
    if (color == null) return system == Brightness.dark ? dark : light;
    return PageChrome(Color(color), double.tryParse(v![1]) ?? 0);
  }

  void save(SharedPreferences prefs) =>
      prefs.setStringList(_prefsKey, ['${color.toARGB32()}', '$headerHeight']);

  @override
  bool operator ==(Object other) =>
      other is PageChrome &&
      other.color == color &&
      other.headerHeight == headerHeight &&
      other.splash == splash &&
      listEquals(other.spans, spans);

  @override
  int get hashCode =>
      Object.hash(color, headerHeight, splash, Object.hashAll(spans));
}

bool _isDark(Color c) => c.computeLuminance() < 0.4;

/// 배경 위에 얹는 글자·아이콘 색
Color _foreground(Color background) =>
    _isDark(background) ? const Color(0xFFE3E3E3) : const Color(0xFF1F1F1F);

/// 이 프로그램의 창 핸들. 못 찾으면 0.
/// (다른 Flutter 앱도 창 클래스 이름이 같으므로 프로세스까지 확인한다)
int _findOwnWindow() {
  final user32 = DynamicLibrary.open('user32.dll');
  final findWindowEx = user32.lookupFunction<
      IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
      int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)>('FindWindowExW');
  final getProcessId = user32.lookupFunction<
      Uint32 Function(IntPtr, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');
  final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  final owner = calloc<Uint32>();
  try {
    var hwnd = 0;
    do {
      hwnd = findWindowEx(0, hwnd, className, nullptr);
      if (hwnd != 0) getProcessId(hwnd, owner);
    } while (hwnd != 0 && owner.value != pid);
    return hwnd;
  } finally {
    calloc.free(className);
    calloc.free(owner);
  }
}

/// 창 테두리(Windows 11 의 1픽셀 선)도 화면의 밝기를 따르게 한다.
void applyWindowFrameBrightness(bool dark) {
  if (!Platform.isWindows) return;
  try {
    final hwnd = _findOwnWindow();
    if (hwnd == 0) return;
    final setAttribute = DynamicLibrary.open('dwmapi.dll').lookupFunction<
        Int32 Function(IntPtr, Uint32, Pointer<Int32>, Uint32),
        int Function(int, int, Pointer<Int32>, int)>('DwmSetWindowAttribute');
    final value = calloc<Int32>()..value = dark ? 1 : 0;
    setAttribute(hwnd, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, value, 4);
    calloc.free(value);
  } catch (_) {
    // 테두리 색만 못 바꾼 것이므로 그대로 둔다
  }
}

/// 창을 최대화하거나 이전 크기로 되돌린다
Future<void> toggleMaximize() async => await windowManager.isMaximized()
    ? windowManager.unmaximize()
    : windowManager.maximize();

/// 창 오른쪽 위에 얹는 최소화 · 최대화 · 닫기 단추
class WindowControls extends StatelessWidget {
  const WindowControls({
    super.key,
    required this.chrome,
    required this.maximized,
    this.visible = true,
  });

  final PageChrome chrome;

  /// 숨기면 서서히 사라지고 눌리지도 않는다
  final bool visible;
  final bool maximized;

  @override
  Widget build(BuildContext context) {
    const height = kCaptionHeight;
    final buttons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CaptionButton(
          glyph: _Glyph.minimize,
          tooltip: '최소화',
          background: chrome.color,
          height: height,
          onTap: windowManager.minimize,
        ),
        _CaptionButton(
          glyph: maximized ? _Glyph.restore : _Glyph.maximize,
          tooltip: maximized ? '이전 크기로' : '최대화',
          background: chrome.color,
          height: height,
          onTap: toggleMaximize,
        ),
        _CaptionButton(
          glyph: _Glyph.close,
          tooltip: '닫기',
          background: chrome.color,
          height: height,
          onTap: windowManager.close,
        ),
      ],
    );
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 220),
        child: buttons,
      ),
    );
  }
}

/// 창의 맨 위 가장자리. 제목 표시줄이 없어 화면이 창 맨 위까지 덮으므로
/// 위쪽·위 모서리의 크기 조절을 직접 받는다.
class TopResizeEdge extends StatelessWidget {
  const TopResizeEdge({super.key});

  static Widget _grip(ResizeEdge edge, MouseCursor cursor) => MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => windowManager.startResizing(edge),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 4,
      child: Row(
        children: [
          SizedBox(
            width: 8,
            child: _grip(ResizeEdge.topLeft, SystemMouseCursors.resizeUpLeft),
          ),
          Expanded(child: _grip(ResizeEdge.top, SystemMouseCursors.resizeUp)),
          SizedBox(
            width: 8,
            child: _grip(ResizeEdge.topRight, SystemMouseCursors.resizeUpRight),
          ),
        ],
      ),
    );
  }
}

enum _Glyph { minimize, maximize, restore, close }

/// 최소화 · 최대화 · 닫기 단추 (Windows 11 과 같은 크기와 동작)
class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.glyph,
    required this.tooltip,
    required this.background,
    required this.height,
    required this.onTap,
  });

  final _Glyph glyph;
  final String tooltip;
  final Color background;
  final double height;
  final VoidCallback onTap;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton>
    with SingleTickerProviderStateMixin {
  /// 빛의 세기 (0: 꺼짐, 1: 마우스가 올라옴). 서서히 켜지고 꺼진다.
  late final AnimationController _light = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
    reverseDuration: const Duration(milliseconds: 360),
  );
  final _pressed = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _light.dispose();
    _pressed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 700),
      child: MouseRegion(
        onEnter: (_) => _light.forward(),
        onExit: (_) {
          _pressed.value = false;
          _light.reverse();
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _pressed.value = true,
          onTapCancel: () => _pressed.value = false,
          onTap: () {
            _pressed.value = false;
            widget.onTap();
          },
          child: CustomPaint(
            size: Size(kCaptionButtonWidth, widget.height),
            painter: _CaptionButtonPainter(
              glyph: widget.glyph,
              dark: _isDark(widget.background),
              foreground: _foreground(widget.background),
              light: _light,
              pressed: _pressed,
            ),
          ),
        ),
      ),
    );
  }
}

/// 단추 하나를 그린다. 바탕은 칠하지 않고, 마우스를 올리면 아이콘 자체가 은은하게 빛난다.
class _CaptionButtonPainter extends CustomPainter {
  _CaptionButtonPainter({
    required this.glyph,
    required this.dark,
    required this.foreground,
    required this.light,
    required this.pressed,
  }) : super(repaint: Listenable.merge([light, pressed]));

  final _Glyph glyph;
  final bool dark;
  final Color foreground;
  final Animation<double> light;
  final ValueListenable<bool> pressed;

  /// 빛의 색: 닫기는 붉은빛, 나머지는 Google 메시지의 강조색(푸른빛)
  Color get _glow {
    if (glyph == _Glyph.close) {
      return dark ? const Color(0xFFFF8A80) : const Color(0xFFE53935);
    }
    return dark ? const Color(0xFFA8C7FA) : const Color(0xFF1A73E8);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = Curves.easeOut.transform(light.value);
    final path = _glyphPath(size);
    Paint stroke(Color color, double width) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = width;

    if (t > 0) {
      // 아이콘 둘레로 번지는 빛: 넓고 옅은 빛 위에 좁고 진한 빛을 겹친다
      final strength = t * (pressed.value ? 0.6 : 1);
      canvas.drawPath(
        path,
        stroke(_glow.withValues(alpha: 0.38 * strength), 4)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      canvas.drawPath(
        path,
        stroke(_glow.withValues(alpha: 0.6 * strength), 2)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.6),
      );
    }
    // 아이콘: 평소에는 조금 흐리게, 마우스를 올리면 빛의 색으로 또렷하게
    final rest = foreground.withValues(alpha: 0.78);
    canvas.drawPath(
        path,
        stroke(Color.lerp(rest, _glow, t)!, 1)
          ..isAntiAlias = glyph != _Glyph.minimize);
  }

  /// 8×8 그림을 가운데에. 선이 흐려지지 않게 픽셀 가운데(.5)에 맞춘다.
  Path _glyphPath(Size size) {
    const s = 8.0;
    final x = (size.width / 2).floorToDouble() - s / 2 + 0.5;
    final y = (size.height / 2).floorToDouble() - s / 2 + 0.5;
    const radius = Radius.circular(1.2);
    switch (glyph) {
      case _Glyph.minimize:
        return Path()
          ..moveTo(x, y + s / 2)
          ..lineTo(x + s, y + s / 2);
      case _Glyph.maximize:
        return Path()
          ..addRRect(
              RRect.fromRectAndRadius(Rect.fromLTWH(x, y, s, s), radius));
      case _Glyph.restore:
        return Path()
          ..addRRect(RRect.fromRectAndRadius(
              Rect.fromLTWH(x, y + 2, s - 2, s - 2), radius))
          // 뒤에 겹친 창: 위쪽과 오른쪽 변만 보인다
          ..moveTo(x + 2.5, y)
          ..lineTo(x + s - 1.2, y)
          ..arcToPoint(Offset(x + s, y + 1.2), radius: radius)
          ..lineTo(x + s, y + s - 2.5);
      case _Glyph.close:
        return Path()
          ..moveTo(x, y)
          ..lineTo(x + s, y + s)
          ..moveTo(x + s, y)
          ..lineTo(x, y + s);
    }
  }

  @override
  bool shouldRepaint(_CaptionButtonPainter old) =>
      old.glyph != glyph || old.dark != dark || old.foreground != foreground;
}
