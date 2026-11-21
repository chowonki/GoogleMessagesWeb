// 앱이 직접 그리는 제목 표시줄. 페이지 맨 위의 배경색을 그대로 써서 화면과 하나로 이어진다.
import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

const double kTitleBarHeight = 36;

/// 페이지 맨 위 가장자리의 배경색 (assets/js/theme.js 가 알려 준다).
/// 왼쪽(대화 목록)과 오른쪽(대화)의 색이 다르면 [split] 에서 갈린다. 같으면 0.
@immutable
class PageColors {
  const PageColors(this.left, this.right, [this.split = 0]);

  static const light = PageColors(Color(0xFFFFFFFF), Color(0xFFFFFFFF));
  static const dark = PageColors(Color(0xFF131314), Color(0xFF131314));

  final Color left, right;
  final double split;

  bool get isDark => _isDark(right);

  static const _prefsKey = 'pageColors';

  /// 마지막으로 본 색. 없으면 Windows 설정을 따른다.
  static PageColors load(SharedPreferences prefs, Brightness system) {
    final v = prefs.getStringList(_prefsKey);
    final left = v != null && v.length == 3 ? int.tryParse(v[0]) : null;
    final right = left != null ? int.tryParse(v![1]) : null;
    if (left == null || right == null) {
      return system == Brightness.dark ? dark : light;
    }
    return PageColors(Color(left), Color(right), double.tryParse(v![2]) ?? 0);
  }

  void save(SharedPreferences prefs) => prefs.setStringList(
      _prefsKey, ['${left.toARGB32()}', '${right.toARGB32()}', '$split']);

  @override
  bool operator ==(Object other) =>
      other is PageColors &&
      other.left == left &&
      other.right == right &&
      other.split == split;

  @override
  int get hashCode => Object.hash(left, right, split);
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

class TitleBar extends StatelessWidget {
  const TitleBar({
    super.key,
    required this.colors,
    required this.title,
    required this.maximized,
  });

  final PageColors colors;
  final String title;
  final bool maximized;

  @override
  Widget build(BuildContext context) {
    const fade = Duration(milliseconds: 200);
    final split = colors.split;
    final bar = SizedBox(
      height: kTitleBarHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedContainer(duration: fade, color: colors.right),
          if (split > 0)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: split,
              child: AnimatedContainer(duration: fade, color: colors.left),
            ),
          Row(
            children: [
              Expanded(
                child: DragToMoveArea(
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      Image.asset('assets/app_icon.png', width: 16, height: 16),
                      const SizedBox(width: 9),
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: _foreground(
                                    split > 0 ? colors.left : colors.right)
                                .withValues(alpha: 0.8),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _CaptionButton(
                glyph: _Glyph.minimize,
                tooltip: '최소화',
                background: colors.right,
                onTap: windowManager.minimize,
              ),
              _CaptionButton(
                glyph: maximized ? _Glyph.restore : _Glyph.maximize,
                tooltip: maximized ? '이전 크기로' : '최대화',
                background: colors.right,
                onTap: maximized
                    ? windowManager.unmaximize
                    : windowManager.maximize,
              ),
              _CaptionButton(
                glyph: _Glyph.close,
                tooltip: '닫기',
                background: colors.right,
                onTap: windowManager.close,
              ),
            ],
          ),
        ],
      ),
    );
    if (maximized) return bar;
    // 제목 표시줄이 창의 맨 위를 덮으므로 위쪽 가장자리의 크기 조절을 직접 받는다
    return DragToResizeArea(
      resizeEdgeSize: 5,
      enableResizeEdges: const [
        ResizeEdge.top,
        ResizeEdge.topLeft,
        ResizeEdge.topRight,
      ],
      child: bar,
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
    required this.onTap,
  });

  final _Glyph glyph;
  final String tooltip;
  final Color background;
  final VoidCallback onTap;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton>
    with SingleTickerProviderStateMixin {
  /// 빛의 세기 (0: 꺼짐, 1: 마우스가 올라옴). 서서히 켜지고 꺼진다.
  late final AnimationController _light = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    reverseDuration: const Duration(milliseconds: 320),
  );
  final _pointer = ValueNotifier<Offset>(Offset.zero);
  final _pressed = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _light.dispose();
    _pointer.dispose();
    _pressed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 700),
      child: MouseRegion(
        onEnter: (e) {
          _pointer.value = e.localPosition;
          _light.forward();
        },
        onHover: (e) => _pointer.value = e.localPosition,
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
            size: const Size(46, kTitleBarHeight),
            painter: _CaptionButtonPainter(
              glyph: widget.glyph,
              foreground: _foreground(widget.background),
              light: _light,
              pointer: _pointer,
              pressed: _pressed,
            ),
          ),
        ),
      ),
    );
  }
}

/// 단추 하나를 그린다: 마우스를 따라 은은하게 번지는 빛 + 그 위의 그림
class _CaptionButtonPainter extends CustomPainter {
  _CaptionButtonPainter({
    required this.glyph,
    required this.foreground,
    required this.light,
    required this.pointer,
    required this.pressed,
  }) : super(repaint: Listenable.merge([light, pointer, pressed]));

  final _Glyph glyph;
  final Color foreground;
  final Animation<double> light;
  final ValueListenable<Offset> pointer;
  final ValueListenable<bool> pressed;

  static const _red = Color(0xFFD93025);
  static const _redGlow = Color(0xFFFF7A6E);

  @override
  void paint(Canvas canvas, Size size) {
    final t = Curves.easeOut.transform(light.value);
    final isClose = glyph == _Glyph.close;
    if (t > 0) _paintLight(canvas, size, t, isClose);
    _paintGlyph(canvas, size,
        isClose ? Color.lerp(foreground, Colors.white, t)! : foreground);
  }

  void _paintLight(Canvas canvas, Size size, double t, bool isClose) {
    final rect = Offset.zero & size;
    final down = pressed.value;
    // 바탕: 단추 전체가 아주 옅게 밝아진다
    final base = isClose
        ? _red.withValues(alpha: (down ? 0.95 : 0.82) * t)
        : foreground.withValues(alpha: (down ? 0.11 : 0.045) * t);
    canvas.drawRect(rect, Paint()..color = base);
    // 빛: 마우스가 있는 곳이 가장 밝고 바깥으로 갈수록 사라진다
    final glow = isClose ? _redGlow : foreground;
    final strength = (isClose ? 0.55 : 0.15) * t;
    canvas.save();
    canvas.clipRect(rect);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          colors: [
            glow.withValues(alpha: strength),
            glow.withValues(alpha: strength * 0.35),
            glow.withValues(alpha: 0),
          ],
          stops: const [0, 0.45, 1],
        ).createShader(Rect.fromCircle(center: pointer.value, radius: 38)),
    );
    canvas.restore();
  }

  void _paintGlyph(Canvas canvas, Size size, Color color) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..isAntiAlias = glyph != _Glyph.minimize;
    // 10×10 그림을 가운데에. 선이 흐려지지 않게 픽셀 가운데(.5)에 맞춘다.
    final x = (size.width / 2).floorToDouble() - 5 + 0.5;
    final y = (size.height / 2).floorToDouble() - 5 + 0.5;
    const radius = Radius.circular(1.5);
    switch (glyph) {
      case _Glyph.minimize:
        canvas.drawLine(Offset(x, y + 5), Offset(x + 10, y + 5), paint);
      case _Glyph.maximize:
        canvas.drawRRect(
            RRect.fromRectAndRadius(Rect.fromLTWH(x, y, 10, 10), radius),
            paint);
      case _Glyph.restore:
        canvas.drawRRect(
            RRect.fromRectAndRadius(Rect.fromLTWH(x, y + 2, 8, 8), radius),
            paint);
        // 뒤에 겹친 창: 위쪽과 오른쪽 변만 보인다
        canvas.drawPath(
          Path()
            ..moveTo(x + 2.5, y)
            ..lineTo(x + 8.5, y)
            ..arcToPoint(Offset(x + 10, y + 1.5), radius: radius)
            ..lineTo(x + 10, y + 7.5),
          paint,
        );
      case _Glyph.close:
        canvas.drawLine(Offset(x, y), Offset(x + 10, y + 10), paint);
        canvas.drawLine(Offset(x + 10, y), Offset(x, y + 10), paint);
    }
  }

  @override
  bool shouldRepaint(_CaptionButtonPainter old) =>
      old.glyph != glyph || old.foreground != foreground;
}
