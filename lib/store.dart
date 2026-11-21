import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bridge.dart';
import 'models.dart';

enum Phase { loading, loggedOut, pairing, ready }

class ChatState {
  final List<Message> messages = []; // 시간 오름차순
  bool loading = false;
  bool loaded = false;
  bool hasMore = true;
  String? cursorId;
  int cursorTs = 0;
  String? error;
}

class AppState extends ChangeNotifier {
  AppState(this.bridge, this.prefs, this.cacheDir);

  final GmBridge bridge;
  final SharedPreferences prefs;
  final String cacheDir;

  Phase phase = Phase.loading;
  String connState = 'connecting';
  String connMessage = '';

  String? pairEmoji;
  String? loginError;
  bool loginBusy = false;

  final Map<String, Conversation> convs = {};
  String folder = 'inbox';
  String query = '';
  bool convsLoading = false;
  String? convsError;
  String? selectedId;

  final Map<String, ChatState> chats = {};

  /// 대화별로 쓰던 글과 첨부 (창 크기를 바꿔 화면이 다시 만들어져도 남는다)
  final Map<String, String> drafts = {};
  final Map<String, List<String>> draftFiles = {};
  final Map<String, Uint8List> avatars = {};
  final Set<String> _avatarRequested = {};
  final Map<String, DateTime> typing = {};
  final Set<String> _notified = {};
  final Map<String, Future<String>> _mediaFutures = {};

  late final Set<String> _pinned =
      (prefs.getStringList('pinned') ?? const []).toSet();
  late final Set<String> _muted =
      (prefs.getStringList('muted') ?? const []).toSet();

  bool isPinned(Conversation c) => c.pinned || _pinned.contains(c.id);
  bool isMuted(String id) => _muted.contains(id);

  void togglePin(String id) {
    if (!_pinned.remove(id)) _pinned.add(id);
    prefs.setStringList('pinned', _pinned.toList());
    notifyListeners();
  }

  /// 알림 끄기/켜기. 휴대폰의 대화 알림 설정에도 함께 반영한다 (웹과 같음).
  void toggleMute(String id) {
    final mute = !_muted.remove(id);
    if (mute) _muted.add(id);
    prefs.setStringList('muted', _muted.toList());
    notifyListeners();
    bridge.call('updateConversation', {
      'convId': id,
      'action': mute ? 'mute' : 'unmute',
    }).catchError((_) => null);
  }

  // ───────── 휴대폰 정보 (SIM · RCS) ─────────
  /// 휴대폰의 SIM 목록: {participantId, carrier, number, color, slot, rcs}
  List<Map<String, dynamic>> sims = const [];

  /// 휴대폰의 채팅(RCS) 설정: {enabled, readReceipts, typingIndicators}
  Map<String, dynamic> rcs = const {};
  String phoneAppVersion = '';

  /// 대화별로 직접 고른 보내는 SIM (없으면 대화의 기본 SIM)
  late final Map<String, String> _simFor = () {
    try {
      return Map<String, String>.from(
          jsonDecode(prefs.getString('simFor') ?? '{}') as Map);
    } catch (_) {
      return <String, String>{};
    }
  }();

  /// 이 대화에서 보낼 때 쓸 SIM 의 participantId
  String simIdFor(Conversation c) {
    final chosen = _simFor[c.id];
    if (chosen != null && sims.any((s) => s['participantId'] == chosen)) {
      return chosen;
    }
    if (sims.any((s) => s['participantId'] == c.outgoingId)) {
      return c.outgoingId;
    }
    return sims.isEmpty ? '' : '${sims.first['participantId']}';
  }

  void setSimFor(String convId, String simId) {
    _simFor[convId] = simId;
    prefs.setString('simFor', jsonEncode(_simFor));
    notifyListeners();
  }

  static String simLabel(Map<String, dynamic> sim) {
    final carrier = '${sim['carrier'] ?? ''}';
    final number = '${sim['number'] ?? ''}';
    final slot = (sim['slot'] as num?)?.toInt() ?? 0;
    return [
      if (slot > 0) 'SIM $slot',
      if (carrier.isNotEmpty) carrier,
      if (number.isNotEmpty) number,
    ].join(' · ');
  }

  // ───────── 휴대폰 상태 알림 (웹의 알림 띠와 같음) ─────────
  bool phoneOnMobileData = false;
  bool phoneBatteryLow = false;

  /// 다른 곳(브라우저 등)에서 메시지 웹을 열어 이 앱이 비활성화됨
  bool sessionInactive = false;
  bool mobileDataDismissed = false;
  bool batteryDismissed = false;

  void dismissAlert(String which) {
    if (which == 'data') mobileDataDismissed = true;
    if (which == 'battery') batteryDismissed = true;
    notifyListeners();
  }

  /// "여기서 사용": 이 앱을 다시 활성 세션으로 만든다
  Future<void> useHere() async {
    try {
      await bridge.call('setActive');
      sessionInactive = false;
      notifyListeners();
      loadConversations();
      final sel = selectedId;
      if (sel != null) loadMessages(sel, refresh: true);
    } catch (e) {
      connMessage = e.toString();
      notifyListeners();
    }
  }

  void _onAlert(String alert) {
    switch (alert) {
      case 'MOBILE_DATA_CONNECTION':
        phoneOnMobileData = true;
        mobileDataDismissed = false;
      case 'MOBILE_WIFI_CONNECTION':
        phoneOnMobileData = false;
      case 'MOBILE_BATTERY_LOW':
        phoneBatteryLow = true;
        batteryDismissed = false;
      case 'MOBILE_BATTERY_RESTORED':
        phoneBatteryLow = false;
      case 'BROWSER_INACTIVE':
      case 'BROWSER_INACTIVE_FROM_TIMEOUT':
      case 'BROWSER_INACTIVE_FROM_INACTIVITY':
        sessionInactive = true;
      case 'BROWSER_ACTIVE':
        if (sessionInactive) {
          sessionInactive = false;
          loadConversations();
        }
      default:
        return;
    }
    notifyListeners();
  }

  // ───────── 입력 중 표시 보내기 (RCS 대화) ─────────
  final Map<String, Timer> _typingStop = {};
  final Map<String, DateTime> _typingSent = {};

  /// 입력창에 글을 쓰는 동안 부른다. [stop] 이면 입력을 멈춘 것으로 알린다.
  void userTyping(String convId, {bool stop = false}) {
    final active = _typingStop.containsKey(convId);
    if (stop) {
      if (!active) return;
      _typingStop.remove(convId)?.cancel();
      _typingSent.remove(convId);
      bridge.call('typing', {'convId': convId, 'typing': false}).catchError(
          (_) => null);
      return;
    }
    if (!sendTyping || connState != 'connected') return;
    final c = convs[convId];
    if (c == null || !c.isRcs || c.readOnly) return;
    _typingStop[convId]?.cancel();
    _typingStop[convId] =
        Timer(const Duration(seconds: 6), () => userTyping(convId, stop: true));
    final last = _typingSent[convId];
    final now = DateTime.now();
    if (last == null || now.difference(last).inSeconds >= 8) {
      _typingSent[convId] = now;
      bridge.call('typing', {'convId': convId, 'typing': true}).catchError(
          (_) => null);
    }
  }

  /// 내 쪽 참여자 번호들 (공감을 내가 눌렀는지 가릴 때 쓴다)
  Set<String> myIds(Conversation c) => {
        if (c.outgoingId.isNotEmpty) c.outgoingId,
        for (final p in c.participants)
          if (p.isMe) p.id,
        for (final s in sims) '${s['participantId']}',
      };

  Future<void> renameGroup(String convId, String name) =>
      bridge.call('updateConversation',
          {'convId': convId, 'action': 'rename', 'name': name});

  /// 대화 목록에서 위(-1)/아래(+1) 대화로 이동
  void moveSelection(int delta) {
    final list = visible;
    if (list.isEmpty) return;
    final i = list.indexWhere((c) => c.id == selectedId);
    final next = i < 0
        ? (delta > 0 ? 0 : list.length - 1)
        : (i + delta).clamp(0, list.length - 1);
    if (list[next].id != selectedId) select(list[next].id);
  }

  bool windowActive = true;
  void Function(Conversation? conv, Message msg)? onIncoming;
  VoidCallback? onUnreadChanged;

  // ───────── 설정 ─────────
  bool get notificationsEnabled => prefs.getBool('notify') ?? true;
  set notificationsEnabled(bool v) {
    prefs.setBool('notify', v);
    notifyListeners();
  }

  /// 잠금 중에 온 알림의 보낸 사람·내용을 가릴지 (기본: 가리지 않음)
  bool get hidePreviewWhenLocked =>
      prefs.getBool('hidePreviewWhenLocked') ?? false;
  set hidePreviewWhenLocked(bool v) {
    prefs.setBool('hidePreviewWhenLocked', v);
    notifyListeners();
  }

  /// 직접 고른 알림 소리 파일 (없으면 시스템 기본 소리)
  String? get soundPath {
    final p = prefs.getString('soundPath');
    return p != null && p.isNotEmpty && File(p).existsSync() ? p : null;
  }

  /// 고른 파일을 앱 폴더로 복사해 두고 쓴다 (null 이면 기본 소리로 되돌림)
  Future<void> setSoundFile(String? source) async {
    if (source == null) {
      await prefs.remove('soundPath');
    } else {
      final dot = source.lastIndexOf('.');
      final ext = dot > 0 ? source.substring(dot) : '';
      final dest =
          '$cacheDir${Platform.pathSeparator}notify_${DateTime.now().millisecondsSinceEpoch}$ext';
      await File(source).copy(dest);
      await prefs.setString('soundPath', dest);
    }
    notifyListeners();
  }

  /// 새 메시지 알림 때 소리 재생
  bool get notifySound => prefs.getBool('notifySound') ?? true;
  set notifySound(bool v) {
    prefs.setBool('notifySound', v);
    notifyListeners();
  }

  /// 휴대폰이 모바일 데이터를 쓰고 있을 때 알려 주기
  bool get dataAlert => prefs.getBool('dataAlert') ?? true;
  set dataAlert(bool v) {
    prefs.setBool('dataAlert', v);
    notifyListeners();
  }

  /// 휴대폰 배터리가 부족할 때 알려 주기
  bool get batteryAlert => prefs.getBool('batteryAlert') ?? true;
  set batteryAlert(bool v) {
    prefs.setBool('batteryAlert', v);
    notifyListeners();
  }

  /// 고대비 모드 (글자·경계선을 더 진하게)
  bool get highContrast => prefs.getBool('highContrast') ?? false;
  set highContrast(bool v) {
    prefs.setBool('highContrast', v);
    notifyListeners();
  }

  /// RCS 대화에서 내가 입력 중임을 상대에게 알리기
  bool get sendTyping => prefs.getBool('sendTyping') ?? true;
  set sendTyping(bool v) {
    prefs.setBool('sendTyping', v);
    notifyListeners();
  }

  bool get notifyPreview => prefs.getBool('notifyPreview') ?? true;
  set notifyPreview(bool v) {
    prefs.setBool('notifyPreview', v);
    notifyListeners();
  }

  ThemeMode get themeMode =>
      ThemeMode.values[
          (prefs.getInt('theme') ?? 0).clamp(0, 2)];
  set themeMode(ThemeMode m) {
    prefs.setInt('theme', m.index);
    notifyListeners();
  }

  // ───────── 앱 잠금 (PIN) ─────────
  bool locked = false;

  bool get lockEnabled => prefs.getString('pinHash') != null;

  /// 잠금 번호는 휴대폰 번호 뒤 4자리로 고정한다 (휴대폰 SIM 정보에서 가져옴)
  String? get phoneLast4 => prefs.getString('phoneLast4');

  void _rememberPhoneNumber(dynamic sims) {
    if (sims is! List) return;
    for (final sim in sims) {
      if (sim is! Map) continue;
      final digits = '${sim['number'] ?? ''}'.replaceAll(RegExp(r'[^0-9]'), '');
      if (digits.length >= 8) {
        final last4 = digits.substring(digits.length - 4);
        if (last4 != phoneLast4) {
          prefs.setString('phoneLast4', last4);
          notifyListeners();
        }
        return;
      }
    }
  }

  /// 자동 잠금까지의 분. 0 이면 앱을 시작할 때만 잠근다.
  int get lockMinutes => prefs.getInt('lockMinutes') ?? 5;
  set lockMinutes(int v) {
    prefs.setInt('lockMinutes', v);
    notifyListeners();
  }

  String _hashPin(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();

  bool checkPin(String pin) {
    final h = prefs.getString('pinHash');
    final salt = prefs.getString('pinSalt') ?? '';
    return h != null && _hashPin(pin, salt) == h;
  }

  Future<void> setPin(String pin) async {
    final r = Random.secure();
    final salt = List.generate(16, (_) => r.nextInt(256).toRadixString(16)).join();
    await prefs.setString('pinSalt', salt);
    await prefs.setString('pinHash', _hashPin(pin, salt));
    notifyListeners();
  }

  Future<void> clearPin() async {
    await prefs.remove('pinHash');
    await prefs.remove('pinSalt');
    locked = false;
    notifyListeners();
  }

  void lockNow() {
    if (!lockEnabled || locked) return;
    locked = true;
    notifyListeners();
  }

  bool unlock(String pin) {
    if (!checkPin(pin)) return false;
    locked = false;
    notifyListeners();
    return true;
  }

  /// PIN을 잊었을 때: 로그아웃하면서 잠금도 지운다
  Future<void> resetLockByLogout() async {
    await logout();
    await clearPin();
  }

  // ───────── 목록·대화창 사이 너비 ─────────
  double get paneWidth =>
      (prefs.getDouble('paneW') ?? 372)
          .clamp(280.0, 640.0);

  void setPaneWidth(double w, {bool save = false}) {
    _paneW = w.clamp(280.0, 640.0);
    if (save) prefs.setDouble('paneW', _paneW!);
    notifyListeners();
  }

  double? _paneW;
  double get livePaneWidth => _paneW ?? paneWidth;

  // ───────── 초기화 ─────────
  Future<void> init() async {
    locked = lockEnabled; // 시작할 때는 항상 잠근 상태로
    bridge.events.listen(_onEvent);
    try {
      final res = await bridge.call('init') as Map;
      phase = res['loggedIn'] == true ? Phase.ready : Phase.loggedOut;
    } catch (e) {
      loginError = e.toString();
      phase = Phase.loggedOut;
    }
    notifyListeners();
  }

  /// 화면 확인용 데모 데이터 (환경 변수 GM_DEMO=1 일 때만, 서버에 연결하지 않음)
  void loadDemo() {
    final now = DateTime.now().millisecondsSinceEpoch;
    const min = 60 * 1000;
    Map<String, dynamic> conv(String id, String name, String preview, int ago,
            {bool unread = false, bool fromMe = false, bool group = false}) =>
        {
          'id': id,
          'name': name,
          'ts': now - ago * min,
          'unread': unread,
          'isGroup': group,
          'preview': preview,
          'previewFromMe': fromMe,
          'status': 'ACTIVE',
          'outgoingId': 'me',
          'participants': [
            {'id': 'me', 'isMe': true, 'name': '나'},
            {
              'id': 'p$id',
              'name': name,
              'number': '+821012345678',
              'formatted': '010-1234-5678',
              'color': const ['#1A73E8', '#E8710A', '#188038', '#A142F4', '#D93025'][id.hashCode % 5],
            },
          ],
        };
    for (final c in [
      conv('1', '김민수', '네, 그럼 내일 오후 3시에 뵙겠습니다', 2, unread: true),
      conv('2', '이서연', '사진 보냈어요 확인해 주세요', 18, unread: true),
      conv('3', '박지훈', '알겠습니다. 감사합니다!', 55, fromMe: true),
      conv('4', '가족', '주말에 다 같이 저녁 먹자', 190, group: true),
      conv('5', '최유진', '택배 문 앞에 두고 갑니다', 60 * 26),
      conv('6', '정하늘', '다음 주 일정 공유드려요', 60 * 50, fromMe: true),
      conv('7', '1588-0000', '[Web발신] 인증번호 [482913]을 입력해 주세요', 60 * 75),
    ]) {
      convs[c['id'] as String] = Conversation.fromJson(c);
    }
    Map<String, dynamic> msg(int i, String text, int ago, {bool mine = false, int status = 0}) => {
          'id': 'm$i',
          'convId': '1',
          'participantId': mine ? 'me' : 'p1',
          'ts': now - ago * min,
          'status': mine ? (status == 0 ? 11 : status) : 100,
          'text': text,
        };
    final chat = chats.putIfAbsent('1', ChatState.new);
    chat.messages.addAll([
      msg(1, '안녕하세요, 내일 미팅 시간 괜찮으신가요?', 42),
      msg(2, '네 안녕하세요! 오후면 언제든 괜찮습니다.', 40, mine: true),
      msg(3, '그럼 3시쯤 어떠세요? 회의실은 제가 예약해 둘게요.', 12),
      msg(4, '좋습니다. 자료는 오늘 저녁까지 메일로 보내 드리겠습니다.', 9, mine: true),
      msg(5, '감사합니다 🙏', 8, mine: true, status: 2),
      msg(6, '네, 그럼 내일 오후 3시에 뵙겠습니다', 2),
    ].map(Message.fromJson));
    chat.loaded = true;
    chat.hasMore = false;
    selectedId = '1';
    wide = true;
    convs['1']!.unread = false;
    connState = 'connected';
    phase = Phase.ready;
    notifyListeners();
  }

  void _onEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'status':
        _onStatus((e['state'] ?? '').toString(), (e['message'] ?? '').toString());
      case 'paired':
        pairEmoji = null;
        loginError = null;
        phase = Phase.ready;
        notifyListeners();
      case 'pair_error':
        pairEmoji = null;
        loginError = (e['error'] ?? '').toString();
        phase = Phase.loggedOut;
        notifyListeners();
      case 'conversation':
        _upsertConv(Conversation.fromJson(
            Map<String, dynamic>.from(e['conv'] as Map)));
        _afterConvChange();
      case 'message':
        _onMessage(
            Message.fromJson(Map<String, dynamic>.from(e['msg'] as Map)),
            e['isOld'] == true);
      case 'settings':
        _rememberPhoneNumber(e['sims']);
        if (e['sims'] is List) {
          sims = [
            for (final sim in e['sims'] as List)
              if (sim is Map) Map<String, dynamic>.from(sim)
          ];
        }
        if (e['rcs'] is Map) rcs = Map<String, dynamic>.from(e['rcs'] as Map);
        phoneAppVersion = (e['phoneAppVersion'] ?? '').toString();
        notifyListeners();
      case 'alert':
        _onAlert((e['alert'] ?? '').toString());
      case 'typing':
        final id = (e['convId'] ?? '').toString();
        if (e['typing'] == true) {
          typing[id] = DateTime.now().add(const Duration(seconds: 12));
          Timer(const Duration(seconds: 13), notifyListeners);
        } else {
          typing.remove(id);
        }
        notifyListeners();
    }
  }

  void _onStatus(String state, String message) {
    if (state == 'logged_out') {
      _clear();
      loginError = '휴대폰에서 연결이 해제되었습니다. 다시 로그인해 주세요.';
      phase = Phase.loggedOut;
      notifyListeners();
      return;
    }
    final wasConnected = connState == 'connected';
    connState = state;
    connMessage = message;
    if (state == 'connected' && !wasConnected) {
      loadConversations();
      final sel = selectedId;
      if (sel != null) loadMessages(sel, refresh: true);
    }
    notifyListeners();
  }

  void _clear() {
    convs.clear();
    chats.clear();
    avatars.clear();
    _avatarRequested.clear();
    selectedId = null;
    connState = 'connecting';
    sims = const [];
    rcs = const {};
    phoneOnMobileData = false;
    phoneBatteryLow = false;
    sessionInactive = false;
  }

  // ───────── 로그인 ─────────
  Future<void> login(Map<String, String> cookies) async {
    if (loginBusy) return;
    loginBusy = true;
    loginError = null;
    notifyListeners();
    try {
      final res = await bridge.call('login', {'cookies': cookies}) as Map;
      pairEmoji = (res['emoji'] ?? '').toString();
      phase = Phase.pairing;
    } catch (e) {
      loginError = e.toString();
    }
    loginBusy = false;
    notifyListeners();
  }

  void setLoginError(String? message) {
    loginError = message;
    notifyListeners();
  }

  Future<void> cancelLogin() async {
    await bridge.call('cancelLogin').catchError((_) => null);
    pairEmoji = null;
    phase = Phase.loggedOut;
    notifyListeners();
  }

  Future<void> logout() async {
    await bridge.call('logout').catchError((_) => null);
    _clear();
    loginError = null;
    phase = Phase.loggedOut;
    notifyListeners();
    onUnreadChanged?.call();
  }

  void reconnect() {
    bridge.call('reconnect').catchError((_) => null);
  }

  // ───────── 대화 목록 ─────────
  List<Conversation> get visible {
    final q = query.trim().toLowerCase();
    final list = convs.values.where((c) {
      if (c.folder != folder) return false;
      // 지금 열어 둔 대화는 읽음 처리돼도 목록에서 바로 사라지지 않게 둔다
      if (filter == 'unread' && !c.unread && c.id != selectedId) return false;
      if (filter == 'pinned' && !isPinned(c)) return false;
      // 재난문자는 따로 모아 보여 주고, 다른 목록에서는 뺀다
      final disaster = isDisaster(c);
      if (filter == 'disaster' ? !disaster : disaster) return false;
      if (q.isEmpty) return true;
      return c.title.toLowerCase().contains(q) ||
          c.preview.toLowerCase().contains(q) ||
          c.participants.any((p) =>
              p.number.contains(q) ||
              p.formatted.replaceAll(RegExp(r'[^0-9]'), '').contains(q));
    }).toList();
    list.sort((a, b) {
      final pa = isPinned(a), pb = isPinned(b);
      if (pa != pb) return pa ? -1 : 1;
      return b.ts.compareTo(a.ts);
    });
    return list;
  }

  static final RegExp _disasterPattern =
      RegExp(r'CMAS|재난|안전\s*안내|긴급\s*문자|경보', caseSensitive: false);

  /// 재난문자(긴급재난·안전안내) 대화인지: 보낸 곳 이름·번호로 판단
  bool isDisaster(Conversation c) {
    if (_disasterPattern.hasMatch(c.name)) return true;
    for (final p in c.others) {
      if (_disasterPattern.hasMatch(p.name) ||
          _disasterPattern.hasMatch(p.number) ||
          _disasterPattern.hasMatch(p.formatted)) {
        return true;
      }
    }
    return false;
  }

  /// 목록 필터: all(전체) / unread(읽지 않음) / pinned(고정) / disaster(재난문자)
  String filter = 'all';

  void setFilter(String f) {
    filter = f;
    notifyListeners();
  }

  int get unreadCount => convs.values
      .where((c) => c.folder == 'inbox' && c.unread && !isDisaster(c))
      .length;

  Conversation? get selected => selectedId == null ? null : convs[selectedId];

  void setFolder(String f) {
    folder = f;
    notifyListeners();
    loadConversations();
  }

  void setQuery(String q) {
    query = q;
    notifyListeners();
  }

  Future<void> loadConversations() async {
    if (convsLoading) return;
    final f = folder;
    convsLoading = true;
    convsError = null;
    notifyListeners();
    try {
      final res =
          await bridge.call('conversations', {'folder': f, 'count': 100})
              as List;
      for (final c in res) {
        _upsertConv(Conversation.fromJson(Map<String, dynamic>.from(c as Map)));
      }
    } catch (e) {
      convsError = e.toString();
    }
    convsLoading = false;
    _afterConvChange();
  }

  void _upsertConv(Conversation c) {
    if (c.folder == 'deleted') {
      convs.remove(c.id);
      chats.remove(c.id);
      if (selectedId == c.id) selectedId = null;
      return;
    }
    // 지금 보고 있는 대화는 읽음 상태 유지
    if (c.id == selectedId && windowActive && c.unread) {
      c.unread = false;
      _markRead(c);
    }
    convs[c.id] = c;
    _requestAvatars(c);
  }

  void _afterConvChange() {
    notifyListeners();
    onUnreadChanged?.call();
  }

  void _requestAvatars(Conversation c) {
    final ids = c.others
        .map((p) => p.id)
        .where((id) => id.isNotEmpty && _avatarRequested.add(id))
        .toList();
    if (ids.isEmpty) return;
    bridge.call('thumbnails', {'ids': ids}).then((res) {
      (res as Map).forEach((k, v) {
        try {
          avatars[k.toString()] = base64Decode(v.toString());
        } catch (_) {}
      });
      notifyListeners();
    }).catchError((_) {
      // 연결 전이면 실패할 수 있으니 다음 기회에 다시 시도
      _avatarRequested.removeAll(ids);
    });
  }

  Future<void> updateConversation(String id, String action) async {
    await bridge.call('updateConversation', {'convId': id, 'action': action});
    if (action == 'delete') {
      convs.remove(id);
      chats.remove(id);
      if (selectedId == id) selectedId = null;
    } else {
      // 폴더가 바뀌므로 현재 목록에서 제거 (새 상태는 이벤트로 반영됨)
      if (selectedId == id) selectedId = null;
      convs.remove(id);
    }
    _afterConvChange();
  }

  Future<Conversation> startConversation(List<String> numbers,
      {String groupName = ''}) async {
    final res = await bridge.call('startConversation', {
      'numbers': numbers,
      if (groupName.trim().isNotEmpty) 'groupName': groupName.trim(),
    });
    final c = Conversation.fromJson(Map<String, dynamic>.from(res as Map));
    _upsertConv(c);
    notifyListeners();
    return c;
  }

  // ───────── 대화 내용 ─────────
  String? lastSelectedId;

  /// 펼침(목록+대화창 두 칸) / 접힘(한 칸: 목록 또는 대화창) 상태
  late bool wide = prefs.getBool('wide') ?? false;

  void setWide(bool v) {
    if (wide == v) return;
    wide = v;
    prefs.setBool('wide', v);
    notifyListeners();
  }

  void toggleChat() => setWide(!wide);

  // ───────── 링크 미리보기 ─────────
  /// Enter 로 보내기 (끄면 Enter 는 줄바꿈, Ctrl·⌘+Enter 로 보냄)
  bool get enterSends => prefs.getBool('enterSends') ?? true;
  set enterSends(bool v) {
    prefs.setBool('enterSends', v);
    notifyListeners();
  }

  bool get linkPreviews => prefs.getBool('linkPreviews') ?? true;
  set linkPreviews(bool v) {
    prefs.setBool('linkPreviews', v);
    notifyListeners();
  }

  // ───────── 글씨 크기 ─────────
  double get textScale => (prefs.getDouble('textScale') ?? 1.0).clamp(0.85, 1.5);
  set textScale(double v) {
    prefs.setDouble('textScale', v);
    notifyListeners();
  }

  void select(String? id) {
    if (id != null) lastSelectedId = id;
    selectedId = id;
    if (id != null) {
      final chat = chats.putIfAbsent(id, ChatState.new);
      if (!chat.loaded) loadMessages(id);
      final c = convs[id];
      if (c != null && c.unread) {
        c.unread = false;
        _markRead(c);
        onUnreadChanged?.call();
      }
    }
    notifyListeners();
  }

  void _markRead(Conversation c) {
    final chat = chats[c.id];
    var msgId = c.latestMsgId;
    if (chat != null) {
      for (final m in chat.messages.reversed) {
        if (!m.isLocal) {
          msgId = m.id;
          break;
        }
      }
    }
    if (msgId.isEmpty) return;
    bridge
        .call('markRead', {'convId': c.id, 'msgId': msgId}).catchError((_) => null);
  }

  void markRead(String id) {
    final c = convs[id];
    if (c == null || !c.unread) return;
    c.unread = false;
    _markRead(c);
    _afterConvChange();
  }

  void markAllRead() {
    for (final c in convs.values) {
      if (c.folder == folder && c.unread) {
        c.unread = false;
        _markRead(c);
      }
    }
    _afterConvChange();
  }

  /// 창이 다시 활성화될 때: 열려 있는 대화를 읽음 처리
  void setWindowActive(bool active) {
    windowActive = active;
    if (active) {
      final c = selected;
      if (c != null && c.unread) {
        c.unread = false;
        _markRead(c);
        _afterConvChange();
      }
    }
  }

  Future<void> loadMessages(String id,
      {bool older = false, bool refresh = false}) async {
    final chat = chats.putIfAbsent(id, ChatState.new);
    if (chat.loading) return;
    if (older && (!chat.hasMore || chat.cursorId == null)) return;
    chat.loading = true;
    chat.error = null;
    notifyListeners();
    try {
      final res = await bridge.call('messages', {
        'convId': id,
        'count': 50,
        if (older) 'cursorId': chat.cursorId,
        if (older) 'cursorTs': chat.cursorTs,
      }) as Map;
      final list = ((res['messages'] as List?) ?? const [])
          .map((m) => Message.fromJson(Map<String, dynamic>.from(m as Map)))
          .where((m) => !m.deleted)
          .toList();
      if (older) {
        final known = chat.messages.map((m) => m.id).toSet();
        chat.messages.insertAll(0, list.where((m) => !known.contains(m.id)));
      } else {
        final fetched = list.map((m) => m.id).toSet();
        final keep = refresh
            ? chat.messages
                .where((m) =>
                    !fetched.contains(m.id) &&
                    (m.isLocal ||
                        (list.isNotEmpty && m.ts < list.first.ts)))
                .toList()
            : <Message>[];
        chat.messages
          ..clear()
          ..addAll(keep)
          ..addAll(list);
      }
      chat.messages.sort((a, b) => a.ts.compareTo(b.ts));
      if (older || !refresh || chat.cursorId == null) {
        chat.cursorId = res['cursorId'] as String?;
        chat.cursorTs = (res['cursorTs'] as num?)?.toInt() ?? 0;
        chat.hasMore = chat.cursorId != null && list.isNotEmpty;
      }
      chat.loaded = true;
    } catch (e) {
      chat.error = e.toString();
    }
    chat.loading = false;
    notifyListeners();
  }

  bool isMine(Message m) {
    if (m.isLocal) return true;
    final c = convs[m.convId];
    if (c != null) {
      if (m.participantId == c.outgoingId && c.outgoingId.isNotEmpty) return true;
      final p = c.participant(m.participantId);
      if (p != null) return p.isMe;
    }
    return m.outgoing;
  }

  void _onMessage(Message m, bool isOld) {
    final chat = chats[m.convId];
    if (chat != null && chat.loaded) {
      var idx = chat.messages.indexWhere((x) => x.id == m.id);
      if (idx < 0 && m.tmpId.isNotEmpty) {
        idx = chat.messages
            .indexWhere((x) => x.isLocal && x.tmpId == m.tmpId);
      }
      // 서버가 돌려준 메시지에 임시 번호가 없거나 달라도, 방금 내가 보낸 같은 내용의
      // 임시 말풍선이 있으면 그것과 같은 메시지로 본다 (두 번 표시되는 것 방지)
      if (idx < 0 && !m.isLocal && !m.deleted && isMine(m)) {
        idx = chat.messages.indexWhere((x) =>
            x.isLocal &&
            x.localError == null &&
            x.text.trim() == m.text.trim() &&
            x.media.isEmpty == m.media.isEmpty &&
            (m.ts - x.ts).abs() < 3 * 60 * 1000);
      }
      if (m.deleted) {
        if (idx >= 0) chat.messages.removeAt(idx);
      } else if (idx >= 0) {
        chat.messages[idx] = m;
      } else {
        chat.messages.add(m);
        chat.messages.sort((a, b) => a.ts.compareTo(b.ts));
      }
    }
    final c = convs[m.convId];
    final mine = isMine(m);
    final viewing = selectedId == m.convId && windowActive;
    if (c != null && !m.deleted && !m.tombstone && m.ts >= c.ts) {
      c.ts = m.ts;
      if (m.summary.isNotEmpty) c.preview = m.summary;
      c.previewFromMe = mine;
      c.latestMsgId = m.id;
      if (!mine && m.incoming && !isOld) {
        if (viewing) {
          _markRead(c);
        } else {
          c.unread = true;
        }
      }
    }
    final fresh =
        DateTime.now().millisecondsSinceEpoch - m.ts < 5 * 60 * 1000;
    if (!isOld && !mine && m.incoming && fresh && !viewing &&
        !_notified.contains(m.id)) {
      void fire(Message msg) {
        _pendingNotify.remove(msg.id)?.cancel();
        _pendingMsg.remove(msg.id);
        if (!_notified.add(msg.id)) return;
        if (notificationsEnabled && !isMuted(msg.convId)) {
          onIncoming?.call(convs[msg.convId], msg);
        }
      }

      if (m.summary.isNotEmpty) {
        fire(m);
      } else {
        // 긴 문자(MMS)는 내용이 조금 늦게 도착한다. 내용이 올 때까지 잠깐 기다렸다가
        // 알리고, 끝내 안 오면 내용 없이 알린다.
        _pendingMsg[m.id] = m;
        _pendingNotify[m.id] ??= Timer(const Duration(seconds: 10), () {
          final last = _pendingMsg[m.id];
          if (last == null) return;
          // 기다리는 사이 그 대화를 보고 있게 됐으면 알리지 않는다
          if (selectedId == last.convId && windowActive) {
            _pendingMsg.remove(last.id);
            _pendingNotify.remove(last.id);
            _notified.add(last.id);
            return;
          }
          fire(last);
        });
      }
    }
    _afterConvChange();
  }

  // ───────── 전송 ─────────
  Future<void> send(String convId, String text,
      {String? path, String? mime, String? replyTo}) async {
    final chat = chats.putIfAbsent(convId, ChatState.new);
    final r = Random();
    final tmpId =
        'tmp_${List.generate(12, (_) => r.nextInt(10)).join()}';
    final now = DateTime.now().millisecondsSinceEpoch;
    final local = Message.fromJson({
      'id': 'local:$tmpId',
      'convId': convId,
      'participantId': convs[convId]?.outgoingId ?? '',
      'ts': now,
      'status': 5,
      'text': text,
      'tmpId': tmpId,
      'media': [
        if (path != null)
          {
            'mime': mime ?? '',
            'name': path.split(Platform.pathSeparator).last,
            'localPath': path,
          }
      ],
    });
    chat.messages.add(local);
    final c = convs[convId];
    if (c != null) {
      c.ts = now;
      c.preview = local.summary;
      c.previewFromMe = true;
    }
    notifyListeners();
    userTyping(convId, stop: true);
    final simId = c != null && sims.length > 1 ? simIdFor(c) : '';
    try {
      await bridge.call('send', {
        'convId': convId,
        'tmpId': tmpId,
        'text': text,
        if (simId.isNotEmpty) 'simId': simId,
        if (path != null) 'path': path,
        if (mime != null) 'mime': mime,
        if (replyTo != null) 'replyTo': replyTo,
      });
    } catch (e) {
      local.localError = e.toString();
      notifyListeners();
    }
  }

  final Map<String, Timer> _pendingNotify = {};
  final Map<String, Message> _pendingMsg = {};
  final Set<String> _fullRequested = {};

  /// 미리보기만 온 사진의 원본을 휴대폰에 요청한다 (사진마다 한 번).
  /// 휴대폰이 원본을 올리면 메시지가 갱신되어 자동으로 원본으로 바뀐다.
  void requestFullImage(Message m, MediaItem item) {
    if (m.isLocal || item.partId.isEmpty) return;
    if (!_fullRequested.add('${m.id}/${item.partId}')) return;
    bridge
        .call('fullImage', {'msgId': m.id, 'partId': item.partId})
        .catchError((_) => null);
  }

  void removeLocal(Message m) {
    chats[m.convId]?.messages.remove(m);
    notifyListeners();
  }

  Future<void> react(Message m, String emoji, {bool remove = false}) =>
      bridge.call('react', {
        'convId': m.convId,
        'msgId': m.id,
        'emoji': emoji,
        'remove': remove,
      });

  Future<void> deleteMessage(Message m) async {
    await bridge.call('deleteMessage', {'msgId': m.id});
    chats[m.convId]?.messages.removeWhere((x) => x.id == m.id);
    notifyListeners();
  }

  // ───────── 미디어 ─────────
  Future<String> mediaFile(MediaItem item) {
    if (item.localPath != null) return Future.value(item.localPath);
    return _mediaFutures.putIfAbsent(item.mediaId, () async {
      final safe = item.mediaId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
      final tail = safe.length > 40 ? safe.substring(safe.length - 40) : safe;
      var ext = '';
      final dot = item.name.lastIndexOf('.');
      if (dot > 0 && item.name.length - dot <= 6) {
        ext = item.name.substring(dot).replaceAll(RegExp(r'[^A-Za-z0-9.]'), '');
      } else if (item.mime.contains('/')) {
        ext = '.${item.mime.split('/').last.split(';').first.split('+').first}';
      }
      final sep = Platform.pathSeparator;
      final path =
          '$cacheDir${sep}media$sep${item.mediaId.length}_${item.mediaId.hashCode.toUnsigned(32)}_$tail$ext';
      try {
        final res = await bridge.call(
                'download', {'mediaId': item.mediaId, 'key': item.key, 'path': path})
            as Map;
        return res['path'].toString();
      } catch (e) {
        _mediaFutures.remove(item.mediaId);
        rethrow;
      }
    });
  }

  Future<List<Map<String, dynamic>>> contacts() async {
    final res = await bridge.call('contacts') as List;
    return res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }
}
