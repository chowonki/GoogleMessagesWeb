// 글자 인식(Windows) 속도 확인용: flutter test test/ocr_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_messages/image_viewer.dart';

void main() {
  test('미리 띄우기와 첫 인식이 겹쳐도 바로 끝나고, 두 번째는 보관 결과를 쓴다', () async {
    if (!Platform.isWindows) return;
    final src = File('shots/main_light.png');
    if (!src.existsSync()) return;
    // 보관 결과가 남아 있지 않도록 매번 새 파일로 시험한다
    final img = File(
        '${Directory.systemTemp.path}/gm_ocr_test_${DateTime.now().microsecondsSinceEpoch}.png');
    src.copySync(img.path);
    addTearDown(() => img.deleteSync());

    final sw = Stopwatch()..start();
    prewarmOcr(); // 사진 창이 뜰 때처럼 기다리지 않고 바로 인식을 요청한다
    final first = await recognizeText(img.path);
    final firstMs = sw.elapsedMilliseconds;
    expect(first, isNotNull);
    expect(first!.lines, isNotEmpty);
    expect(firstMs, lessThan(5000));

    sw.reset();
    final again = await recognizeText(img.path);
    final againMs = sw.elapsedMilliseconds;
    expect(again!.lines.length, first.lines.length);
    // ignore: avoid_print
    print('first=${firstMs}ms cached=${againMs}ms lines=${first.lines.length}');
  }, timeout: const Timeout(Duration(seconds: 60)));
}
