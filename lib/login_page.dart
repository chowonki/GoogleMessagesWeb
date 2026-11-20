import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'store.dart';

const String kLoginUrl =
    'https://accounts.google.com/AccountChooser?continue=https://messages.google.com/web/config';

const List<String> kRequiredCookies = [
  'SID', 'HSID', 'OSID', 'SSID', 'APISID', 'SAPISID',
];

const String kSafariUA =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/18.6 Safari/605.1.15';
const String kFirefoxWinUA =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:145.0) Gecko/20100101 Firefox/145.0';
const String kFirefoxMacUA =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:145.0) Gecko/20100101 Firefox/145.0';

/// Windows 에서 로그인 창이 쓰는 WebView2 환경 (main 에서 생성)
WebViewEnvironment? webViewEnvironment;
bool webViewAvailable = true;

CookieManager _cookieManager() =>
    CookieManager.instance(webViewEnvironment: webViewEnvironment);

Future<void> clearLoginCookies() async {
  try {
    await _cookieManager().deleteAllCookies();
  } catch (_) {}
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.state});
  final AppState state;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool _showWeb = false;
  bool _compat = false;
  bool _submitted = false;
  bool _osidRetried = false;
  int _webKey = 0;

  AppState get s => widget.state;

  String get _ua {
    if (_compat) return Platform.isMacOS ? kFirefoxMacUA : kFirefoxWinUA;
    return Platform.isMacOS ? kSafariUA : '';
  }

  Future<void> _checkCookies(InAppWebViewController c, WebUri? url) async {
    if (_submitted || url == null) return;
    if (url.host != 'messages.google.com') return;
    final cookies = await _cookieManager().getCookies(
        url: WebUri('https://messages.google.com/web/config'),
        webViewController: c);
    final map = <String, String>{};
    for (final ck in cookies) {
      final v = ck.value?.toString() ?? '';
      if (v.isNotEmpty) map[ck.name] = v;
    }
    // 메시지 서버는 아래 쿠키가 모두 있어야 인증된다. OSID 는 messages.google.com
    // 전용 쿠키라 로그인 직후에는 아직 없을 수 있으므로, 다 모일 때까지 기다린다.
    final missing = kRequiredCookies.where((k) => !map.containsKey(k)).toList();
    if (missing.isNotEmpty) {
      final loggedIn = map.containsKey('SAPISID') && map.containsKey('SID');
      if (loggedIn && !_osidRetried) {
        // 로그인은 됐는데 OSID 가 없으면 메시지 웹 페이지를 한 번 열어 발급받는다
        _osidRetried = true;
        await c.loadUrl(
            urlRequest: URLRequest(
                url: WebUri('https://messages.google.com/web/conversations')));
      }
      return;
    }
    _submitted = true;
    if (mounted) setState(() => _showWeb = false);
    await s.login(map);
    _submitted = false;
  }

  Future<void> _manualCookies() async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('쿠키 직접 입력'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '앱 안에서 Google 로그인이 막힐 때 쓰는 방법입니다.\n'
                'Chrome 등에서 messages.google.com 에 로그인한 뒤, 개발자 도구(F12) → '
                'Network → 아무 요청의 Cookie 헤더 값을 통째로 붙여 넣으세요. '
                '(JSON 형식 {"SID":"…"} 도 가능)',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                maxLines: 6,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'SID=…; HSID=…; SSID=…; APISID=…; SAPISID=…; OSID=…',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('연결')),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    final map = _parseCookies(text.trim());
    if (map.isEmpty) {
      s.setLoginError('쿠키를 읽지 못했습니다. 형식을 확인해 주세요.');
      return;
    }
    final missing = kRequiredCookies.where((k) => !map.containsKey(k)).toList();
    if (missing.isNotEmpty) {
      s.setLoginError('필요한 쿠키가 빠져 있습니다: ${missing.join(', ')}\n'
          'messages.google.com/web/config 요청의 Cookie 헤더를 복사해 주세요.');
      return;
    }
    await s.login(map);
  }

  static Map<String, String> _parseCookies(String text) {
    final map = <String, String>{};
    if (text.startsWith('{')) {
      try {
        (jsonDecode(text) as Map).forEach((k, v) => map['$k'] = '$v');
        return map;
      } catch (_) {}
    }
    var t = text;
    final m = RegExp(r'cookie:\s*', caseSensitive: false).firstMatch(t);
    if (m != null) t = t.substring(m.end);
    for (final part in t.split(';')) {
      final i = part.indexOf('=');
      if (i <= 0) continue;
      final k = part.substring(0, i).trim();
      final v = part.substring(i + 1).trim();
      if (k.isNotEmpty && v.isNotEmpty && !k.contains(' ')) map[k] = v;
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    if (s.phase == Phase.pairing) return _pairing(context);
    if (_showWeb) return _web(context);
    return _intro(context);
  }

  Widget _intro(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset('assets/app_icon.png', width: 84, height: 84),
                const SizedBox(height: 20),
                Text('Google 메시지',
                    style: theme.textTheme.headlineMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text(
                  '휴대폰의 Google 메시지와 같은 Google 계정으로\n로그인하면 컴퓨터에서 문자를 주고받을 수 있습니다.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 28),
                if (s.loginBusy)
                  const Column(children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('휴대폰에 연결하는 중…'),
                  ])
                else ...[
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                        minimumSize: const Size(260, 48)),
                    onPressed: webViewAvailable
                        ? () => setState(() {
                              _webKey++;
                              _osidRetried = false;
                              _showWeb = true;
                            })
                        : null,
                    icon: const Icon(Icons.login),
                    label: const Text('Google 계정으로 로그인'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                      onPressed: _manualCookies,
                      child: const Text('로그인이 막힐 때: 쿠키 직접 입력')),
                  TextButton(
                      onPressed: () async {
                        await clearLoginCookies();
                        s.setLoginError(null);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text(
                                      '저장된 Google 로그인 정보를 지웠습니다. 다른 계정으로 로그인할 수 있습니다.')));
                        }
                      },
                      child: const Text('다른 계정으로 로그인')),
                ],
                if (!webViewAvailable)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                        'Microsoft Edge WebView2 런타임이 없어 로그인 창을 열 수 없습니다.',
                        textAlign: TextAlign.center),
                  ),
                if (s.loginError != null) ...[
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(s.loginError!,
                        style: TextStyle(
                            color: theme.colorScheme.onErrorContainer)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _web(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 720),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: c.outlineVariant),
              ),
              child: Column(
                children: [
                  SizedBox(
                    height: 52,
                    child: Row(
                      children: [
                        const SizedBox(width: 6),
                        IconButton(
                          icon: const Icon(Icons.arrow_back_rounded, size: 20),
                          tooltip: '뒤로',
                          onPressed: () => setState(() => _showWeb = false),
                        ),
                        const Expanded(
                          child: Text('Google 계정 로그인',
                              style: TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w600)),
                        ),
                        Text('호환 모드',
                            style: TextStyle(
                                fontSize: 12, color: c.onSurfaceVariant)),
                        Transform.scale(
                          scale: 0.75,
                          child: Switch(
                            value: _compat,
                            onChanged: (v) => setState(() {
                              _compat = v;
                              _webKey++;
                            }),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                    ),
                  ),
                  Expanded(
                    child: InAppWebView(
                      key: ValueKey('login-$_webKey'),
                      webViewEnvironment: webViewEnvironment,
                      initialUrlRequest: URLRequest(url: WebUri(kLoginUrl)),
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                        transparentBackground: false,
                        thirdPartyCookiesEnabled: true,
                        userAgent: _ua,
                      ),
                      onLoadStop: (c, url) => _checkCookies(c, url),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pairing(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('휴대폰에서 이 이모티콘을 누르세요',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 24),
            Container(
              width: 160,
              height: 160,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(32),
              ),
              child: Text(s.pairEmoji ?? '',
                  style: const TextStyle(fontSize: 96, height: 1.1)),
            ),
            const SizedBox(height: 24),
            Text(
              '휴대폰의 Google 메시지 앱에 확인 화면이 표시됩니다.\n보이지 않으면 휴대폰에서 메시지 앱을 열어 주세요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(height: 16),
            TextButton(onPressed: s.cancelLogin, child: const Text('취소')),
          ],
        ),
      ),
    );
  }
}
