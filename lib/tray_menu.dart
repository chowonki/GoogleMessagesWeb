import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

// 트레이 우클릭 메뉴 (Windows).
// Windows 기본 트레이 메뉴는 모양을 바꿀 수 없어서, 메뉴만 그리는 작은 도우미 창을
// 같은 실행 파일로 따로 띄워 둔다(--tray-menu <포트>). 본 창은 건드리지 않고,
// 둘은 이 컴퓨터 안에서만 통하는 소켓으로 한 줄짜리 JSON 을 주고받는다.

class TrayEntry {
  const TrayEntry(this.key, this.label,
      {this.checked, this.value, this.enabled = true, this.danger = false})
      : isDivider = false;
  const TrayEntry.divider()
      : key = '',
        label = '',
        checked = null,
        value = null,
        enabled = false,
        danger = false,
        isDivider = true;
  final String key, label;
  final bool? checked;
  final String? value;
  final bool enabled, danger, isDivider;

  Map<String, dynamic> toJson() => isDivider
      ? {'d': true}
      : {
          'k': key,
          'l': label,
          if (checked != null) 'c': checked,
          if (value != null) 'v': value,
          'e': enabled,
          'x': danger,
        };

  static TrayEntry fromJson(Map<String, dynamic> j) => j['d'] == true
      ? const TrayEntry.divider()
      : TrayEntry(j['k'] as String, j['l'] as String,
          checked: j['c'] as bool?,
          value: j['v'] as String?,
          enabled: j['e'] as bool? ?? true,
          danger: j['x'] as bool? ?? false);
}

// 아이콘은 항목 이름으로 고른다 (실행 중에 만든 아이콘은 빌드에서 빠지므로 상수로 둔다)
const Map<String, IconData> _icons = {
  'show': Icons.open_in_new_rounded,
  'new': Icons.edit_outlined,
  'unread': Icons.mark_chat_unread_outlined,
  'readAll': Icons.done_all_rounded,
  'notify': Icons.notifications_none_rounded,
  'preview': Icons.visibility_outlined,
  'themeNext': Icons.contrast_rounded,
  'autostart': Icons.rocket_launch_outlined,
  'reconnect': Icons.sync_rounded,
  'settings': Icons.settings_outlined,
  'lock': Icons.lock_outline_rounded,
  'quit': Icons.power_settings_new_rounded,
};

const double _kWidth = 272;
double _heightOf(List<TrayEntry> e) =>
    16.0 + e.fold<double>(0, (a, x) => a + (x.isDivider ? 9.0 : 40.0));

/// 본 앱 쪽: 도우미 창을 미리 띄워 두고, 우클릭 때 메뉴를 보여 달라고 한다.
class TrayMenuHost {
  TrayMenuHost({required this.onPick});
  final void Function(String key) onPick;

  ServerSocket? _server;
  Socket? _sock;
  Process? _proc;
  bool _starting = false;
  void Function()? onReady;

  bool get ready => _sock != null;

  Future<void> start() async {
    if (!Platform.isWindows || _starting || _sock != null) return;
    _starting = true;
    try {
      _server?.close();
      final server = _server =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((sock) {
        if (_sock != null) {
          sock.destroy();
          return;
        }
        _sock = sock;
        utf8.decoder.bind(sock).transform(const LineSplitter()).listen((line) {
          if (line == 'READY') {
            onReady?.call();
          } else if (line.startsWith('PICK ')) {
            onPick(line.substring(5));
          }
        }, onDone: _lost, onError: (_) => _lost(), cancelOnError: true);
      });
      _proc = await Process.start(
          Platform.resolvedExecutable, ['--tray-menu', '${server.port}']);
      _proc!.exitCode.then((_) => _lost());
    } catch (_) {
      _lost();
    } finally {
      _starting = false;
    }
  }

  void _lost() {
    _sock?.destroy();
    _sock = null;
    _proc = null;
  }

  /// 메뉴를 보여 준다. 도우미가 없으면 false (기본 메뉴로 대신한다)
  bool show(List<TrayEntry> entries, {required bool dark}) {
    final sock = _sock;
    final proc = _proc;
    if (sock == null || proc == null) {
      start();
      return false;
    }
    try {
      // 도우미 창이 앞으로 나와 포커스를 받을 수 있게 허용
      DynamicLibrary.open('user32.dll').lookupFunction<Int32 Function(Uint32),
          int Function(int)>('AllowSetForegroundWindow')(proc.pid);
    } catch (_) {}
    try {
      sock.writeln(jsonEncode({
        'dark': dark,
        'items': [for (final e in entries) e.toJson()],
      }));
      return true;
    } catch (_) {
      _lost();
      return false;
    }
  }

  void dispose() {
    _sock?.destroy();
    _proc?.kill();
    _server?.close();
    _sock = null;
    _proc = null;
  }
}

/// 도우미 쪽: 메뉴만 그리는 작은 창
Future<void> runTrayMenuHelper(
    int port, ThemeData Function(Brightness) theme) async {
  await windowManager.ensureInitialized();
  // 첫 화면이 그려질 때 창이 잠깐 보이지 않도록 투명하게, 화면 밖에 둔다
  await windowManager.setOpacity(0);
  await windowManager.setSkipTaskbar(true);
  await windowManager.setTitleBarStyle(TitleBarStyle.hidden,
      windowButtonVisibility: false);
  await windowManager.setResizable(false);
  await windowManager.setAlwaysOnTop(true);
  await windowManager.setBounds(const Rect.fromLTWH(-4000, -4000, _kWidth, 200));
  final Socket sock;
  try {
    sock = await Socket.connect(InternetAddress.loopbackIPv4, port);
  } catch (_) {
    exit(0);
  }
  runApp(_HelperApp(sock: sock, theme: theme));
}

class _HelperApp extends StatefulWidget {
  const _HelperApp({required this.sock, required this.theme});
  final Socket sock;
  final ThemeData Function(Brightness) theme;

  @override
  State<_HelperApp> createState() => _HelperAppState();
}

class _HelperAppState extends State<_HelperApp> with WindowListener {
  List<TrayEntry> _entries = const [];
  bool _dark = false;
  bool _open = false;
  DateTime _openedAt = DateTime.now();
  Timer? _guard;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    utf8.decoder
        .bind(widget.sock)
        .transform(const LineSplitter())
        .listen(_onLine, onDone: () => exit(0), onError: (_) => exit(0));
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 실행기가 첫 화면에서 창을 보이게 하므로 곧바로 숨긴다
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await windowManager.hide();
      _say('READY');
    });
  }

  void _say(String s) {
    try {
      widget.sock.writeln(s);
    } catch (_) {
      exit(0);
    }
  }

  Future<void> _onLine(String line) async {
    try {
      final j = jsonDecode(line) as Map<String, dynamic>;
      final items = [
        for (final e in j['items'] as List)
          TrayEntry.fromJson((e as Map).cast<String, dynamic>())
      ];
      setState(() {
        _entries = items;
        _dark = j['dark'] == true;
      });
      await _show(_heightOf(items));
    } catch (_) {}
  }

  Future<void> _show(double h) async {
    var p = await screenRetriever.getCursorScreenPoint();
    final d = await screenRetriever.getPrimaryDisplay();
    final sw = d.size.width, sh = d.size.height;
    final scale = (d.scaleFactor ?? 1).toDouble();
    // 커서 좌표가 물리 픽셀로 올 때는 논리 좌표로 바꾼다
    if (scale > 1 && (p.dx > sw + 1 || p.dy > sh + 1)) {
      p = Offset(p.dx / scale, p.dy / scale);
    }
    final maxL = sw - _kWidth - 8, maxT = sh - h - 8;
    final left = (p.dx - _kWidth + 14).clamp(8.0, maxL < 8 ? 8.0 : maxL);
    final top = (p.dy - h - 10).clamp(8.0, maxT < 8 ? 8.0 : maxT);
    await windowManager.setOpacity(0);
    await windowManager.setBounds(Rect.fromLTWH(left, top, _kWidth, h));
    _openedAt = DateTime.now();
    _open = true;
    await windowManager.show();
    await windowManager.focus();
    // 새 내용이 그려진 다음에 보이게 한다
    await Future<void>.delayed(const Duration(milliseconds: 45));
    await windowManager.setOpacity(1);
    // 포커스를 못 받았으면 바깥 클릭을 알 수 없으니 얼마 뒤 스스로 닫는다
    _guard?.cancel();
    _guard = Timer(const Duration(seconds: 8), () async {
      if (_open && !await windowManager.isFocused()) _close(null);
    });
  }

  Future<void> _close(String? key) async {
    if (!_open) return;
    _open = false;
    _guard?.cancel();
    await windowManager.hide();
    if (key != null) _say('PICK $key');
  }

  @override
  void onWindowBlur() {
    if (_open && DateTime.now().difference(_openedAt).inMilliseconds > 200) {
      _close(null);
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: widget.theme(_dark ? Brightness.dark : Brightness.light),
        home: Scaffold(
          body: TrayPopupMenu(
            entries: _entries,
            onSelect: _close,
            onDismiss: () => _close(null),
          ),
        ),
      );
}

/// 앱 안 우클릭 메뉴와 같은 모양 (아이콘 + 글자, 종료는 빨강)
class TrayPopupMenu extends StatelessWidget {
  const TrayPopupMenu(
      {super.key,
      required this.entries,
      required this.onSelect,
      required this.onDismiss});
  final List<TrayEntry> entries;
  final ValueChanged<String> onSelect;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) {
        if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
          onDismiss();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        color: PopupMenuTheme.of(context).color ?? c.surfaceContainerHigh,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: Column(
            children: [
              for (final e in entries)
                if (e.isDivider)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Divider(
                        height: 1,
                        thickness: 1,
                        color: c.outlineVariant.withValues(alpha: 0.7)),
                  )
                else
                  _Item(entry: e, onTap: () => onSelect(e.key)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Item extends StatefulWidget {
  const _Item({required this.entry, required this.onTap});
  final TrayEntry entry;
  final VoidCallback onTap;

  @override
  State<_Item> createState() => _ItemState();
}

class _ItemState extends State<_Item> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final e = widget.entry;
    final fg = !e.enabled
        ? c.onSurface.withValues(alpha: 0.38)
        : (e.danger ? c.error : c.onSurface);
    return MouseRegion(
      cursor: e.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: e.enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 40,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: _hover && e.enabled
                ? c.onSurface.withValues(alpha: 0.07)
                : c.onSurface.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(_icons[e.key],
                  size: 18,
                  color: !e.enabled
                      ? fg
                      : (e.danger ? c.error : c.onSurfaceVariant)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(e.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, color: fg)),
              ),
              if (e.value != null)
                Text(e.value!,
                    style:
                        TextStyle(fontSize: 12.5, color: c.onSurfaceVariant)),
              if (e.checked == true)
                Icon(Icons.check_rounded,
                    size: 18, color: e.enabled ? c.primary : fg),
            ],
          ),
        ),
      ),
    );
  }
}
