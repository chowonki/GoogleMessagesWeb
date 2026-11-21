// 화면 확인용: 데모 데이터로 앱 화면을 그려 shots/ 폴더에 PNG 로 저장한다.
//   flutter test test/screenshot_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_messages/bridge.dart';
import 'package:google_messages/home_page.dart';
import 'package:google_messages/main.dart';
import 'package:google_messages/models.dart';
import 'package:google_messages/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _loadFonts() async {
  // 앱에 포함된 글꼴(Pretendard, 아이콘 글꼴)
  final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json'))
      as List<dynamic>;
  for (final f in manifest) {
    final loader = FontLoader(f['family'] as String);
    for (final font in f['fonts'] as List<dynamic>) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
  // 시스템 글꼴(이모지·한글 대체 글꼴)
  for (final e in {
    'Segoe UI Emoji': r'C:\Windows\Fonts\seguiemj.ttf',
    'Malgun Gothic': r'C:\Windows\Fonts\malgun.ttf',
  }.entries) {
    final file = File(e.value);
    if (!file.existsSync()) continue;
    final bytes = file.readAsBytesSync();
    final loader = FontLoader(e.key)
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }
}

final _shotKey = GlobalKey();

Future<void> _save(WidgetTester tester, String name) async {
  final boundary =
      _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('shots')..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

Future<AppState> _demoState() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final state = AppState(GmBridge(), prefs, Directory.systemTemp.path);
  state.loadDemo();
  // 새 기능이 보이도록 데모 데이터를 보탠다: RCS 대화, 듀얼 SIM, 공감, 휴대폰 상태 알림
  final c = state.convs['1']!;
  state.convs['1'] = Conversation.fromJson({
    'id': c.id,
    'name': c.name,
    'ts': c.ts,
    'preview': c.preview,
    'status': 'ACTIVE',
    'outgoingId': 'me',
    'type': 'RCS',
    'participants': [
      {'id': 'me', 'isMe': true, 'name': '나'},
      {
        'id': 'p1',
        'name': '김민수',
        'number': '+821012345678',
        'formatted': '010-1234-5678',
        'color': '#1A73E8',
      },
    ],
  });
  state.sims = [
    {'participantId': 'me', 'carrier': 'SKT', 'number': '010-1111-2222', 'slot': 1, 'rcs': true},
    {'participantId': 'me2', 'carrier': 'KT', 'number': '010-3333-4444', 'slot': 2, 'rcs': false},
  ];
  state.rcs = {'enabled': true, 'readReceipts': true, 'typingIndicators': true};
  final msgs = state.chats['1']!.messages;
  msgs[3] = Message.fromJson({
    'id': msgs[3].id,
    'convId': '1',
    'participantId': 'me',
    'ts': msgs[3].ts,
    'status': 11,
    'msgType': 4,
    'text': msgs[3].text,
    'reactions': [
      {'emoji': '👍', 'participants': ['p1']},
      {'emoji': '😂', 'participants': ['p1', 'me']},
    ],
  });
  state.phoneOnMobileData = true;
  state.phoneBatteryLow = true;
  return state;
}

Widget _app(AppState state, Brightness b) => RepaintBoundary(
      key: _shotKey,
      child: ListenableBuilder(
        listenable: state,
        builder: (context, _) => MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: MessagesApp.oneUiTheme(b),
          // 글씨 크기 설정별 확인용: GM_SCALE=1.4 flutter test ...
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(double.tryParse(
                        Platform.environment['GM_SCALE'] ?? '') ??
                    1.0)),
            child: child!,
          ),
          home: Scaffold(
            body: HomePage(state: state, onSettings: () {}, onQuit: () {}),
          ),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final b in Brightness.values) {
    testWidgets('screenshots ${b.name}', (tester) async {
      // 실제 앱(Windows)과 같은 조건으로 그린다. 테스트 기본값은 Android 라서 버튼·입력 칸
      // 간격(visual density)이 데스크톱과 달라, 실제 화면과 다르게 보인다.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await tester.runAsync(_loadFonts);
      tester.view.physicalSize = const Size(1016, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final state = await _demoState();
      await tester.pumpWidget(_app(state, b));
      // 그림(탭바의 앱 아이콘 등)이 읽힐 시간을 준다
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await _save(tester, 'main_${b.name}');

      // 대화 우클릭 메뉴
      await tester.tap(find.textContaining('이서연').first,
          buttons: kSecondaryButton);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await _save(tester, 'menu_${b.name}');

      // 세부정보 (대화를 열고 대화 상대 정보 화면을 펼친다)
      await tester.tap(find.text('세부정보'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await _save(tester, 'contact_info_${b.name}');

      debugDefaultTargetPlatformOverride = null;
      // 앱의 우클릭 메뉴는 직접 만든 창이라 테스트의 접근성 검사와 맞지 않아 끈다
    }, semanticsEnabled: false);
  }
}
