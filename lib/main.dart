import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:windows_single_instance/windows_single_instance.dart';

import 'bridge.dart';
import 'fade_menu.dart';
import 'home_page.dart';
import 'image_viewer.dart';
import 'lock.dart';
import 'login_page.dart';
import 'models.dart';
import 'sound.dart';
import 'store.dart';
import 'style.dart';
import 'tray_menu.dart';

const String kAppName = 'Google 메시지';
const String kVersion = '1.0.12';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 트레이 메뉴만 그리는 도우미 창으로 실행된 경우
  final tm = args.indexOf('--tray-menu');
  if (Platform.isWindows && tm >= 0 && tm + 1 < args.length) {
    await runTrayMenuHelper(
        int.tryParse(args[tm + 1]) ?? 0, MessagesApp.oneUiTheme);
    return;
  }

  final iv = args.indexOf('--image-viewer');
  final ivSpec = iv >= 0 && iv + 1 < args.length
      ? args[iv + 1]
      : Platform.environment['GM_IMAGE_VIEWER'];
  if (ivSpec != null && ivSpec.isNotEmpty) {
    await runImageViewerWindow(ivSpec, MessagesApp.oneUiTheme);
    return;
  }

  if (Platform.isWindows) {
    await WindowsSingleInstance.ensureSingleInstance(
      args,
      'google_messages_desktop_single_instance',
      onSecondWindow: (_) async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  final support = await getApplicationSupportDirectory();
  final sep = Platform.pathSeparator;
  final trace = File('${support.path}${sep}startup.log');
  void mark(String m) {
    try {
      trace.writeAsStringSync('${DateTime.now().toIso8601String()} $m\n',
          mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  try {
    if (trace.existsSync()) trace.deleteSync();
  } catch (_) {}
  mark('start $kVersion');

  // 메시지 엔진(gmbridge) 시작
  String? startError;
  final bridge = GmBridge();
  try {
    bridge.start('${support.path}${sep}session');
    mark('bridge ok');
  } catch (e) {
    startError = e.toString();
    mark('bridge error: $e');
  }

  if (Platform.isWindows) {
    // 로그인 창(WebView2) 환경
    try {
      final version = await WebViewEnvironment.getAvailableVersion();
      webViewAvailable = version != null;
      if (webViewAvailable) {
        webViewEnvironment = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(
            userDataFolder: '${support.path}${sep}WebView2',
            // Sec-CH-UA 의 "WebView2" 표기로 Google 로그인이 막히는 것을 방지
            additionalBrowserArguments:
                '--disable-features=UserAgentClientHint',
          ),
        );
      }
    } catch (e) {
      webViewAvailable = false;
      mark('webview error: $e');
    }
    mark('webview available=$webViewAvailable');
  }

  await windowManager.ensureInitialized();
  await localNotifier.setup(
    appName: kAppName,
    shortcutPolicy: ShortcutPolicy.requireCreate,
  );

  final prefs = await SharedPreferences.getInstance();
  final saved = _loadBounds(prefs);

  final options = WindowOptions(
    // 메신저처럼 목록만 보이는 좁은 창으로 시작하고, 대화를 열면 옆으로 펼친다
    size: saved?.size ?? Size(kListWindowWidth, 740),
    minimumSize: const Size(340, 480),
    center: saved == null,
    title: kAppName,
    // 창 테두리(타이틀바)를 숨기고 앱이 직접 그린다
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: Platform.isMacOS,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    if (saved != null) await windowManager.setBounds(saved);
    if (prefs.getBool('maximized') ?? false) await windowManager.maximize();
    await windowManager.setPreventClose(true);
    await windowManager.show();
    await windowManager.focus();
  });

  mark('window ready');
  final cacheDir = (await getApplicationCacheDirectory()).path;
  final state = AppState(bridge, prefs, cacheDir);
  final demo = Platform.environment['GM_DEMO'];
  if (demo == '1' || demo == 'list') {
    state.loadDemo();
    if (demo == 'list' || demo == 'chat') state.wide = false;
    if (demo == 'list') state.select(null);
  } else if (startError == null) {
    state.init();
  }

  // 사진 글자 인식 엔진을 미리 띄워 두어 첫 인식을 빠르게 한다
  Future<void>.delayed(const Duration(seconds: 4), prewarmOcr);

  runApp(MessagesApp(state: state, startError: startError));
}

Rect? _loadBounds(SharedPreferences prefs) {
  final l = prefs.getDouble('x');
  final t = prefs.getDouble('y');
  final h = prefs.getDouble('h');
  if (l == null || t == null || h == null || h < 480) return null;
  final w = (prefs.getDouble('listW') ?? kListWindowWidth).clamp(340.0, 700.0);
  return Rect.fromLTWH(l, t, w, h);
}

class MessagesApp extends StatelessWidget {
  const MessagesApp({super.key, required this.state, this.startError});
  final AppState state;
  final String? startError;

  /// Windows: One UI 스타일 (큰 둥근 카드, 삼성 블루, 알약 모양 버튼)
  static ThemeData oneUiTheme(Brightness b) {
    final dark = b == Brightness.dark;
    final accent = dark ? const Color(0xFF3E91FF) : const Color(0xFF0381FE);
    final base = ColorScheme.fromSeed(seedColor: accent, brightness: b);
    final scheme = dark
        ? base.copyWith(
            primary: accent,
            onPrimary: Colors.white,
            surface: const Color(0xFF171717),
            onSurface: const Color(0xFFFAFAFA),
            onSurfaceVariant: const Color(0xFF999999),
            surfaceContainerLow: const Color(0xFF1C1C1C),
            surfaceContainer: const Color(0xFF202020),
            surfaceContainerHigh: const Color(0xFF252525),
            surfaceContainerHighest: const Color(0xFF2A2A2C),
            secondaryContainer: const Color(0xFF242A35),
            onSecondaryContainer: const Color(0xFFFAFAFA),
            outline: const Color(0xFF5C5C5C),
            outlineVariant: const Color(0xFF333333),
            tertiaryContainer: const Color(0xFF3A2E12),
            onTertiaryContainer: const Color(0xFFFFD98A),
            error: const Color(0xFFFF6B60),
          )
        : base.copyWith(
            primary: accent,
            onPrimary: Colors.white,
            surface: const Color(0xFFFCFCFE),
            onSurface: const Color(0xFF000000),
            onSurfaceVariant: const Color(0xFF75757A),
            surfaceContainerLow: const Color(0xFFFCFCFE),
            surfaceContainer: const Color(0xFFF4F4F7),
            surfaceContainerHigh: const Color(0xFFFFFFFF),
            surfaceContainerHighest: const Color(0xFFEEEEF2),
            secondaryContainer: const Color(0xFFE6F0FF),
            onSecondaryContainer: const Color(0xFF000000),
            outlineVariant: const Color(0xFFE2E2E7),
            error: const Color(0xFFE5392D),
          );
    final pill = RoundedRectangleBorder(borderRadius: BorderRadius.circular(26));
    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: scheme,
      scaffoldBackgroundColor:
          dark ? const Color(0xFF000000) : const Color(0xFFF2F2F6),
      fontFamily: 'Pretendard',
      fontFamilyFallback: const ['Malgun Gothic', 'Segoe UI Emoji'],
      splashFactory: NoSplash.splashFactory,
      focusColor: Colors.transparent,
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        titleTextStyle: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 19,
            fontWeight: FontWeight.w700,
            color: scheme.onSurface),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 10,
        shadowColor: Colors.black.withValues(alpha: 0.35),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: pill,
          minimumSize: const Size(88, 44),
          textStyle: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 15,
              fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: pill,
          minimumSize: const Size(72, 42),
          textStyle: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 15,
              fontWeight: FontWeight.w700),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll(Colors.white),
        trackColor: WidgetStateProperty.resolveWith((st) =>
            st.contains(WidgetState.selected)
                ? accent
                : (dark ? const Color(0xFF4A4A4D) : const Color(0xFFC9C9CE))),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      chipTheme: ChipThemeData(shape: pill),
      listTileTheme: const ListTileThemeData(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(18)))),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1),
      snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating, width: 420, shape: pill),
      tooltipTheme: const TooltipThemeData(
          waitDuration: Duration(milliseconds: 500)),
    );
  }

  ThemeData _theme(Brightness b) {
    if (oneUi) return oneUiTheme(b);
    final dark = b == Brightness.dark;
    final base = ColorScheme.fromSeed(
        seedColor: const Color(0xFF4F5DFF), brightness: b);
    final scheme = dark
        ? base.copyWith(
            primary: const Color(0xFF6474FF),
            onPrimary: Colors.white,
            surface: const Color(0xFF17171C),
            onSurface: const Color(0xFFF1F1F4),
            onSurfaceVariant: const Color(0xFF9B9BA8),
            surfaceContainerLow: const Color(0xFF1C1C22),
            surfaceContainer: const Color(0xFF1F1F26),
            surfaceContainerHigh: const Color(0xFF24242C),
            surfaceContainerHighest: const Color(0xFF282831),
            secondaryContainer: const Color(0xFF2A2C45),
            onSecondaryContainer: const Color(0xFFE6E8FF),
            outline: const Color(0xFF5A5A66),
            outlineVariant: const Color(0xFF30303A),
            tertiaryContainer: const Color(0xFF372D12),
            onTertiaryContainer: const Color(0xFFFFDB8A),
          )
        : base.copyWith(
            primary: const Color(0xFF3F4EF0),
            onPrimary: Colors.white,
            surface: Colors.white,
            onSurface: const Color(0xFF17171C),
            onSurfaceVariant: const Color(0xFF6B6B78),
            surfaceContainerLow: const Color(0xFFF7F8FB),
            surfaceContainer: const Color(0xFFF3F4F8),
            surfaceContainerHigh: const Color(0xFFEFF1F6),
            surfaceContainerHighest: const Color(0xFFEDEFF5),
            secondaryContainer: const Color(0xFFE6E9FF),
            onSecondaryContainer: const Color(0xFF1B2170),
            outlineVariant: const Color(0xFFE2E4EC),
          );
    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: scheme,
      scaffoldBackgroundColor:
          dark ? const Color(0xFF0D0D10) : const Color(0xFFEBEDF3),
      fontFamily: 'Pretendard',
      fontFamilyFallback: const [
        'Malgun Gothic',
        'Apple SD Gothic Neo',
        'Segoe UI Emoji',
        'Apple Color Emoji',
      ],
      splashFactory: NoSplash.splashFactory,
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating, width: 420),
      tooltipTheme: const TooltipThemeData(
          waitDuration: Duration(milliseconds: 500)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => MaterialApp(
        title: kAppName,
        debugShowCheckedModeBanner: false,
        // 글씨 크기 설정을 앱 전체에 적용
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(state.textScale)),
          child: child!,
        ),
        // 입력창 우클릭 메뉴(잘라내기·복사·붙여넣기) 등을 한국어로
        locale: const Locale('ko'),
        supportedLocales: const [Locale('ko'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: state.themeMode,
        home: startError != null
            ? Scaffold(
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text('메시지 엔진을 시작하지 못했습니다.\n$startError',
                        textAlign: TextAlign.center),
                  ),
                ),
              )
            : Shell(state: state),
      ),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key, required this.state});
  final AppState state;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WindowListener, TrayListener {
  Timer? _saveTimer;
  bool _quitting = false;
  bool _maximized = false;
  int _lastUnread = -1;

  AppState get s => widget.state;
  SharedPreferences get prefs => s.prefs;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    trayManager.addListener(this);
    s.onIncoming = _notify;
    s.onUnreadChanged = _updateUnread;
    _initTray();
    if (Platform.isWindows) {
      Future<void>.delayed(const Duration(milliseconds: 1500), () {
        if (!mounted) return;
        // 도우미 창이 처음 뜰 때 포커스를 가져가므로, 쓰던 중이면 되돌린다
        final wasActive = s.windowActive;
        _trayHost.onReady = () {
          if (wasActive && mounted) windowManager.focus();
          _trayHost.onReady = null;
        };
        _trayHost.start();
      });
    }
    _chatOpen = s.wide && s.phase == Phase.ready;
    _wasLocked = s.locked;
    HardwareKeyboard.instance.addHandler(_onAnyKey);
    _lockTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _checkAutoLock());
    s.addListener(_onStateChanged);
    if (_chatOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _applyChat(true));
    }
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => _maximized = v);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    s.removeListener(_onStateChanged);
    HardwareKeyboard.instance.removeHandler(_onAnyKey);
    _lockTimer?.cancel();
    _saveTimer?.cancel();
    super.dispose();
  }

  // ───────── 앱 잠금: 자리를 비우면 자동으로 잠근다 ─────────
  DateTime _lastActivity = DateTime.now();
  Timer? _lockTimer;
  bool _wasLocked = false;

  void _touch() => _lastActivity = DateTime.now();

  bool _onAnyKey(KeyEvent e) {
    _touch();
    if (handleGlobalPasteKeys(e)) return true;
    // 로그인·잠금 화면에서도 창 숨기기(W)·종료(Q)는 동작한다 (본 화면은 HomePage 가 처리)
    if (e is KeyDownEvent && (s.phase != Phase.ready || s.locked)) {
      final hk = HardwareKeyboard.instance;
      final mod = Platform.isMacOS ? hk.isMetaPressed : hk.isControlPressed;
      if (mod && e.logicalKey == LogicalKeyboardKey.keyW) {
        windowManager.close();
        return true;
      }
      if (mod && e.logicalKey == LogicalKeyboardKey.keyQ) {
        _quit();
        return true;
      }
    }
    return false;
  }

  void _checkAutoLock() {
    if (!s.lockEnabled || s.locked || s.lockMinutes <= 0) return;
    if (DateTime.now().difference(_lastActivity).inSeconds >=
        s.lockMinutes * 60) {
      s.lockNow();
    }
  }

  // ───────── 대화창 접기/펼치기 ─────────
  bool _chatOpen = false;
  bool _resizing = false;

  void _onStateChanged() {
    _updateTrayMenu();
    if (s.locked != _wasLocked) {
      _wasLocked = s.locked;
      // 잠기는 순간 열려 있던 대화상자(설정 등)를 모두 닫는다
      if (s.locked) closeImageViewers();
      if (s.locked && mounted) {
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
      _touch();
    }
    final open = s.phase == Phase.ready && s.wide;
    if (open == _chatOpen) return;
    _chatOpen = open;
    _applyChat(open);
  }

  /// 대화를 열면 창을 오른쪽으로 넓히고, 닫으면 목록 너비로 줄인다.
  Future<void> _applyChat(bool open) async {
    if (await windowManager.isMaximized() ||
        await windowManager.isFullScreen()) {
      return;
    }
    final b = await windowManager.getBounds();
    final listW = (prefs.getDouble('listW') ?? kListWindowWidth).clamp(340.0, 700.0);
    var left = b.left;
    double width;
    if (open) {
      if (b.width >= listW + 260) return; // 이미 넓은 창
      await prefs.setDouble('listW', b.width);
      width = b.width + (prefs.getDouble('chatW') ?? kChatDefaultWidth);
      try {
        // 화면 오른쪽 밖으로 나가면 왼쪽으로 당긴다 (주 모니터 기준)
        final d = await screenRetriever.getPrimaryDisplay();
        final sw = d.visibleSize?.width ?? d.size.width;
        if (left >= 0 && left < sw && left + width > sw) {
          left = (sw - width).clamp(0.0, left);
        }
      } catch (_) {}
    } else {
      if (b.width < listW + 260) return; // 이미 좁은 창
      await prefs.setDouble('chatW', (b.width - listW).clamp(320.0, 2000.0));
      final prevLeft = prefs.getDouble('x');
      if (prevLeft != null && (prevLeft - left).abs() < 800 && prevLeft > left) {
        left = prevLeft; // 펼칠 때 당겨졌던 만큼 원래 자리로
      }
      width = listW;
    }
    _resizing = true;
    await windowManager.setBounds(
        Rect.fromLTWH(left, b.top, width, b.height),
        animate: true);
    _resizing = false;
  }

  // ───────── 트레이 ─────────
  Future<void> _initTray() async {
    await trayManager.setIcon(
      Platform.isWindows ? 'assets/tray.ico' : 'assets/tray.png',
      isTemplate: Platform.isMacOS,
    );
    await trayManager.setToolTip(kAppName);
    if (Platform.isWindows) _autostart = await autostartEnabled();
    await _updateTrayMenu(force: true);
  }

  bool _autostart = false;
  String _traySig = '';

  /// 트레이 우클릭 메뉴. 상태(안 읽은 수·알림·테마 등)가 바뀌면 다시 만든다.
  Future<void> _updateTrayMenu({bool force = false}) async {
    final ready = s.phase == Phase.ready && !s.locked;
    final unread = ready ? s.unreadCount : 0;
    final sig = '${s.locked}|${s.lockEnabled}|$ready|$unread|${s.notificationsEnabled}|${s.notifyPreview}|'
        '${s.themeMode.index}|$_autostart|${s.connState}';
    if (!force && sig == _traySig) return;
    _traySig = sig;
    final conn = switch (s.connState) {
      'connected' => '휴대폰에 연결됨',
      'connecting' || 'reconnecting' => '연결 중…',
      'phone_not_responding' => '휴대폰 응답 없음',
      _ => '연결 끊김',
    };
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: '$kAppName 열기'),
      if (ready) MenuItem(key: 'new', label: '새 메시지 작성'),
      if (ready)
        MenuItem(
            key: 'unread',
            label: unread > 0 ? '읽지 않은 대화 $unread개 보기' : '읽지 않은 대화 없음',
            disabled: unread == 0),
      if (ready)
        MenuItem(key: 'readAll', label: '모두 읽음으로 표시', disabled: unread == 0),
      MenuItem.separator(),
      MenuItem.checkbox(
          key: 'notify', label: '새 메시지 알림', checked: s.notificationsEnabled),
      MenuItem.checkbox(
          key: 'preview',
          label: '알림에 내용 표시',
          checked: s.notifyPreview,
          disabled: !s.notificationsEnabled),
      MenuItem.submenu(
        key: 'theme',
        label: '테마',
        submenu: Menu(items: [
          MenuItem.checkbox(
              key: 'theme0',
              label: '시스템 설정',
              checked: s.themeMode == ThemeMode.system),
          MenuItem.checkbox(
              key: 'theme1', label: '밝게', checked: s.themeMode == ThemeMode.light),
          MenuItem.checkbox(
              key: 'theme2', label: '어둡게', checked: s.themeMode == ThemeMode.dark),
        ]),
      ),
      if (Platform.isWindows)
        MenuItem.checkbox(
            key: 'autostart', label: 'Windows 시작 시 자동 실행', checked: _autostart),
      MenuItem.separator(),
      if (ready) MenuItem(key: 'conn', label: conn, disabled: true),
      if (ready) MenuItem(key: 'reconnect', label: '다시 연결'),
      if (ready) MenuItem(key: 'settings', label: '설정…'),
      if (s.lockEnabled && !s.locked && s.phase == Phase.ready)
        MenuItem(key: 'lock', label: '지금 잠그기'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: '종료'),
    ]));
  }

  @override
  void onTrayIconMouseDown() => _showWindow();

  @override
  void onTrayIconRightMouseDown() {
    // Windows: 앱 메뉴와 같은 모양의 메뉴를 도우미 창에 띄운다 (준비 전이면 기본 메뉴)
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (!Platform.isWindows || !_trayHost.show(_trayEntries(), dark: dark)) {
      trayManager.popUpContextMenu();
    }
  }

  late final TrayMenuHost _trayHost = TrayMenuHost(onPick: _runTrayAction);

  List<TrayEntry> _trayEntries() {
    final ready = s.phase == Phase.ready && !s.locked;
    final unread = ready ? s.unreadCount : 0;
    final conn = switch (s.connState) {
      'connected' => '휴대폰에 연결됨',
      'connecting' || 'reconnecting' => '연결 중…',
      'phone_not_responding' => '휴대폰 응답 없음',
      _ => '연결 끊김',
    };
    const themeNames = ['시스템 설정', '밝게', '어둡게'];
    return [
      TrayEntry('show', '$kAppName 열기'),
      if (ready) TrayEntry('new', '새 메시지 작성'),
      if (ready)
        TrayEntry('unread', unread > 0 ? '읽지 않은 대화 $unread개 보기' : '읽지 않은 대화 없음',
            enabled: unread > 0),
      if (ready)
        TrayEntry('readAll', '모두 읽음으로 표시',
            enabled: unread > 0),
      const TrayEntry.divider(),
      TrayEntry('notify', '새 메시지 알림',
          checked: s.notificationsEnabled),
      TrayEntry('preview', '알림에 내용 표시',
          checked: s.notifyPreview, enabled: s.notificationsEnabled),
      TrayEntry('themeNext', '테마',
          value: themeNames[s.themeMode.index]),
      TrayEntry('autostart', 'Windows 시작 시 자동 실행',
          checked: _autostart),
      const TrayEntry.divider(),
      if (ready)
        TrayEntry('reconnect', '다시 연결', value: conn),
      if (ready) TrayEntry('settings', '설정'),
      if (s.lockEnabled && !s.locked && s.phase == Phase.ready)
        TrayEntry('lock', '지금 잠그기'),
      if (ready) const TrayEntry.divider(),
      TrayEntry('quit', '종료', danger: true),
    ];
  }

  Future<void> _runTrayAction(String key) async {
    switch (key) {
      case 'show':
        await _showWindow();
      case 'new':
        await _showWindow();
        openNewChat?.call();
      case 'unread':
        await _showWindow();
        s.setFolder('inbox');
        for (final c in s.visible) {
          if (c.unread) {
            s.select(c.id);
            break;
          }
        }
      case 'readAll':
        s.markAllRead();
      case 'notify':
        s.notificationsEnabled = !s.notificationsEnabled;
      case 'preview':
        s.notifyPreview = !s.notifyPreview;
      case 'themeNext':
        s.themeMode = ThemeMode.values[(s.themeMode.index + 1) % 3];
      case 'autostart':
        if (await setAutostart(!_autostart)) _autostart = !_autostart;
      case 'lock':
        s.lockNow();
      case 'reconnect':
        s.reconnect();
      case 'settings':
        await _showWindow();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) {
            _openSettings();
          }
        });
      case 'quit':
        _quit();
        return;
    }
    _updateTrayMenu(force: true);
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        _showWindow();
      case 'new':
        await _showWindow();
        openNewChat?.call();
      case 'unread':
        await _showWindow();
        s.setFolder('inbox');
        for (final c in s.visible) {
          if (c.unread) {
            s.select(c.id);
            break;
          }
        }
      case 'readAll':
        s.markAllRead();
      case 'notify':
        s.notificationsEnabled = !s.notificationsEnabled;
      case 'preview':
        s.notifyPreview = !s.notifyPreview;
      case 'theme0':
        s.themeMode = ThemeMode.system;
      case 'theme1':
        s.themeMode = ThemeMode.light;
      case 'theme2':
        s.themeMode = ThemeMode.dark;
      case 'autostart':
        if (await setAutostart(!_autostart)) _autostart = !_autostart;
      case 'lock':
        s.lockNow();
      case 'reconnect':
        s.reconnect();
      case 'settings':
        await _showWindow();
        if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) {
          _openSettings();
        }
      case 'quit':
        _quit();
        return;
    }
    _updateTrayMenu(force: true);
  }

  Future<void> _showWindow() async {
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    _quitting = true;
    _trayHost.dispose();
    closeImageViewers();
    await _saveBounds();
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  void _updateUnread() {
    final n = s.unreadCount;
    if (n == _lastUnread) return;
    _lastUnread = n;
    final label = n > 0 ? '$kAppName ($n)' : kAppName;
    windowManager.setTitle(label);
    trayManager.setToolTip(label);
    if (Platform.isMacOS) {
      windowManager.setBadgeLabel(n > 0 ? '$n' : null);
    }
  }

  // ───────── 알림 ─────────
  Future<void> _notify(Conversation? conv, Message msg) async {
    final title = conv?.title ??
        (msg.senderName.isNotEmpty ? msg.senderName : kAppName);
    // 내용 표시는 설정을 따른다. 잠금 중에 숨길지는 별도 설정(기본: 숨기지 않음)
    final hide = s.locked && s.hidePreviewWhenLocked;
    final show = s.notifyPreview && !hide;
    var body = show && msg.summary.isNotEmpty ? msg.summary : '새 메시지';
    // 알림은 넉넉한 크기로 보여 주되, 너무 긴 문자는 300자까지만 싣는다
    body = body.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    if (body.runes.length > 300) {
      body = '${String.fromCharCodes(body.runes.take(300))}…';
    }
    if (conv != null && conv.isGroup) {
      final p = conv.participant(msg.participantId);
      if (p != null && show) body = '${p.display}: $body';
    }
    // 직접 고른 알림 소리가 있으면 시스템 소리는 끄고 그 파일을 재생한다
    final sound = s.soundPath;
    final n = LocalNotification(
        title: hide ? kAppName : title, body: body, silent: sound != null);
    if (sound != null) playSoundFile(sound);
    n.onClick = () {
      _showWindow();
      if (s.phase == Phase.ready) s.select(msg.convId);
    };
    await n.show();
  }

  // ───────── 창 상태 ─────────
  @override
  void onWindowClose() async {
    if (_quitting) return;
    // 닫기 버튼은 트레이로 숨기기 (문자 알림을 계속 받기 위해)
    await _saveBounds();
    await windowManager.hide();
    s.setWindowActive(false);
  }

  @override
  void onWindowFocus() => s.setWindowActive(true);

  @override
  void onWindowBlur() => s.setWindowActive(false);

  @override
  void onWindowMinimize() => s.setWindowActive(false);

  @override
  void onWindowResized() => _scheduleSave();

  @override
  void onWindowMoved() => _scheduleSave();

  @override
  void onWindowMaximize() {
    prefs.setBool('maximized', true);
    setState(() => _maximized = true);
  }

  @override
  void onWindowUnmaximize() {
    prefs.setBool('maximized', false);
    setState(() => _maximized = false);
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _saveBounds);
  }

  Future<void> _saveBounds() async {
    if (_resizing ||
        await windowManager.isMaximized() ||
        await windowManager.isMinimized()) {
      return;
    }
    final b = await windowManager.getBounds();
    await prefs.setDouble('y', b.top);
    await prefs.setDouble('h', b.height);
    final listW = (prefs.getDouble('listW') ?? kListWindowWidth).clamp(340.0, 700.0);
    if (b.width < listW + 260 && !_chatOpen) {
      // 접힌 상태: 목록 창의 위치와 너비를 기억
      await prefs.setDouble('x', b.left);
      await prefs.setDouble('listW', b.width);
    } else if (b.width >= listW + 260) {
      // 펼친 상태: 대화창 쪽 너비를 기억
      await prefs.setDouble('chatW', (b.width - listW).clamp(320.0, 2000.0));
      if (prefs.getDouble('x') == null) await prefs.setDouble('x', b.left);
    }
  }

  // ───────── 설정 ─────────
  /// 설정 창에서 보고 있는 분류
  final ValueNotifier<String> _settingsTab = ValueNotifier('알림');

  void _openSettings() {
    showDialog<void>(
      context: context,
      builder: (ctx) => ListenableBuilder(
        listenable: Listenable.merge([s, _settingsTab]),
        builder: (ctx, _) {
          final c = Theme.of(ctx).colorScheme;
          final tab = _settingsTab.value;
          final mod = Platform.isMacOS ? '⌘' : 'Ctrl+';
          return Dialog(
            backgroundColor: Theme.of(ctx).scaffoldBackgroundColor,
            surfaceTintColor: Colors.transparent,
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 20),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(30)),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 제목 줄
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 14, 8),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text('설정',
                              style: TextStyle(
                                  fontSize: 24, fontWeight: FontWeight.w700)),
                        ),
                        HeaderIcon(
                          icon: Symbols.close,
                          tooltip: '닫기 (Esc)',
                          raised: true,
                          onTap: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                  ),
                  // 분류 탭
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: Row(
                      children: [
                        for (final t in const ['알림', '화면', '잠금', '일반', '계정'])
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: _SettingsTab(
                              label: t,
                              selected: t == tab,
                              onTap: () => _settingsTab.value = t,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
                      child: ConstrainedBox(
                      // 탭을 바꿔도 창 높이가 크게 출렁이지 않게
                      constraints: const BoxConstraints(minHeight: 300),
                      child: Column(
                        children: [
                          if (tab == '알림')
                          _SettingsGroup(label: '알림', children: [
                            _SettingsRow(
                              icon: Symbols.notifications,
                              title: '새 메시지 알림',
                              trailing: Switch(
                                value: s.notificationsEnabled,
                                onChanged: (v) => s.notificationsEnabled = v,
                              ),
                            ),
                            _SettingsRow(
                              icon: Symbols.visibility,
                              title: '알림에 내용 표시',
                              subtitle: '끄면 "새 메시지"로만 알려 줍니다',
                              trailing: Switch(
                                value: s.notifyPreview,
                                onChanged: s.notificationsEnabled
                                    ? (v) => s.notifyPreview = v
                                    : null,
                              ),
                            ),
                            _SettingsRow(
                              icon: Symbols.music_note,
                              title: '알림 소리',
                              subtitle: s.soundPath == null
                                  ? '시스템 기본 소리'
                                  : '직접 고른 소리 파일',
                              trailing: _ValuePicker<String>(
                                value: s.soundPath == null ? 'default' : 'file',
                                options: const {
                                  'default': '기본 소리',
                                  'file': '파일 선택…',
                                },
                                onChanged: (v) async {
                                  if (v == 'default') {
                                    await s.setSoundFile(null);
                                    return;
                                  }
                                  final f = await openFile(acceptedTypeGroups: [
                                    const XTypeGroup(
                                        label: '소리',
                                        extensions: ['mp3', 'wav', 'm4a', 'ogg']),
                                  ]);
                                  if (f == null) return;
                                  await s.setSoundFile(f.path);
                                  final p = s.soundPath;
                                  if (p != null) playSoundFile(p); // 들어 보기
                                },
                              ),
                            ),
                          ]),
                          if (tab == '화면')
                          _SettingsGroup(label: '화면', children: [
                            _SettingsRow(
                              icon: Symbols.contrast,
                              title: '테마',
                              trailing: _ValuePicker<ThemeMode>(
                                value: s.themeMode,
                                options: const {
                                  ThemeMode.system: '시스템 설정',
                                  ThemeMode.light: '밝게',
                                  ThemeMode.dark: '어둡게',
                                },
                                onChanged: (v) => s.themeMode = v,
                              ),
                            ),
                            _SettingsRow(
                              icon: Symbols.format_size,
                              title: '글씨 크기',
                              trailing: _ValuePicker<double>(
                                value: s.textScale,
                                options: <double, String>{
                                  0.9: '작게',
                                  1.0: '보통',
                                  1.12: '크게',
                                  1.25: '더 크게',
                                  1.4: '아주 크게',
                                },
                                onChanged: (v) => s.textScale = v,
                              ),
                            ),
                            _SettingsRow(
                              icon: Symbols.keyboard_return,
                              title: 'Enter 키로 보내기',
                              subtitle: s.enterSends
                                  ? '줄바꿈은 Shift+Enter'
                                  : 'Enter 는 줄바꿈, 보내기는 ${mod}Enter',
                              trailing: Switch(
                                value: s.enterSends,
                                onChanged: (v) => s.enterSends = v,
                              ),
                            ),
                            _SettingsRow(
                              icon: Symbols.link,
                              title: '링크 미리보기',
                              subtitle: '링크의 제목과 이미지를 불러옵니다 (스팸 폴더 제외)',
                              trailing: Switch(
                                value: s.linkPreviews,
                                onChanged: (v) => s.linkPreviews = v,
                              ),
                            ),
                          ]),
                          if (tab == '잠금')
                          _SettingsGroup(label: '잠금', children: [
                            _SettingsRow(
                              icon: Symbols.lock,
                              title: '앱 잠금',
                              subtitle: '잠금 번호는 휴대폰 번호 뒤 4자리입니다',
                              trailing: Switch(
                                value: s.lockEnabled,
                                onChanged: (v) async {
                                  if (v) {
                                    // 잠금 번호 = 휴대폰 번호 뒤 4자리 (자동).
                                    // 번호를 못 가져온 경우에만 한 번 입력받는다.
                                    final pin = s.phoneLast4 ??
                                        await askPin(ctx,
                                            title: '휴대폰 번호 뒤 4자리',
                                            hint:
                                                '휴대폰에서 번호를 자동으로 가져오지 못했습니다. 잠금 번호로 쓸 휴대폰 번호 뒤 4자리를 입력해 주세요.');
                                    if (pin == null) return;
                                    await s.setPin(pin);
                                    if (ctx.mounted) {
                                      ScaffoldMessenger.of(ctx).showSnackBar(
                                          const SnackBar(
                                              content: Text(
                                                  '잠금을 켰습니다. 잠금 번호는 휴대폰 번호 뒤 4자리입니다.')));
                                    }
                                  } else {
                                    final pin = await askPin(ctx,
                                        title: '잠금 해제 확인');
                                    if (pin == null) return;
                                    if (s.checkPin(pin)) {
                                      await s.clearPin();
                                    } else if (ctx.mounted) {
                                      ScaffoldMessenger.of(ctx).showSnackBar(
                                          const SnackBar(
                                              content: Text('번호가 맞지 않습니다')));
                                    }
                                  }
                                },
                              ),
                            ),
                            if (s.lockEnabled)
                              _SettingsRow(
                                icon: Symbols.timer,
                                title: '자동 잠금',
                                trailing: _ValuePicker<int>(
                                  value: s.lockMinutes,
                                  options: const {
                                    1: '1분 후',
                                    5: '5분 후',
                                    15: '15분 후',
                                    30: '30분 후',
                                    0: '앱을 시작할 때만',
                                  },
                                  onChanged: (v) => s.lockMinutes = v,
                                ),
                              ),
                            if (s.lockEnabled)
                              _SettingsRow(
                                icon: Symbols.visibility_off,
                                title: '잠금 중에는 알림 내용 숨기기',
                                subtitle: '잠겨 있을 때 온 문자는 보낸 사람과 내용을 가립니다',
                                trailing: Switch(
                                  value: s.hidePreviewWhenLocked,
                                  onChanged: (v) =>
                                      s.hidePreviewWhenLocked = v,
                                ),
                              ),
                            if (s.lockEnabled)
                              _SettingsRow(
                                icon: Symbols.lock_clock,
                                title: '지금 잠그기',
                                trailing: _KeyHint('${mod}L'),
                                onTap: s.lockNow,
                              ),
                          ]),
                          if (tab == '일반')
                          _SettingsGroup(label: '일반', children: [
                            if (Platform.isWindows)
                              _AutostartTile(onChanged: (v) {
                                _autostart = v;
                                _updateTrayMenu(force: true);
                              }),
                            _SettingsRow(
                              icon: Symbols.keyboard,
                              title: '단축키',
                              trailing: Icon(Symbols.chevron_right,
                                  size: 22, color: c.onSurfaceVariant),
                              onTap: () => _openShortcuts(ctx),
                            ),
                          ]),
                          if (tab == '계정')
                          _SettingsGroup(label: '계정', children: [
                            _SettingsRow(
                              icon: Symbols.logout,
                              title: '로그아웃',
                              subtitle: '휴대폰과의 연결을 해제합니다',
                              danger: true,
                              onTap: () async {
                                Navigator.pop(ctx);
                                await s.logout();
                                await clearLoginCookies();
                              },
                            ),
                          ]),
                          if (tab == '계정') ...[
                            const SizedBox(height: 6),
                            Text('$kAppName  ·  버전 $kVersion',
                                style: TextStyle(
                                    fontSize: 12, color: c.onSurfaceVariant)),
                          ],
                        ],
                      )),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _openShortcuts(BuildContext context) {
    final mod = Platform.isMacOS ? '⌘' : 'Ctrl+';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('단축키'),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final e in <List<String>>[
                  ['새 대화', 'N'],
                  ['대화 목록 검색', 'F / K'],
                  ['대화 안에서 검색', 'Shift+F'],
                  ['위·아래 대화로 이동', '↑ / ↓'],
                  ['대화창 접기·펼치기', '\\'],
                  ['지금 잠그기 (잠금 사용 시)', 'L'],
                  ['파일 첨부', 'O'],
                  ['사진 붙여넣기', 'V'],
                  ['설정', ','],
                  ['창 숨기기', 'W'],
                  ['종료', 'Q'],
                ])
                  _ShortcutRow(e[0], '$mod${e[1]}'),
                _ShortcutRow(
                    '보내기 / 줄바꿈',
                    s.enterSends
                        ? 'Enter / Shift+Enter'
                        : '${mod}Enter / Enter'),
                const _ShortcutRow('취소·뒤로·대화 닫기', 'Esc'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('닫기')),
        ],
      ),
    );
  }

  Widget _page() {
    switch (s.phase) {
      case Phase.loading:
        return const Center(child: CircularProgressIndicator());
      case Phase.loggedOut:
      case Phase.pairing:
        return LoginPage(state: s);
      case Phase.ready:
        if (s.locked) return LockScreen(state: s);
        return HomePage(state: s, onSettings: _openSettings, onQuit: _quit);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final unread = s.phase == Phase.ready ? s.unreadCount : 0;
    return Scaffold(
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _touch(),
        onPointerHover: (_) => _touch(),
        child: Column(
        children: [
          // 앱과 하나로 이어진 타이틀바
          SizedBox(
            // macOS: 신호등 버튼(세로 중심 16)과 같은 줄에 맞춘다
            height: Platform.isMacOS ? 32 : 44,
            child: Row(
              children: [
                Expanded(
                  child: DragToMoveArea(
                    child: Row(
                      children: [
                        SizedBox(width: Platform.isMacOS ? 76 : 22),
                        // 프로그램 아이콘: 한 번 누르면 창 메뉴(이동·크기·닫기), 두 번 누르면 닫기
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: Platform.isWindows
                              ? () => windowManager.popUpWindowMenu()
                              : null,
                          onSecondaryTap: Platform.isWindows
                              ? () => windowManager.popUpWindowMenu()
                              : null,
                          onDoubleTap: Platform.isWindows
                              ? () => windowManager.close()
                              : null,
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: Platform.isMacOS ? 5 : 8),
                            child: Image.asset('assets/app_icon.png',
                                width: Platform.isMacOS ? 16 : 18,
                                height: Platform.isMacOS ? 16 : 18),
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(kAppName,
                            style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: c.onSurfaceVariant)),
                        if (unread > 0) ...[
                          const SizedBox(width: 8),
                          Text('$unread',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: c.primary)),
                        ],
                        const Spacer(),
                      ],
                    ),
                  ),
                ),
                // 창 제어 버튼도 앱의 헤더 아이콘과 같은 선 아이콘·같은 모양으로
                if (!Platform.isMacOS) ...[
                  HeaderIcon(
                    icon: Symbols.remove,
                    tooltip: '최소화',
                    box: 32,
                    iconSize: 20,
                    onTap: () => windowManager.minimize(),
                  ),
                  const SizedBox(width: 4),
                  HeaderIcon(
                    icon: _maximized
                        ? Symbols.filter_none
                        : Symbols.crop_square,
                    tooltip: _maximized ? '이전 크기로' : '최대화',
                    box: 32,
                    iconSize: _maximized ? 16 : 18,
                    onTap: () => _maximized
                        ? windowManager.unmaximize()
                        : windowManager.maximize(),
                  ),
                  const SizedBox(width: 4),
                  HeaderIcon(
                    icon: Symbols.close,
                    tooltip: '닫기 (트레이로 숨김)',
                    box: 32,
                    iconSize: 20,
                    danger: true,
                    onTap: () => windowManager.close(),
                  ),
                  const SizedBox(width: 10),
                ],
              ],
            ),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: KeyedSubtree(
                key: ValueKey('${s.phase.name}-${s.locked}'),
                child: _page(),
              ),
            ),
          ),
        ],
      )),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow(this.label, this.keys);
  final String label, keys;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          Text(keys,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: c.onSurfaceVariant)),
        ],
      ),
    );
  }
}

const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
const _runName = 'GoogleMessages';

Future<bool> autostartEnabled() async {
  try {
    final r = await Process.run('reg', ['query', _runKey, '/v', _runName]);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// 성공하면 true
Future<bool> setAutostart(bool on) async {
  try {
    final r = on
        ? await Process.run('reg', [
            'add', _runKey, '/v', _runName, '/t', 'REG_SZ', '/d',
            '"${Platform.resolvedExecutable}"', '/f',
          ])
        : await Process.run('reg', ['delete', _runKey, '/v', _runName, '/f']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Windows 시작 시 자동 실행 (현재 사용자 레지스트리 Run 키)
class _AutostartTile extends StatefulWidget {
  const _AutostartTile({this.onChanged});
  final ValueChanged<bool>? onChanged;

  @override
  State<_AutostartTile> createState() => _AutostartTileState();
}

class _AutostartTileState extends State<_AutostartTile> {
  bool? _on;

  @override
  void initState() {
    super.initState();
    autostartEnabled().then((v) {
      if (mounted) setState(() => _on = v);
    });
  }

  Future<void> _set(bool v) async {
    if (await setAutostart(v) && mounted) {
      setState(() => _on = v);
      widget.onChanged?.call(v);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsRow(
      icon: Symbols.rocket_launch,
      title: 'Windows 시작 시 자동 실행',
      trailing: Switch(
        value: _on ?? false,
        onChanged: _on == null ? null : _set,
      ),
    );
  }
}


/// 설정: 제목이 붙은 둥근 카드 묶음
/// 설정 창 위쪽의 분류 탭
class _SettingsTab extends StatefulWidget {
  const _SettingsTab(
      {required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<_SettingsTab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final on = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
          decoration: BoxDecoration(
            color: on
                ? c.primary
                : c.onSurface.withValues(alpha: _hover ? 0.08 : 0.04),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Text(widget.label,
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                  color: on ? c.onPrimary : c.onSurfaceVariant)),
        ),
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.label, required this.children});
  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(Divider(
            height: 1,
            thickness: 1,
            indent: 54,
            endIndent: 16,
            color: c.outlineVariant.withValues(alpha: 0.6)));
      }
      rows.add(children[i]);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Column(children: rows),
          ),
        ],
      ),
    );
  }
}

/// 설정의 한 줄: 아이콘 · 제목(설명) · 오른쪽 값
class _SettingsRow extends StatefulWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.danger = false,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool danger;

  @override
  State<_SettingsRow> createState() => _SettingsRowState();
}

class _SettingsRowState extends State<_SettingsRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final fg = widget.danger ? c.error : c.onSurface;
    final row = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      color: _hover && widget.onTap != null
          ? c.onSurface.withValues(alpha: 0.04)
          : Colors.transparent,
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.fromLTRB(16, 9, 12, 9),
      child: Row(
        children: [
          Icon(widget.icon,
              size: 22,
              weight: 300,
              color: widget.danger ? c.error : c.primary),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.title,
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w500, color: fg)),
                if (widget.subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(widget.subtitle!,
                        style: TextStyle(
                            fontSize: 12.5,
                            height: 1.3,
                            color: c.onSurfaceVariant)),
                  ),
              ],
            ),
          ),
          if (widget.trailing != null) ...[
            const SizedBox(width: 10),
            widget.trailing!,
          ],
        ],
      ),
    );
    if (widget.onTap == null) return row;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
          behavior: HitTestBehavior.opaque, onTap: widget.onTap, child: row),
    );
  }
}

/// 값 고르기 (팝업). 고른 뒤 포커스 표시가 남지 않는다.
class _ValuePicker<T> extends StatelessWidget {
  const _ValuePicker(
      {required this.value, required this.options, required this.onChanged});
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) async {
        // 고른 값 옆에 체크 표시, 페이드로 열리고 닫힌다
        final box = context.findRenderObject() as RenderBox?;
        final origin = box == null
            ? d.globalPosition
            : box.localToGlobal(Offset(0, box.size.height + 4));
        final v = await showFadeMenu<T>(
          context: context,
          at: origin,
          minWidth: 170,
          items: [
            for (final e in options.entries)
              PopupMenuItem<T>(
                value: e.key,
                height: 42,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(e.value,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: e.key == value
                                  ? FontWeight.w700
                                  : FontWeight.w400)),
                    ),
                    if (e.key == value)
                      Icon(Icons.check_rounded, size: 18, color: c.primary),
                  ],
                ),
              ),
          ],
        );
        if (v != null) onChanged(v);
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 7, 2, 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(options[value] ?? options.values.first,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: c.onSurface)),
            const SizedBox(width: 3),
            Icon(Symbols.unfold_more,
                size: 17, color: c.onSurfaceVariant),
            const SizedBox(width: 3),
          ],
        ),
      ),
    ));
  }
}

class _KeyHint extends StatelessWidget {
  const _KeyHint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: c.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600, color: c.onSurfaceVariant)),
    );
  }
}
