import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'bank_account.dart';
import 'drag_out.dart';
import 'fade_menu.dart';
import 'models.dart';
import 'store.dart';
import 'style.dart';

// ───────────────────────── 라이브 텍스트 (사진 속 글자 인식) ─────────────────────────

class OcrLine {
  OcrLine(this.text, this.rect);
  final String text;
  final Rect rect; // 원본 사진 픽셀 좌표
}

class OcrResult {
  OcrResult(this.width, this.height, this.lines);
  final double width, height;
  final List<OcrLine> lines;
  String get text => lines.map((l) => l.text).join('\n');
}

/// Windows 기본 OCR(Windows.Media.Ocr)을 PowerShell 로 호출한다. 창이 뜨지 않도록
/// 분리 실행하고 결과는 임시 파일(JSON)로 받는다.
const String _ocrScript = r'''
$ErrorActionPreference='Stop'
try {
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null=[Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime]
$null=[Windows.Media.Ocr.OcrEngine,Windows.Foundation,ContentType=WindowsRuntime]
$null=[Windows.Graphics.Imaging.BitmapDecoder,Windows.Graphics,ContentType=WindowsRuntime]
$null=[Windows.Graphics.Imaging.BitmapTransform,Windows.Graphics,ContentType=WindowsRuntime]
$null=[Windows.Globalization.Language,Windows.Globalization,ContentType=WindowsRuntime]
$asTask=([System.WindowsRuntimeSystemExtensions].GetMethods()|Where-Object{$_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'})[0]
function Await($op,$type){$t=$asTask.MakeGenericMethod($type).Invoke($null,@($op));$t.Wait(-1)|Out-Null;$t.Result}
$f=Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($env:GM_OCR_PATH)) ([Windows.Storage.StorageFile])
$s=Await ($f.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
$d=Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($s)) ([Windows.Graphics.Imaging.BitmapDecoder])
$tr=New-Object Windows.Graphics.Imaging.BitmapTransform
# 작은 사진은 키워서 인식률을 높인다 (긴 변 2400px 근처까지, 최대 4배)
$long=[Math]::Max($d.PixelWidth,$d.PixelHeight)
$k=[Math]::Min(4.0,[Math]::Max(1.0,2400.0/$long))
if($long*$k -gt 9000){$k=9000.0/$long}
if($k -ne 1.0){$tr.ScaledWidth=[uint32]($d.PixelWidth*$k);$tr.ScaledHeight=[uint32]($d.PixelHeight*$k);$tr.InterpolationMode=[Windows.Graphics.Imaging.BitmapInterpolationMode]::Fant}
$b=Await ($d.GetSoftwareBitmapAsync([Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,[Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied,$tr,[Windows.Graphics.Imaging.ExifOrientationMode]::RespectExifOrientation,[Windows.Graphics.Imaging.ColorManagementMode]::DoNotColorManage)) ([Windows.Graphics.Imaging.SoftwareBitmap])
$e=$null
try{$ko=New-Object Windows.Globalization.Language 'ko';if([Windows.Media.Ocr.OcrEngine]::IsLanguageSupported($ko)){$e=[Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($ko)}}catch{}
if($e -eq $null){$e=[Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()}
if($e -eq $null){throw 'no ocr language'}
$r=Await ($e.RecognizeAsync($b)) ([Windows.Media.Ocr.OcrResult])
$lines=@()
foreach($l in $r.Lines){$x0=1e9;$y0=1e9;$x1=0;$y1=0;foreach($w in $l.Words){$q=$w.BoundingRect;if($q.X -lt $x0){$x0=$q.X};if($q.Y -lt $y0){$y0=$q.Y};if($q.X+$q.Width -gt $x1){$x1=$q.X+$q.Width};if($q.Y+$q.Height -gt $y1){$y1=$q.Y+$q.Height}};$lines+=@{t=$l.Text;x=$x0;y=$y0;w=$x1-$x0;h=$y1-$y0}}
$out=@{w=$b.PixelWidth;h=$b.PixelHeight;lines=$lines}|ConvertTo-Json -Depth 4 -Compress
} catch { $out=@{error="$_"}|ConvertTo-Json -Compress }
[IO.File]::WriteAllText($env:GM_OCR_OUT,$out,(New-Object Text.UTF8Encoding $false))
''';

/// 속도를 위해 PowerShell 을 한 번만 띄워 두고(형식 로딩·엔진 생성 1회) 사진 경로를
/// 한 줄씩 보내 결과를 받는다. 입출력은 인코딩 문제를 피하려고 base64 로 주고받는다.
const String _ocrWorkerScript = r"""
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null=[Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime]
$null=[Windows.Media.Ocr.OcrEngine,Windows.Foundation,ContentType=WindowsRuntime]
$null=[Windows.Graphics.Imaging.BitmapDecoder,Windows.Graphics,ContentType=WindowsRuntime]
$null=[Windows.Graphics.Imaging.BitmapTransform,Windows.Graphics,ContentType=WindowsRuntime]
$null=[Windows.Globalization.Language,Windows.Globalization,ContentType=WindowsRuntime]
$asTask=([System.WindowsRuntimeSystemExtensions].GetMethods()|Where-Object{$_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'})[0]
function Await($op,$type){$t=$asTask.MakeGenericMethod($type).Invoke($null,@($op));$t.Wait(-1)|Out-Null;$t.Result}
$e=$null
try{$ko=New-Object Windows.Globalization.Language 'ko';if([Windows.Media.Ocr.OcrEngine]::IsLanguageSupported($ko)){$e=[Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($ko)}}catch{}
if($e -eq $null){$e=[Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()}
$u8=New-Object Text.UTF8Encoding $false
$o=New-Object IO.StreamWriter([Console]::OpenStandardOutput(),$u8)
$o.AutoFlush=$true
# 요청은 폴더에 놓인 파일(*.req, 내용 = 사진 경로)로 받는다. 표준 입력으로 받으면
# 요청이 전달되지 않고 멈추는 경우가 있었다. 앱이 끝나면 함께 끝난다.
$dir=$args[0]
$parent=[Diagnostics.Process]::GetProcessById([int]$args[1])
$o.WriteLine('READY')
while(-not $parent.HasExited){
 $reqs=[IO.Directory]::GetFiles($dir,'*.req')
 if($reqs.Length -eq 0){[Threading.Thread]::Sleep(15);continue}
 [Array]::Sort($reqs)
 foreach($rq in $reqs){
 try{
  $path=[IO.Path]::GetFullPath([IO.File]::ReadAllText($rq,$u8).Trim())
  [IO.File]::Delete($rq)
  if($e -eq $null){throw 'no ocr language'}
  $f=Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
  $s=Await ($f.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
  $d=Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($s)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $tr=New-Object Windows.Graphics.Imaging.BitmapTransform
  $long=[Math]::Max($d.PixelWidth,$d.PixelHeight)
  $k=1.0
  if($long -lt 1400){$k=[Math]::Min(3.0,1800.0/$long)}
  elseif($long -gt 3200){$k=3200.0/$long}
  if($k -ne 1.0){$tr.ScaledWidth=[uint32]($d.PixelWidth*$k);$tr.ScaledHeight=[uint32]($d.PixelHeight*$k);$tr.InterpolationMode=[Windows.Graphics.Imaging.BitmapInterpolationMode]::Linear}
  $b=Await ($d.GetSoftwareBitmapAsync([Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,[Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied,$tr,[Windows.Graphics.Imaging.ExifOrientationMode]::RespectExifOrientation,[Windows.Graphics.Imaging.ColorManagementMode]::DoNotColorManage)) ([Windows.Graphics.Imaging.SoftwareBitmap])
  $r=Await ($e.RecognizeAsync($b)) ([Windows.Media.Ocr.OcrResult])
  $lines=@()
  foreach($l in $r.Lines){$x0=1e9;$y0=1e9;$x1=0;$y1=0;foreach($w in $l.Words){$q=$w.BoundingRect;if($q.X -lt $x0){$x0=$q.X};if($q.Y -lt $y0){$y0=$q.Y};if($q.X+$q.Width -gt $x1){$x1=$q.X+$q.Width};if($q.Y+$q.Height -gt $y1){$y1=$q.Y+$q.Height}};$lines+=@{t=$l.Text;x=$x0;y=$y0;w=$x1-$x0;h=$y1-$y0}}
  $out=@{w=$b.PixelWidth;h=$b.PixelHeight;lines=$lines}|ConvertTo-Json -Depth 4 -Compress
  $b.Dispose();$s.Dispose()
 }catch{$out=@{error="$_"}|ConvertTo-Json -Compress}
 $o.WriteLine($out)
 }
}
""";

class _OcrWorker {
  Process? _p;
  StreamIterator<String>? _lines;
  Future<void> _queue = Future.value();
  bool _failed = false;

  Future<bool>? _starting;
  Directory? _reqDir;
  int _seq = 0;

  /// 작업자를 띄운다. 동시에 여러 번 불려도 한 번만 띄운다.
  /// (미리 띄우기와 첫 인식 요청이 겹치면 작업자가 둘 생겨, 요청은 한쪽에 보내고
  /// 답은 다른 쪽에서 기다리다 20초를 허비하던 문제가 있었다)
  Future<bool> _ensure() {
    if (_p != null) return Future.value(true);
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<bool> _start() async {
    if (_failed || !Platform.isWindows) return false;
    try {
      // 스크립트를 파일로 두고 실행한다 (긴 명령줄을 보안 프로그램이 막는 경우가 있음)
      final script = File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}gm_ocr_worker.ps1');
      await script.writeAsString(_ocrWorkerScript, flush: true);
      // 요청 파일을 놓을 폴더 (앱 실행마다 따로)
      final dir = Directory(
          '${Directory.systemTemp.path}${Platform.pathSeparator}gm_ocr_req_$pid');
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);
      _reqDir = dir;
      final p = await Process.start('powershell', [
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', script.path, dir.path, '$pid',
      ]);
      p.stderr.drain<void>();
      final it = StreamIterator(p.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter()));
      final sw = Stopwatch()..start();
      final ok = await it
          .moveNext()
          .timeout(const Duration(seconds: 25), onTimeout: () => false);
      if (!ok || !it.current.contains('READY')) {
        p.kill();
        _failed = true;
        _ocrLog('worker failed to start');
        return false;
      }
      _ocrLog('worker ready in ${sw.elapsedMilliseconds}ms');
      _p = p;
      _lines = it;
      p.exitCode.then((_) {
        if (identical(_p, p)) {
          _p = null;
          _lines = null;
        }
      });
      return true;
    } catch (e) {
      _failed = true;
      _ocrLog('worker exception: $e');
      return false;
    }
  }

  /// JSON 문자열을 돌려준다. 작업자를 쓸 수 없으면 null.
  Future<String?> run(String path) {
    final c = Completer<String?>();
    _queue = _queue.then((_) async {
      try {
        if (!await _ensure()) return c.complete(null);
        final sw = Stopwatch()..start();
        // 요청을 보낸 바로 그 작업자의 답을 읽는다
        final p = _p!, lines = _lines!;
        // 다 쓴 뒤 이름을 바꿔, 작업자가 쓰다 만 요청을 읽지 않게 한다
        final base =
            '${_reqDir!.path}${Platform.pathSeparator}${(_seq++).toString().padLeft(8, '0')}';
        File('$base.tmp')
          ..writeAsStringSync(path, flush: true)
          ..renameSync('$base.req');
        final ok = await lines
            .moveNext()
            .timeout(const Duration(seconds: 8), onTimeout: () => false);
        if (!ok) {
          p.kill();
          if (identical(_p, p)) {
            _p = null;
            _lines = null;
          }
          _ocrLog('worker timeout');
          return c.complete(null);
        }
        final json = lines.current.trim();
        _ocrLog('worker ocr ${sw.elapsedMilliseconds}ms');
        c.complete(json);
      } catch (e) {
        _p?.kill();
        _p = null;
        _lines = null;
        _ocrLog('worker run exception: $e');
        if (!c.isCompleted) c.complete(null);
      }
    });
    return c.future;
  }
}

final _OcrWorker _worker = _OcrWorker();

/// 앱 시작 뒤 한 번 호출해 인식 엔진을 미리 띄워 둔다
Future<void> prewarmOcr() async {
  if (!Platform.isWindows) return;
  await _worker._ensure();
  _pruneOcrDiskCache();
}

// ── 인식 결과 보관 (Windows) ──
// 사진 창은 따로 실행되는 프로그램이라 매번 인식 엔진을 새로 띄워야 한다. 그래서
// 본 앱이 사진을 여는 순간 (이미 떠 있는 엔진으로) 먼저 인식해 결과를 파일로 남기고,
// 사진 창은 그 파일이 있으면 바로 쓴다. 같은 사진을 다시 열 때도 즉시 나온다.
Directory get _ocrDiskDir => Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}gm_ocr_cache');

File? _ocrDiskFile(String path) {
  try {
    final st = File(path).statSync();
    if (st.type == FileSystemEntityType.notFound) return null;
    final key = md5
        .convert(utf8.encode(
            '$path|${st.size}|${st.modified.millisecondsSinceEpoch}'))
        .toString();
    return File('${_ocrDiskDir.path}${Platform.pathSeparator}$key.json');
  } catch (_) {
    return null;
  }
}

/// 일주일 넘은 보관 결과는 지운다
void _pruneOcrDiskCache() {
  try {
    final dir = _ocrDiskDir;
    if (!dir.existsSync()) return;
    final limit = DateTime.now().subtract(const Duration(days: 7));
    for (final f in dir.listSync()) {
      if (f is File && f.statSync().modified.isBefore(limit)) {
        f.deleteSync();
      }
    }
  } catch (_) {}
}

/// 사진 창을 띄우기 직전에 본 앱에서 불러, 인식을 미리 해 둔다
void precomputeOcr(String path) {
  if (Platform.isWindows) recognizeText(path).ignore();
}

OcrResult? _parseOcr(String text) {
  final j = jsonDecode(text) as Map<String, dynamic>;
  if (j['error'] != null) {
    _ocrLog('ocr error: ${j['error']}');
    return null;
  }
  final raw = j['lines'];
  final list = raw is List ? raw : (raw == null ? const [] : [raw]);
  double n(dynamic v) => v is num ? v.toDouble() : 0;
  return OcrResult(n(j['w']), n(j['h']), [
    for (final l in list)
      if (l is Map && '${l['t']}'.trim().isNotEmpty)
        OcrLine('${l['t']}',
            Rect.fromLTWH(n(l['x']), n(l['y']), n(l['w']), n(l['h']))),
  ]);
}

final Map<String, Future<OcrResult?>> _ocrCache = {};

/// 진단용 기록 (%TEMP%\\gm_ocr.log)
void _ocrLog(String msg) {
  try {
    File('${Directory.systemTemp.path}${Platform.pathSeparator}gm_ocr.log')
        .writeAsStringSync('${DateTime.now().toIso8601String()} $msg\n',
            mode: FileMode.append);
  } catch (_) {}
}

Future<OcrResult?> recognizeText(String path) {
  final f = _ocrCache.putIfAbsent(path, () => _recognize(path));
  f.then((r) {
    if (r == null) _ocrCache.remove(path);
  });
  return f;
}

Future<OcrResult?> _recognize(String path) async {
  if (Platform.isMacOS) {
    // macOS: 시스템 글자 인식(Vision)을 앱 쪽 코드로 부른다
    try {
      final json = await const MethodChannel('gm/ocr')
          .invokeMethod<String>('recognize', path);
      return json == null ? null : _parseOcr(json);
    } catch (e) {
      _ocrLog('vision error: $e');
      return null;
    }
  }
  if (!Platform.isWindows) return null;
  // 가장 빠른 길: 이미 인식해 둔 결과 (본 앱이 미리 해 뒀거나 전에 열어 본 사진)
  final disk = _ocrDiskFile(path);
  try {
    if (disk != null && disk.existsSync()) {
      final r = _parseOcr(disk.readAsStringSync());
      if (r != null) {
        _ocrLog('disk cache hit');
        return r;
      }
    }
  } catch (_) {}
  // 빠른 길: 미리 떠 있는 작업자에게 맡긴다
  try {
    // 작업자가 뜨는 사이 본 앱이 결과를 남겼으면 그걸 쓴다
    await _worker._ensure();
    if (disk != null && disk.existsSync()) {
      final r = _parseOcr(disk.readAsStringSync());
      if (r != null) {
        _ocrLog('disk cache hit (late)');
        return r;
      }
    }
    final json = await _worker.run(path);
    if (json != null) {
      final r = _parseOcr(json);
      if (r != null && disk != null) {
        try {
          disk.parent.createSync(recursive: true);
          // 다 쓴 뒤 이름을 바꿔, 사진 창이 쓰다 만 파일을 읽지 않게 한다
          final tmp = File('${disk.path}.$pid.tmp')
            ..writeAsStringSync(json, flush: true);
          tmp.renameSync(disk.path);
        } catch (_) {}
      }
      return r;
    }
  } catch (e) {
    _ocrLog('worker parse exception: $e');
  }
  // 느린 길(예비): 한 번 쓰고 끝나는 실행
  final out = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}gm_ocr_${DateTime.now().microsecondsSinceEpoch}.json');
  const args = [
    '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
    '-ExecutionPolicy', 'Bypass', '-Command', _ocrScript,
  ];
  final env = {'GM_OCR_PATH': path, 'GM_OCR_OUT': out.path};
  Future<bool> waitFor(int ticks) async {
    for (var i = 0; i < ticks; i++) {
      if (await out.exists() && await out.length() > 0) return true;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  try {
    // 분리 실행은 이 환경에서 결과를 내지 못해 8초를 허비했으므로 바로 일반 실행
    final r = await Process.run('powershell', args, environment: env)
        .timeout(const Duration(seconds: 25));
    if (r.exitCode != 0) _ocrLog('attached exit ${r.exitCode}: ${r.stderr}');
    await waitFor(5);
    if (!await out.exists()) return null;
    final j = jsonDecode(await out.readAsString()) as Map<String, dynamic>;
    if (j['error'] != null) {
      _ocrLog('ocr error: ${j['error']}');
      return null;
    }
    _ocrLog('ok ${j['w']}x${j['h']} lines=${(j['lines'] as List?)?.length}');
    final raw = j['lines'];
    final list = raw is List ? raw : (raw == null ? const [] : [raw]);
    double n(dynamic v) => v is num ? v.toDouble() : 0;
    return OcrResult(n(j['w']), n(j['h']), [
      for (final l in list)
        if (l is Map && '${l['t']}'.trim().isNotEmpty)
          OcrLine('${l['t']}',
              Rect.fromLTWH(n(l['x']), n(l['y']), n(l['w']), n(l['h']))),
    ]);
  } catch (e) {
    _ocrLog('exception: $e');
    return null;
  } finally {
    try {
      if (await out.exists()) await out.delete();
    } catch (_) {}
  }
}

// ───────────────────────── 사진 뷰어 ─────────────────────────

final List<Process> _viewerProcs = [];

/// 열려 있는 사진 창을 모두 닫는다 (앱 종료·잠금 때)
void closeImageViewers() {
  for (final p in _viewerProcs) {
    p.kill();
  }
  _viewerProcs.clear();
}

/// 사진을 연다. Windows 에서는 따로 움직일 수 있는 별도 창으로 띄운다.
Future<void> showImageViewer(BuildContext context, AppState state,
    List<MediaItem> items, int index, List<String> titles) async {
  if (Platform.isWindows || Platform.isMacOS) {
    try {
      // 누른 사진만 기다렸다가 곧바로 창을 띄운다. 나머지 사진은 준비되는 대로
      // '추가 파일'에 한 줄씩 적어 주고, 사진 창이 그걸 읽어 채운다.
      final futures = [
        for (final it in items)
          state.mediaFile(it).then<String?>((p) => p, onError: (_) => null)
      ];
      final first = await futures[index];
      if (first != null && context.mounted) {
        // 사진 창이 뜨는 동안, 이미 떠 있는 엔진으로 글자를 먼저 인식해 둔다
        precomputeOcr(first);
        final stamp = DateTime.now().microsecondsSinceEpoch;
        final tmp = '${Directory.systemTemp.path}${Platform.pathSeparator}';
        final spec = File('${tmp}gm_viewer_$stamp.json');
        final more = File('${tmp}gm_viewer_$stamp.more');
        await more.writeAsString('');
        await spec.writeAsString(jsonEncode({
          'index': index,
          'paths': [
            for (var i = 0; i < items.length; i++) i == index ? first : null
          ],
          'names': [for (final it in items) it.name],
          'titles': [
            for (var i = 0; i < items.length; i++)
              i < titles.length ? titles[i] : ''
          ],
          'more': more.path,
        }));
        // macOS 는 실행 인자가 앱까지 전달되지 않아 환경 변수로도 알린다
        final proc = await Process.start(
            Platform.resolvedExecutable, ['--image-viewer', spec.path],
            environment: {'GM_IMAGE_VIEWER': spec.path});
        _viewerProcs.add(proc);
        var alive = true;
        proc.exitCode.then((_) {
          alive = false;
          _viewerProcs.remove(proc);
          more.delete().ignore();
        });
        for (var i = 0; i < items.length; i++) {
          if (i == index) continue;
          futures[i].then((p) {
            if (!alive) return;
            try {
              more.writeAsStringSync('${jsonEncode({'i': i, 'p': p})}\n',
                  mode: FileMode.append, flush: true);
            } catch (_) {}
          });
        }
        return;
      }
    } catch (_) {}
  }
  if (!context.mounted) return;
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.9),
    builder: (_) => Dialog.fullscreen(
      backgroundColor: Colors.transparent,
      child: ImageViewer(
        count: items.length,
        index: index,
        pathOf: (i) => state.mediaFile(items[i]),
        nameOf: (i) => items[i].name,
        titleOf: (i) => i < titles.length ? titles[i] : '',
      ),
    ),
  );
}

/// 사진 창으로 실행된 경우 (--image-viewer <설정 파일>)
Future<void> runImageViewerWindow(
    String specPath, ThemeData Function(Brightness) theme) async {
  var paths = <String?>[];
  var names = <String>[], titles = <String>[];
  var index = 0;
  String? morePath;
  try {
    final f = File(specPath);
    final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    paths = (j['paths'] as List).cast<String?>();
    names = (j['names'] as List).cast<String>();
    titles = (j['titles'] as List? ?? const []).cast<String>();
    index = j['index'] as int? ?? 0;
    morePath = j['more'] as String?;
    f.delete().ignore();
  } catch (_) {}
  if (paths.isEmpty || index >= paths.length || paths[index] == null) exit(0);
  // 나머지 사진은 본 앱이 준비되는 대로 알려 준다
  final failed = <int>{};
  void readMore() {
    if (morePath == null) return;
    try {
      for (final line in File(morePath).readAsLinesSync()) {
        if (line.isEmpty) continue;
        final m = jsonDecode(line) as Map<String, dynamic>;
        final i = m['i'] as int;
        if (i < 0 || i >= paths.length) continue;
        final p = m['p'] as String?;
        if (p == null) {
          failed.add(i);
        } else {
          paths[i] = p;
        }
      }
    } catch (_) {}
  }

  Future<String> pathOf(int i) async {
    for (var n = 0; n < 300; n++) {
      final p = paths[i];
      if (p != null) return p;
      readMore();
      if (paths[i] != null) return paths[i]!;
      if (failed.contains(i)) throw '사진을 받지 못했습니다';
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw '사진을 받지 못했습니다';
  }

  await windowManager.ensureInitialized();
  windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(980, 760),
      minimumSize: Size(440, 380),
      center: true,
      title: '사진',
      backgroundColor: Color(0xFF111113),
      titleBarStyle: TitleBarStyle.hidden,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  windowManager.addListener(_ExitOnClose());
  prewarmOcr();
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    title: '사진',
    theme: theme(Brightness.dark),
    home: Scaffold(
      backgroundColor: const Color(0xFF111113),
      body: ImageViewer(
        count: paths.length,
        index: index,
        standalone: true,
        pathOf: pathOf,
        nameOf: (i) => i < names.length ? names[i] : '',
        titleOf: (i) => i < titles.length ? titles[i] : '',
      ),
    ),
  ));
}

/// 사진 창을 닫으면 그 프로세스도 끝낸다
class _ExitOnClose with WindowListener {
  @override
  void onWindowClose() => exit(0);
}

class ImageViewer extends StatefulWidget {
  const ImageViewer(
      {super.key,
      required this.count,
      required this.index,
      required this.pathOf,
      required this.nameOf,
      required this.titleOf,
      this.standalone = false});
  final int count;
  final int index;
  final Future<String> Function(int index) pathOf;
  final String Function(int index) nameOf;

  /// 제목 줄: 상대 연락처와 받은 날짜·시각
  final String Function(int index) titleOf;

  /// 별도 창으로 떠 있음 (닫기 = 창 닫기)
  final bool standalone;

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> {
  late int _i = widget.index.clamp(0, widget.count - 1);
  final _tc = TransformationController();
  final _focus = FocusNode();
  String? _path;
  Size? _natural;
  String? _error;
  int _turns = 0;
  /// 글자 모드: 켜면 사진 속 글자만 밝게 강조되고 끌어서 선택할 수 있다
  bool _liveText = false;
  bool _ocrBusy = false;
  OcrResult? _ocr;

  /// 사진 속 글자에서 찾은 계좌 정보 (은행·계좌번호·예금주). 없으면 null
  AccountInfo? _account;
  String? _toast;
  Timer? _toastTimer;

  String get _name => widget.nameOf(_i);
  String get _title => widget.titleOf(_i);
  String _selected = '';

  /// 우클릭 메뉴
  Future<void> _menu(Offset at, Size viewport) async {
    final ocr = _ocr;
    final hasText = ocr != null && ocr.text.trim().isNotEmpty;
    PopupMenuItem<String> mi(String v, IconData icon, String label,
            {bool enabled = true}) =>
        PopupMenuItem<String>(
          value: v,
          enabled: enabled,
          height: 40,
          child: Row(children: [
            Icon(icon, size: 18),
            const SizedBox(width: 12),
            Text(label, style: const TextStyle(fontSize: 13.5)),
          ]),
        );
    final v = await showFadeMenu<String>(
      context: context,
      at: at,
      items: [
        if (_selected.trim().isNotEmpty)
          mi('copySel', Symbols.content_copy, '선택한 글자 복사'),
        mi('copy', Symbols.image, '사진 복사', enabled: _path != null),
        mi('save', Symbols.download, '다른 이름으로 저장…', enabled: _path != null),
        mi('open', Symbols.open_in_new, '기본 앱으로 열기', enabled: _path != null),
        const PopupMenuDivider(height: 9),
        if (_account != null) ...[
          mi('copyAccount', Symbols.account_balance,
              '계좌번호 복사 (${_account!.number})'),
          mi('copyAccountAll', Symbols.receipt_long, '계좌 정보 모두 복사'),
          const PopupMenuDivider(height: 9),
        ],
        if (hasText) mi('copyText', Symbols.text_fields, '글자 모두 복사'),
        if (hasText) mi('allText', Symbols.article, '인식한 글자 보기'),
        if (hasText) const PopupMenuDivider(height: 9),
        mi('zoomIn', Symbols.zoom_in, '확대'),
        mi('zoomOut', Symbols.zoom_out, '축소'),
        mi('fit', Symbols.fit_screen, '화면에 맞추기'),
        mi('rotate', Symbols.rotate_right, '회전'),
        const PopupMenuDivider(height: 9),
        mi('close', Symbols.close, '닫기'),
      ],
    );
    if (!mounted) return;
    switch (v) {
      case 'copySel':
        _copyText(_selected, '선택한 글자를 복사했습니다');
      case 'copy':
        _copyImage();
      case 'save':
        _save();
      case 'open':
        launchUrl(Uri.file(_path!));
      case 'copyAccount':
        _copyText(_account!.number, '계좌번호를 복사했습니다');
      case 'copyAccountAll':
        _copyText(_account!.summary, '계좌 정보를 복사했습니다');
      case 'copyText':
        _copyText(ocr!.text, '글자를 복사했습니다');
      case 'allText':
        _showAllText();
      case 'zoomIn':
        _zoom(1.3, viewport);
      case 'zoomOut':
        _zoom(1 / 1.3, viewport);
      case 'fit':
        _tc.value = Matrix4.identity();
      case 'rotate':
        setState(() => _turns = (_turns + 1) % 4);
      case 'close':
        _close();
    }
  }

  void _close() {
    if (widget.standalone) {
      exit(0);
    } else {
      Navigator.pop(context);
    }
  }

  @override
  void initState() {
    super.initState();
    _tc.addListener(_onTransform);
    _load();
  }

  /// 확대했을 때만 끌기를 화면 이동에 쓴다 (평소엔 사진 끌어내기)
  bool _zoomed = false;
  void _onTransform() {
    final z = _tc.value.getMaxScaleOnAxis() > 1.01;
    if (z != _zoomed && mounted) setState(() => _zoomed = z);
  }

  @override
  void dispose() {
    _tc.dispose();
    _focus.dispose();
    _toastTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final at = _i;
    setState(() {
      _path = null;
      _natural = null;
      _error = null;
      _ocr = null;
      _account = null;
      _turns = 0;
      _tc.value = Matrix4.identity();
    });
    try {
      final path = await widget.pathOf(_i);
      final size = await _imageSize(path);
      if (!mounted || at != _i) return;
      setState(() {
        _path = path;
        _natural = size;
      });
      if (widget.standalone) {
        windowManager.setTitle(_title.isNotEmpty ? _title : '사진');
      }
      _runOcr(); // 글자가 있는지 미리 알아 둔다
    } catch (e) {
      if (mounted && at == _i) setState(() => _error = '$e');
    }
  }

  Future<void> _runOcr() async {
    final path = _path;
    if (path == null || _ocr != null || _ocrBusy) return;
    setState(() => _ocrBusy = true);
    final r = await recognizeText(path);
    if (!mounted) return;
    setState(() {
      _ocrBusy = false;
      if (path == _path) {
        _ocr = r;
        _account =
            r == null ? null : parseAccount([for (final l in r.lines) l.text]);
      }
    });
  }

  void _say(String msg) {
    _toastTimer?.cancel();
    setState(() => _toast = msg);
    _toastTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  void _go(int d) {
    final n = _i + d;
    if (n < 0 || n >= widget.count) return;
    _i = n;
    _load();
  }

  void _zoom(double factor, Size viewport) {
    final cur = _tc.value.getMaxScaleOnAxis();
    final next = (cur * factor).clamp(1.0, 8.0);
    final c = Offset(viewport.width / 2, viewport.height / 2);
    _tc.value = Matrix4.identity()
      ..translateByDouble(c.dx, c.dy, 0, 1)
      ..scaleByDouble(next, next, 1, 1)
      ..translateByDouble(-c.dx, -c.dy, 0, 1);
  }

  Future<void> _save() async {
    final path = _path;
    if (path == null) return;
    final base = path.split(Platform.pathSeparator).last;
    final loc = await getSaveLocation(
        suggestedName: _name.isNotEmpty ? _name : base);
    if (loc == null) return;
    await File(path).copy(loc.path);
    _say('저장했습니다');
  }

  Future<void> _copyImage() async {
    final path = _path;
    if (path == null) return;
    try {
      await Pasteboard.writeFiles([path]);
      _say('사진을 복사했습니다');
    } catch (_) {
      _say('복사하지 못했습니다');
    }
  }

  /// 찾은 계좌 정보 막대: 항목을 누르면 그 값만 복사한다 (계좌번호는 숫자만)
  Widget _accountBar(AccountInfo a) {
    Widget chip(String label, String value, String done, {bool mono = false}) =>
        Tooltip(
          message: '$label 복사',
          child: Material(
            color: Colors.white.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => _copyText(value, done),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(label,
                      style: const TextStyle(
                          color: Colors.white60, fontSize: 11.5)),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            letterSpacing: mono ? 0.4 : 0)),
                  ),
                ]),
              ),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
        color: const Color(0xE6222226),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Symbols.account_balance, size: 18, color: Colors.white70),
          const SizedBox(width: 8),
          if (a.bank.isNotEmpty) ...[
            Flexible(child: chip('은행', a.bank, '은행 이름을 복사했습니다')),
            const SizedBox(width: 6),
          ],
          Flexible(
              flex: 2,
              child:
                  chip('계좌번호', a.number, '계좌번호를 복사했습니다', mono: true)),
          if (a.holder.isNotEmpty) ...[
            const SizedBox(width: 6),
            Flexible(child: chip('예금주', a.holder, '예금주를 복사했습니다')),
          ],
          const SizedBox(width: 4),
          _btn(Symbols.content_copy, '계좌 정보 모두 복사',
              () => _copyText(a.summary, '계좌 정보를 복사했습니다')),
        ],
      ),
    );
  }

  Future<void> _copyText(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    _say(what);
  }

  void _showAllText() {
    final text = _ocr?.text ?? '';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('사진 속 글자'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: SelectableText(text.isEmpty ? '(글자를 찾지 못했습니다)' : text,
                style: const TextStyle(fontSize: 14.5, height: 1.5)),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('닫기')),
          FilledButton(
              onPressed: text.isEmpty
                  ? null
                  : () {
                      Clipboard.setData(ClipboardData(text: text));
                      Navigator.pop(ctx);
                      _say('글자를 모두 복사했습니다');
                    },
              child: const Text('모두 복사')),
        ],
      ),
    );
  }

  KeyEventResult _onKey(FocusNode n, KeyEvent e, Size viewport) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final mod = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (k == LogicalKeyboardKey.escape && widget.standalone) {
      _close();
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      _go(-1);
    } else if (k == LogicalKeyboardKey.arrowRight) {
      _go(1);
    } else if (k == LogicalKeyboardKey.equal || k == LogicalKeyboardKey.add ||
        k == LogicalKeyboardKey.numpadAdd) {
      _zoom(1.3, viewport);
    } else if (k == LogicalKeyboardKey.minus ||
        k == LogicalKeyboardKey.numpadSubtract) {
      _zoom(1 / 1.3, viewport);
    } else if (k == LogicalKeyboardKey.digit0) {
      _tc.value = Matrix4.identity();
    } else if (k == LogicalKeyboardKey.keyR) {
      setState(() => _turns = (_turns + 1) % 4);
    } else if (k == LogicalKeyboardKey.keyS && mod) {
      _save();
    } else if (k == LogicalKeyboardKey.keyC && mod) {
      _copyImage();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Widget _btn(IconData icon, String tip, VoidCallback? onTap,
      {bool active = false}) {
    return Tooltip(
      message: tip,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(9),
          child: Icon(icon,
              size: 22,
              weight: 300,
              color: onTap == null
                  ? Colors.white30
                  : (active ? const Color(0xFF7FB2FF) : Colors.white)),
        ),
      ),
    );
  }

  Widget _picture(Size viewport) {
    final path = _path;
    final nat = _natural;
    if (_error != null) {
      return Text('사진을 열지 못했습니다\n$_error',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70));
    }
    if (path == null || nat == null) {
      return const CircularProgressIndicator(color: Colors.white70);
    }
    // 회전을 반영해 화면에 맞는 크기를 구한다
    final odd = _turns.isOdd;
    final box = Size(viewport.width - 48, viewport.height - 150);
    final rw = odd ? nat.height : nat.width;
    final rh = odd ? nat.width : nat.height;
    final scale = [box.width / rw, box.height / rh, 1.0]
        .reduce((a, b) => a < b ? a : b)
        .clamp(0.01, 1.0);
    final w = nat.width * scale;
    final h = nat.height * scale;
    final ocr = _ocr;
    final sx = ocr == null || ocr.width == 0 ? 0.0 : w / ocr.width;
    final sy = ocr == null || ocr.height == 0 ? 0.0 : h / ocr.height;
    return RotatedBox(
      quarterTurns: _turns,
      child: DragOutFile(
        path: path,
        name: _name,
        // 사진 어디를 잡아도 끌어낼 수 있다 (글자 모드·확대 중은 예외)
        enabled: () => !_liveText && !_zoomed,
        child: MouseRegion(
        cursor: !_liveText && !_zoomed
            ? SystemMouseCursors.grab
            : MouseCursor.defer,
        child: SizedBox(
        width: w,
        height: h,
        child: Stack(
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.file(File(path),
                    fit: BoxFit.fill, filterQuality: FilterQuality.medium),
              ),
            ),
            // 라이브 텍스트: 인식된 줄 위에 투명한 글자를 겹쳐 놓아, 사진 위에서
            // 바로 끌어서 선택하고 Ctrl+C 나 우클릭으로 복사할 수 있게 한다
            // 글자 모드: 글자가 아닌 곳을 어둡게 덮어 글자만 도드라지게 한다
            if (_liveText && ocr != null && ocr.lines.isNotEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _TextSpotlight([
                      for (final l in ocr.lines)
                        Rect.fromLTWH(l.rect.left * sx, l.rect.top * sy,
                            l.rect.width * sx, l.rect.height * sy),
                    ]),
                  ),
                ),
              ),
            if (_liveText && ocr != null)
              Positioned.fill(
                child: SelectionArea(
                  // 우클릭은 뷰어 메뉴가 맡는다
                  contextMenuBuilder: (_, __) => const SizedBox.shrink(),
                  onSelectionChanged: (c) => _selected = c?.plainText ?? '',
                  child: Stack(
                    children: [
                      for (final l in ocr.lines)
                        Positioned(
                          left: l.rect.left * sx,
                          top: l.rect.top * sy,
                          width: (l.rect.width * sx).clamp(1.0, 100000.0),
                          height: (l.rect.height * sy).clamp(1.0, 100000.0),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(2),
                            ),
                            child: FittedBox(
                              fit: BoxFit.fill,
                              child: Text.rich(
                                TextSpan(text: l.text, children: const [
                                  // 복사할 때 줄이 나뉘도록
                                  TextSpan(
                                      text: '\n',
                                      style: TextStyle(fontSize: 0.01)),
                                ]),
                                softWrap: false,
                                style: const TextStyle(
                                    fontSize: 20,
                                    height: 1.0,
                                    color: Colors.transparent),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    )));
  }

  @override
  Widget build(BuildContext context) {
    final many = widget.count > 1;
    final ocr = _ocr;
    return LayoutBuilder(builder: (context, box) {
      final viewport = Size(box.maxWidth, box.maxHeight);
      return Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: (n, e) => _onKey(n, e, viewport),
        child: Listener(
        onPointerDown: (e) {
          if (e.buttons == kSecondaryMouseButton) _menu(e.position, viewport);
        },
        child: Stack(
          children: [
            // 빈 곳: 대화상자면 누르면 닫히고, 별도 창이면 끌어서 창을 옮긴다
            Positioned.fill(
              child: widget.standalone
                  ? const DragToMoveArea(child: SizedBox.expand())
                  : GestureDetector(
                      behavior: HitTestBehavior.opaque, onTap: _close),
            ),
            Positioned.fill(
              child: InteractiveViewer(
                transformationController: _tc,
                // 글자 인식이 켜져 있으면 끌기는 글자 선택에 쓴다 (확대는 휠·버튼)
                panEnabled: _zoomed &&
                    !(_liveText && _ocr != null && _ocr!.lines.isNotEmpty),
                minScale: 1,
                maxScale: 8,
                child: Center(child: _picture(viewport)),
              ),
            ),
            if (many && _i > 0)
              Positioned(
                left: 10,
                top: 0,
                bottom: 0,
                child: Center(
                    child: _btn(Symbols.chevron_left, '이전 사진 (←)',
                        () => _go(-1))),
              ),
            if (many && _i < widget.count - 1)
              Positioned(
                right: 10,
                top: 0,
                bottom: 0,
                child: Center(
                    child: _btn(Symbols.chevron_right, '다음 사진 (→)',
                        () => _go(1))),
              ),
            // 위: 순서·닫기
            Positioned(
              // macOS 별도 창: 신호등 버튼을 피해 오른쪽으로, 같은 높이에 둔다
              top: widget.standalone && Platform.isMacOS ? -4 : 8,
              left: widget.standalone && Platform.isMacOS ? 82 : 16,
              right: 8,
              child: Row(
                children: [
                  Expanded(
                    child: DragToMoveArea(
                    child: SizedBox(
                    height: 40,
                    child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                        [
                          if (many) '${_i + 1} / ${widget.count}',
                          if (_title.isNotEmpty) _title else if (_name.isNotEmpty) _name,
                        ].join('   '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600)),
                  )))),
                  _btn(Symbols.close, '닫기 (Esc)', _close),
                ],
              ),
            ),
            // 아래: 도구 막대
            Positioned(
              bottom: 18,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xE6222226),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _btn(Symbols.zoom_out, '축소 (−)',
                          () => _zoom(1 / 1.3, viewport)),
                      _btn(Symbols.fit_screen, '화면에 맞추기 (0)',
                          () => _tc.value = Matrix4.identity()),
                      _btn(Symbols.zoom_in, '확대 (+)',
                          () => _zoom(1.3, viewport)),
                      _btn(Symbols.rotate_right, '회전 (R)',
                          () => setState(() => _turns = (_turns + 1) % 4)),
                      Container(
                          width: 1,
                          height: 22,
                          margin: const EdgeInsets.symmetric(horizontal: 6),
                          color: Colors.white24),
                      if (Platform.isWindows || Platform.isMacOS) ...[
                        _btn(
                            Symbols.text_fields,
                            ocr != null && ocr.lines.isEmpty
                                ? '사진에서 글자를 찾지 못했습니다'
                                : (_liveText
                                    ? '글자 강조 끄기 (사진을 끌어 내보내기)'
                                    : '글자 강조 — 사진 속 글자만 밝게, 끌어서 선택'),
                            ocr != null && ocr.lines.isEmpty
                                ? null
                                : () {
                                    setState(() => _liveText = !_liveText);
                                    if (_liveText) _runOcr();
                                  },
                            active: _liveText),
                        if (_ocrBusy)
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white70)),
                          )
                        else
                          _btn(
                              Symbols.content_paste_search,
                              ocr == null
                                  ? '글자 보기'
                                  : (ocr.lines.isEmpty
                                      ? '글자를 찾지 못했습니다'
                                      : '인식된 글자 모두 보기·복사'),
                              ocr != null && ocr.lines.isNotEmpty
                                  ? _showAllText
                                  : null),
                        Container(
                            width: 1,
                            height: 22,
                            margin: const EdgeInsets.symmetric(horizontal: 6),
                            color: Colors.white24),
                      ],
                      _btn(Symbols.content_copy, '사진 복사 (${kMod}C)',
                          _path == null ? null : _copyImage),
                      _btn(Symbols.download, '저장 (${kMod}S)',
                          _path == null ? null : _save),
                      _btn(
                          Symbols.open_in_new,
                          '기본 앱으로 열기',
                          _path == null
                              ? null
                              : () => launchUrl(Uri.file(_path!))),
                    ],
                  ),
                ),
              ),
            ),
            // 계좌 정보: 사진에서 은행·계좌번호·예금주를 찾았으면 눌러서 복사
            if (_account != null)
              Positioned(
                bottom: 78,
                left: 12,
                right: 12,
                child: Center(child: _accountBar(_account!)),
              ),
            if (_toast != null)
              Positioned(
                bottom: _account != null ? 128 : 84,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 9),
                    decoration: BoxDecoration(
                      color: const Color(0xF0303036),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(_toast!,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13.5)),
                  ),
                ),
              ),
          ],
        )),
      );
    });
  }
}

/// 사진 크기를 빨리 알아낸다. 머리말에서 원래 크기를 읽고, 작게 풀어 본 결과로
/// 방향(세로로 돌려 찍은 사진)만 확인한다. 사진 전체를 두 번 풀지 않기 위해서다.
Future<Size> _imageSize(String path) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(path);
  final desc = await ui.ImageDescriptor.encoded(buffer);
  var w = desc.width.toDouble(), h = desc.height.toDouble();
  try {
    final codec = await desc.instantiateCodec(targetWidth: 48);
    final frame = await codec.getNextFrame();
    final fw = frame.image.width, fh = frame.image.height;
    frame.image.dispose();
    codec.dispose();
    // 풀어 본 방향이 머리말과 반대면 돌려 찍은 사진이다
    if ((fw > fh) != (w > h) && fw != fh) {
      final t = w;
      w = h;
      h = t;
    }
  } catch (_) {}
  desc.dispose();
  buffer.dispose();
  return Size(w, h);
}

/// 글자 영역만 남기고 나머지를 어둡게 덮는다
class _TextSpotlight extends CustomPainter {
  _TextSpotlight(this.rects);
  final List<Rect> rects;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size);
    var holes = Path();
    for (final r in rects) {
      holes = Path.combine(
          PathOperation.union,
          holes,
          Path()
            ..addRRect(RRect.fromRectAndRadius(
                r.inflate(3), const Radius.circular(5))));
    }
    canvas.drawPath(
        Path.combine(PathOperation.difference, path, holes),
        Paint()..color = Colors.black.withValues(alpha: 0.55));
  }

  @override
  bool shouldRepaint(_TextSpotlight old) => old.rects != rects;
}
