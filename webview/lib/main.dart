// Google Messages for Web 을 시스템 WebView(Windows: WebView2, macOS: WKWebView)로 감싼 앱
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
import 'package:windows_single_instance/windows_single_instance.dart';
import 'package:windows_taskbar/windows_taskbar.dart';

import 'window_controls.dart';

const String kAppName = 'Google 메시지';
const String kHomeUrl = 'https://messages.google.com/web/';

/// macOS 의 WebView(WKWebView)는 Safari 와 같은 엔진이므로 Safari 로 알린다.
/// (기본 표기로는 Google 로그인이 "안전하지 않은 브라우저"로 막힐 수 있다)
const String kSafariUA =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/18.6 Safari/605.1.15';

/// 이미지 글자 인식. 모두 이 컴퓨터 안에서 처리된다.
/// - Windows: 앱과 함께 들어 있는 보조 프로그램(gm_ocr.exe, Windows 내장 OCR)을
///   이미지마다 한 번 실행해 결과(JSON 한 줄)를 받는다.
/// - macOS: 앱 쪽 코드(AppDelegate.swift)가 내장 Vision 으로 읽어 같은 형식으로 돌려준다.
class ImageOcr {
  String? _helper; // 한 번 찾아 두는 보조 프로그램 경로
  bool _unavailable = false;
  int _seq = 0;

  String? _findHelper() {
    if (!Platform.isWindows) return null;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final path = [
      exeDir,
      'data',
      'flutter_assets',
      'assets',
      'ocr',
      'gm_ocr.exe'
    ].join(Platform.pathSeparator);
    return File(path).existsSync() ? path : null;
  }

  /// [dataUrl] 은 "data:image/png;base64,..." 형태. 실패하면 null.
  Future<Map<String, dynamic>?> recognize(String dataUrl) async {
    if (_unavailable) return null;
    final helper = Platform.isMacOS ? '' : _helper ??= _findHelper();
    if (helper == null) {
      _unavailable = true;
      return null;
    }
    final comma = dataUrl.indexOf(',');
    if (comma < 0) return null;
    File? file;
    try {
      final ext = dataUrl.startsWith('data:image/jpeg') ? 'jpg' : 'png';
      final dir = await getTemporaryDirectory();
      final sep = Platform.pathSeparator;
      file = File('${dir.path}${sep}gm_ocr_${pid}_${_seq++}.$ext');
      await file.writeAsBytes(base64Decode(dataUrl.substring(comma + 1)),
          flush: true);
      if (Platform.isMacOS) {
        final json = await const MethodChannel('gm/ocr')
            .invokeMethod<String>('recognize', file.path)
            .timeout(const Duration(seconds: 20));
        if (json == null || json.isEmpty) return null;
        return jsonDecode(json) as Map<String, dynamic>;
      }
      final result = await Process.run(helper, [file.path],
              stdoutEncoding: utf8, stderrEncoding: utf8)
          .timeout(const Duration(seconds: 20));
      final line = const LineSplitter()
          .convert(result.stdout as String)
          .lastWhere((l) => l.trim().isNotEmpty, orElse: () => '')
          .trim();
      if (line.isEmpty) return null;
      return jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return null;
    } finally {
      try {
        await file?.delete();
      } catch (_) {}
    }
  }
}

final imageOcr = ImageOcr();

/// 페이지에 넣는 스크립트 (assets/js). 앱을 시작할 때 한 번 읽는다.
const List<String> kPageScriptAssets = [
  'assets/js/theme.js',
  'assets/js/notification.js',
  'assets/js/context_menu.js',
  'assets/js/live_text.js',
];
List<String> pageScripts = const [];

WebViewEnvironment? webViewEnvironment;
bool webViewAvailable = true;

/// 지금 페이지 머리말의 모습. 창 단추와 앱의 밝게/어둡게가 이 값을 따른다.
late final ValueNotifier<PageChrome> pageChrome;

Future<void> showMainWindow() async {
  if (await windowManager.isMinimized()) await windowManager.restore();
  await windowManager.show();
  await windowManager.focus();
  onMainWindowShown?.call();
}

/// 숨겨졌던 창을 다시 보인 뒤 호출된다 (작업 표시줄 단추가 새로 생기므로 배지를 다시 얹는다)
void Function()? onMainWindowShown;

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows) {
    await WindowsSingleInstance.ensureSingleInstance(
      args,
      'google_messages_web_single_instance',
      onSecondWindow: (_) => showMainWindow(),
    );
  }

  final support = await getApplicationSupportDirectory();
  if (Platform.isWindows) {
    // 기존 앱의 로그인 창과 같은 WebView2 환경 설정
    try {
      webViewAvailable = await WebViewEnvironment.getAvailableVersion() != null;
      if (webViewAvailable) {
        webViewEnvironment = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(
            userDataFolder: '${support.path}${Platform.pathSeparator}WebView2',
            additionalBrowserArguments:
                '--disable-features=UserAgentClientHint',
          ),
        );
      }
    } catch (_) {
      webViewAvailable = false;
    }
  }

  pageScripts = [
    // 창 단추를 앱이 그릴 때만 페이지가 그 자리를 비우고 머리말의 빈 구간을 알려 준다 (theme.js)
    if (Platform.isWindows)
      'window.__gmCaptionWidth = ${kCaptionWidth.round()};',
    for (final asset in kPageScriptAssets) await rootBundle.loadString(asset),
  ];

  await windowManager.ensureInitialized();
  await localNotifier.setup(
    appName: kAppName,
    shortcutPolicy: ShortcutPolicy.requireCreate,
  );

  final prefs = await SharedPreferences.getInstance();
  final saved = _loadBounds(prefs);
  final startHidden = args.contains('--hidden');

  final options = WindowOptions(
    size: saved?.size ?? const Size(1100, 760),
    minimumSize: const Size(420, 480),
    center: saved == null,
    title: kAppName,
    // Windows: 제목 표시줄 없이 창 단추만 페이지 머리말 위에 얹는다 (window_controls.dart)
    titleBarStyle: Platform.isWindows ? TitleBarStyle.hidden : null,
  );
  pageChrome = ValueNotifier(PageChrome.load(
      prefs, WidgetsBinding.instance.platformDispatcher.platformBrightness));
  await windowManager.waitUntilReadyToShow(options, () async {
    applyWindowFrameBrightness(pageChrome.value.isDark);
    if (saved != null) await windowManager.setBounds(saved);
    if (prefs.getBool('maximized') ?? false) await windowManager.maximize();
    await windowManager.setPreventClose(true);
    if (prefs.getBool('alwaysOnTop') ?? false) {
      await windowManager.setAlwaysOnTop(true);
    }
    if (!startHidden) {
      await windowManager.show();
      await windowManager.focus();
    }
  });

  runApp(MessagesWebApp(prefs: prefs));
}

// ───────── Windows 시작 시 자동 실행 (현재 사용자 레지스트리 Run 키) ─────────
const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
const _runName = 'GoogleMessagesWeb';

Future<bool> autostartEnabled() async {
  try {
    final r = await Process.run('reg', ['query', _runKey, '/v', _runName]);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// 성공하면 true. 자동 실행으로 켜질 때는 창 없이 트레이에만 뜬다(--hidden).
Future<bool> setAutostart(bool on) async {
  try {
    final r = on
        ? await Process.run('reg', [
            'add',
            _runKey,
            '/v',
            _runName,
            '/t',
            'REG_SZ',
            '/d',
            '"${Platform.resolvedExecutable}" --hidden',
            '/f',
          ])
        : await Process.run('reg', ['delete', _runKey, '/v', _runName, '/f']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Rect? _loadBounds(SharedPreferences prefs) {
  final x = prefs.getDouble('x'), y = prefs.getDouble('y');
  final w = prefs.getDouble('w'), h = prefs.getDouble('h');
  if (x == null || y == null || w == null || h == null) return null;
  if (w < 300 || h < 300) return null;
  return Rect.fromLTWH(x, y, w, h);
}

class MessagesWebApp extends StatelessWidget {
  const MessagesWebApp({super.key, required this.prefs});
  final SharedPreferences prefs;

  @override
  Widget build(BuildContext context) {
    final home = HomePage(prefs: prefs);
    return ValueListenableBuilder<PageChrome>(
      valueListenable: pageChrome,
      builder: (context, colors, _) => MaterialApp(
        title: kAppName,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF1A73E8)),
        darkTheme: ThemeData(
            colorSchemeSeed: const Color(0xFF1A73E8),
            brightness: Brightness.dark),
        themeMode: colors.isDark ? ThemeMode.dark : ThemeMode.light,
        home: home,
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.prefs});
  final SharedPreferences prefs;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WindowListener, TrayListener {
  InAppWebViewController? _web;
  bool _closeToTray = true;
  bool _alwaysOnTop = false;
  int _unread = 0;
  int _badgeShown = 0;
  bool _loading = true;
  bool _maximized = false;
  bool _pageReady = false; // 페이지가 머리말 모습을 알려 왔다
  String? _loadError;

  SharedPreferences get prefs => widget.prefs;

  @override
  void initState() {
    super.initState();
    _closeToTray = prefs.getBool('closeToTray') ?? true;
    _alwaysOnTop = prefs.getBool('alwaysOnTop') ?? false;
    windowManager.addListener(this);
    onMainWindowShown = () => _applyBadge(force: true);
    trayManager.addListener(this);
    _initTray();
    windowManager.isMaximized().then((v) {
      if (mounted && v != _maximized) setState(() => _maximized = v);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    super.dispose();
  }

  // ───────── 트레이 ─────────
  Future<void> _initTray() async {
    await trayManager.setIcon(
      Platform.isWindows ? 'assets/tray.ico' : 'assets/tray.png',
      // macOS 메뉴 막대: 검은 그림을 밝기에 맞춰 자동으로 칠한다
      isTemplate: Platform.isMacOS,
    );
    await trayManager.setToolTip(kAppName);
    if (Platform.isWindows) _autostart = await autostartEnabled();
    await _updateTrayMenu();
  }

  bool _autostart = false;

  Future<void> _updateTrayMenu() async {
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: '$kAppName 열기'),
      MenuItem(key: 'reload', label: '새로고침'),
      MenuItem.separator(),
      MenuItem.checkbox(
        key: 'closeToTray',
        label: Platform.isMacOS ? '창을 닫아도 메뉴 막대에 남기기' : '닫기 버튼으로 트레이에 숨기기',
        checked: _closeToTray,
      ),
      if (Platform.isWindows)
        MenuItem.checkbox(
          key: 'autostart',
          label: 'Windows 시작 시 자동 실행',
          checked: _autostart,
        ),
      MenuItem.checkbox(
        key: 'alwaysOnTop',
        label: '항상 위에 표시',
        checked: _alwaysOnTop,
      ),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: '종료'),
    ]));
  }

  // macOS 메뉴 막대 아이콘은 누르면 메뉴가 뜨는 것이 관례다
  @override
  void onTrayIconMouseDown() =>
      Platform.isMacOS ? trayManager.popUpContextMenu() : showMainWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        showMainWindow();
      case 'reload':
        _web?.loadUrl(urlRequest: URLRequest(url: WebUri(kHomeUrl)));
        showMainWindow();
      case 'closeToTray':
        _closeToTray = !_closeToTray;
        prefs.setBool('closeToTray', _closeToTray);
        _updateTrayMenu();
      case 'autostart':
        setAutostart(!_autostart).then((ok) {
          if (ok) _autostart = !_autostart;
          _updateTrayMenu();
        });
      case 'alwaysOnTop':
        _alwaysOnTop = !_alwaysOnTop;
        prefs.setBool('alwaysOnTop', _alwaysOnTop);
        windowManager.setAlwaysOnTop(_alwaysOnTop);
        _updateTrayMenu();
      case 'quit':
        _quit();
    }
  }

  // ───────── 작업 표시줄 배지 · 깜빡임 (Windows) ─────────
  /// 안 읽은 개수를 작업 표시줄 아이콘 위에 빨간 배지로 얹는다.
  /// 창이 숨겨져 있으면 작업 표시줄 단추가 없으므로 다시 보일 때 얹는다.
  Future<void> _applyBadge({bool force = false}) async {
    if (!force && _badgeShown == _unread) return;
    if (Platform.isMacOS) {
      // macOS: Dock 아이콘의 빨간 배지
      try {
        await windowManager.setBadgeLabel(_unread > 0 ? '$_unread' : '');
        _badgeShown = _unread;
      } catch (_) {}
      return;
    }
    if (!Platform.isWindows) return;
    try {
      if (_unread <= 0) {
        await WindowsTaskbar.resetOverlayIcon();
      } else {
        final name = _unread > 9 ? '9plus' : '$_unread';
        await WindowsTaskbar.setOverlayIcon(
          ThumbnailToolbarAssetIcon('assets/badge/$name.ico'),
          tooltip: '안 읽은 메시지 $_unread개',
        );
      }
      _badgeShown = _unread;
    } catch (_) {
      // 배지 없이 계속
    }
  }

  /// 창이 앞에 있지 않으면 작업 표시줄 단추를 깜빡인다 (macOS: Dock 아이콘을 한 번 튕긴다)
  Future<void> _flash() async {
    if (Platform.isMacOS) {
      try {
        if (!await windowManager.isFocused()) {
          await const MethodChannel('gm/app').invokeMethod('bounce');
        }
      } catch (_) {}
      return;
    }
    if (!Platform.isWindows) return;
    try {
      if (await windowManager.isFocused()) return;
      await WindowsTaskbar.setFlashTaskbarAppIcon(
        mode: TaskbarFlashMode.tray | TaskbarFlashMode.timernofg,
        flashCount: 5,
      );
    } catch (_) {}
  }

  // 주의: 창 포커스 이벤트에서 작업 표시줄을 건드리면 포커스 이벤트가 다시 일어나
  // 무한 반복된다. 깜빡임은 창이 앞으로 오면 저절로 멈추므로(timernofg) 따로 끄지 않는다.

  // ───────── 창 ─────────
  Future<void> _saveBounds() async {
    final maximized = await windowManager.isMaximized();
    await prefs.setBool('maximized', maximized);
    if (maximized || await windowManager.isMinimized()) return;
    final b = await windowManager.getBounds();
    await prefs.setDouble('x', b.left);
    await prefs.setDouble('y', b.top);
    await prefs.setDouble('w', b.width);
    await prefs.setDouble('h', b.height);
  }

  @override
  void onWindowResized() => _saveBounds();

  @override
  void onWindowMoved() => _saveBounds();

  @override
  void onWindowMaximize() {
    setState(() => _maximized = true);
    _saveBounds();
  }

  @override
  void onWindowUnmaximize() {
    setState(() => _maximized = false);
    _saveBounds();
  }

  @override
  void onWindowClose() async {
    await _saveBounds();
    if (_closeToTray) {
      await windowManager.hide(); // 알림을 계속 받기 위해 트레이에 남는다
    } else {
      await _quit();
    }
  }

  Future<void> _quit() async {
    await _saveBounds();
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  // ───────── 웹 ─────────
  /// 창 안에서 열 주소: Google 메시지와 Google 계정 로그인 화면
  bool _isInternal(Uri? url) {
    if (url == null) return false;
    if (url.scheme == 'about' || url.scheme == 'blob' || url.scheme == 'data') {
      return true;
    }
    if (url.scheme != 'https') return false;
    final h = url.host;
    return h == 'google.com' ||
        h.endsWith('.google.com') ||
        h.endsWith('.google.co.kr') ||
        h == 'accounts.youtube.com';
  }

  Future<void> _openExternal(Uri? url) async {
    if (url == null) return;
    if (!const ['https', 'http', 'mailto', 'tel'].contains(url.scheme)) return;
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  void _notify(String title, String body) {
    final n =
        LocalNotification(title: title.isEmpty ? kAppName : title, body: body);
    n.onClick = () async {
      await showMainWindow();
      await _web?.evaluateJavascript(
          source:
              'window.__gmNotificationClicked && window.__gmNotificationClicked();');
    };
    n.show();
    _flash();
  }

  void _onTitle(String? title) {
    final m = RegExp(r'^\((\d+)\+?\)').firstMatch(title ?? '');
    final count = m == null ? 0 : int.parse(m.group(1)!);
    if (count == _unread) return;
    if (count > _unread) _flash();
    _unread = count;
    trayManager
        .setToolTip(count > 0 ? '$kAppName - 안 읽은 메시지 $count개' : kAppName);
    _applyBadge();
  }

  /// 페이지가 알려 준 머리말 모습(theme.js)을 창 단추·창 테두리에 반영한다
  void _onPageChrome(List<dynamic> args) {
    if (args.length < 3 || args[0] is! num || args[1] is! num) return;
    final spans = args[2];
    final chrome = PageChrome(
      Color(0xFF000000 | (args[0] as num).toInt()),
      (args[1] as num) + 0.0,
      [
        if (spans is List)
          for (final x in spans)
            if (x is num) x + 0.0,
      ],
    );
    if (!_pageReady) setState(() => _pageReady = true);
    final previous = pageChrome.value;
    if (chrome == previous) return;
    pageChrome.value = chrome;
    chrome.save(prefs);
    if (chrome.isDark != previous.isDark) {
      applyWindowFrameBrightness(chrome.isDark);
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = _content(context);
    if (!Platform.isWindows) return Scaffold(body: content);
    // Windows: 제목 표시줄 없이 화면이 창 전체를 덮고, 창 단추를 그 위에 얹는다
    final pageShown = _pageReady && _loadError == null;
    return Scaffold(
      body: ValueListenableBuilder<PageChrome>(
        valueListenable: pageChrome,
        child: content,
        builder: (context, chrome, content) => Stack(
          children: [
            Positioned.fill(child: content!),
            // 창을 끌어 옮기는 손잡이: 머리말의 빈 구간들.
            // 페이지가 아직 없거나 불러오지 못했을 때는 맨 위 띠 전체.
            for (final (left, width) in pageShown
                ? chrome.dragSpans
                : const [(0.0, double.infinity)])
              Positioned(
                top: 0,
                left: left,
                width: width.isFinite ? width : null,
                right: width.isFinite ? null : kCaptionWidth,
                height: chrome.captionHeight,
                child: const DragToMoveArea(child: SizedBox.expand()),
              ),
            Positioned(
              top: 0,
              right: 0,
              child: WindowControls(chrome: chrome, maximized: _maximized),
            ),
            if (!_maximized)
              const Positioned(
                  top: 0, left: 0, right: 0, child: TopResizeEdge()),
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    if (!webViewAvailable) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Microsoft Edge WebView2 런타임이 없어 화면을 표시할 수 없습니다.\n'
            'WebView2 런타임을 설치한 뒤 다시 실행해 주세요.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return Stack(
      children: [
        InAppWebView(
          webViewEnvironment: webViewEnvironment,
          initialUrlRequest: URLRequest(url: WebUri(kHomeUrl)),
          initialUserScripts: UnmodifiableListView<UserScript>([
            for (final source in pageScripts)
              UserScript(
                source: source,
                injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
              ),
          ]),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            transparentBackground: false,
            thirdPartyCookiesEnabled: true,
            useShouldOverrideUrlLoading: true,
            javaScriptCanOpenWindowsAutomatically: true,
            supportMultipleWindows: true,
            userAgent: Platform.isMacOS ? kSafariUA : '',
            // macOS: 트랙패드로 앞뒤 넘기기, 링크 길게 누르기 미리보기 끄기
            allowsBackForwardNavigationGestures: false,
            allowsLinkPreview: false,
          ),
          onWebViewCreated: (c) {
            _web = c;
            c.addJavaScriptHandler(
                handlerName: 'gmTheme', callback: _onPageChrome);
            c.addJavaScriptHandler(
              handlerName: 'gmOcr',
              callback: (args) async {
                if (args.isEmpty || args[0] is! String) return null;
                return await imageOcr.recognize(args[0] as String);
              },
            );
            c.addJavaScriptHandler(
              handlerName: 'gmCopy',
              callback: (args) {
                if (args.isNotEmpty) {
                  Clipboard.setData(ClipboardData(text: '${args[0]}'));
                }
              },
            );
            c.addJavaScriptHandler(
              handlerName: 'gmNotify',
              callback: (args) {
                final title = args.isNotEmpty ? '${args[0]}' : '';
                final body = args.length > 1 ? '${args[1]}' : '';
                _notify(title, body);
              },
            );
          },
          // 메시지에 들어 있는 외부 링크는 기본 브라우저로 연다
          shouldOverrideUrlLoading: (c, action) async {
            final url = action.request.url;
            if (!action.isForMainFrame || _isInternal(url)) {
              return NavigationActionPolicy.ALLOW;
            }
            _openExternal(url);
            return NavigationActionPolicy.CANCEL;
          },
          // 새 창 요청: Google 주소는 같은 창에서, 나머지는 기본 브라우저로
          onCreateWindow: (c, action) async {
            final url = action.request.url;
            if (_isInternal(url) && url != null && url.scheme == 'https') {
              c.loadUrl(urlRequest: URLRequest(url: url));
            } else {
              _openExternal(url);
            }
            return false;
          },
          onPermissionRequest: (c, request) async {
            return PermissionResponse(
              resources: request.resources,
              action: _isInternal(request.origin)
                  ? PermissionResponseAction.GRANT
                  : PermissionResponseAction.DENY,
            );
          },
          onTitleChanged: (c, title) => _onTitle(title),
          onLoadStart: (c, url) => setState(() {
            _loading = true;
            _loadError = null;
          }),
          onLoadStop: (c, url) => setState(() => _loading = false),
          onReceivedError: (c, request, error) {
            if (request.isForMainFrame ?? false) {
              setState(() {
                _loading = false;
                _loadError = error.description;
              });
            }
          },
        ),
        if (_loading)
          const Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (_loadError != null)
          Positioned.fill(
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('페이지를 불러오지 못했습니다.'),
                    const SizedBox(height: 4),
                    Text(_loadError!,
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => _web?.loadUrl(
                          urlRequest: URLRequest(url: WebUri(kHomeUrl))),
                      child: const Text('다시 시도'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
