// 계좌 안내 사진을 만들어 → 글자 인식 → 은행·계좌번호·예금주 찾기까지 한 번에 확인한다.
// (Windows 전용)   flutter test test/account_viewer_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_messages/bank_account.dart';
import 'package:google_messages/image_viewer.dart';

/// 흰 바탕에 글자를 쓴 사진을 만든다 (Windows 의 그리기 기능 사용)
String _makeImage(List<String> lines) {
  final out =
      '${Directory.systemTemp.path}\gm_account_${DateTime.now().microsecondsSinceEpoch}.png';
  final draw = [
    for (var i = 0; i < lines.length; i++)
      "\$g.DrawString('${lines[i]}',\$f,[System.Drawing.Brushes]::Black,40,${40 + i * 62});"
  ].join();
  final r = Process.runSync('powershell', [
    '-NoProfile', '-NonInteractive', '-Command',
    "Add-Type -AssemblyName System.Drawing;"
        "\$b=New-Object System.Drawing.Bitmap 900,${80 + lines.length * 62};"
        "\$g=[System.Drawing.Graphics]::FromImage(\$b);\$g.Clear([System.Drawing.Color]::White);"
        "\$g.TextRenderingHint='AntiAlias';"
        "\$f=New-Object System.Drawing.Font('Malgun Gothic',26);$draw"
        "\$b.Save('$out');",
  ]);
  if (r.exitCode != 0) throw 'image: ${r.stderr}';
  return out;
}

void main() {
  test('사진에서 계좌 정보를 찾는다', () async {
    if (!Platform.isWindows) return;
    final img = _makeImage([
      '입금 계좌 안내',
      '신한은행 110-123-456789',
      '예금주: 홍길동',
      '문의 010-1234-5678',
    ]);
    addTearDown(() => File(img).deleteSync());
    final ocr = (await recognizeText(img))!;
    // ignore: avoid_print
    print(ocr.lines.map((l) => l.text).join(' | '));
    final a = parseAccount([for (final l in ocr.lines) l.text])!;
    expect(a.bank, '신한은행');
    expect(a.number, '110123456789');
    expect(a.holder, '홍길동');
  }, timeout: const Timeout(Duration(seconds: 60)));
}
