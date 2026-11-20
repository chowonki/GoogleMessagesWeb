import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _CbNative = Void Function(Pointer<Utf8>);
typedef _StartNative = Void Function(
    Pointer<Utf8>, Pointer<NativeFunction<_CbNative>>);
typedef _StartDart = void Function(
    Pointer<Utf8>, Pointer<NativeFunction<_CbNative>>);
typedef _StrNative = Void Function(Pointer<Utf8>);
typedef _StrDart = void Function(Pointer<Utf8>);

class BridgeError implements Exception {
  BridgeError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Go 로 작성한 gmbridge 공유 라이브러리(libgm)와의 연결.
class GmBridge {
  late final DynamicLibrary _lib;
  late final _StartDart _start;
  late final _StrDart _request;
  late final _StrDart _free;
  late final NativeCallable<_CbNative> _callable;

  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();
  final Map<int, Completer<dynamic>> _pending = {};
  int _nextId = 1;

  Stream<Map<String, dynamic>> get events => _events.stream;

  static String _libraryPath() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    if (Platform.isWindows) return '$exeDir\\gmbridge.dll';
    if (Platform.isMacOS) return '$exeDir/../Frameworks/libgmbridge.dylib';
    return '$exeDir/lib/libgmbridge.so';
  }

  void start(String dataDir) {
    _lib = DynamicLibrary.open(_libraryPath());
    _start = _lib.lookupFunction<_StartNative, _StartDart>('GmStart');
    _request = _lib.lookupFunction<_StrNative, _StrDart>('GmRequest');
    _free = _lib.lookupFunction<_StrNative, _StrDart>('GmFree');
    _callable = NativeCallable<_CbNative>.listener(_onNative);
    final dir = dataDir.toNativeUtf8();
    _start(dir, _callable.nativeFunction);
    malloc.free(dir);
  }

  void _onNative(Pointer<Utf8> p) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(p.toDartString()) as Map<String, dynamic>;
    } catch (_) {
      _free(p);
      return;
    }
    _free(p);
    if (msg['type'] == 'result') {
      final c = _pending.remove((msg['id'] as num).toInt());
      if (c == null) return;
      if (msg['ok'] == true) {
        c.complete(msg['data']);
      } else {
        c.completeError(BridgeError((msg['error'] ?? '알 수 없는 오류').toString()));
      }
    } else {
      _events.add(msg);
    }
  }

  Future<dynamic> call(String method, [Map<String, dynamic>? args]) {
    final id = _nextId++;
    final c = Completer<dynamic>();
    _pending[id] = c;
    final req = jsonEncode({'id': id, 'method': method, 'args': args ?? {}})
        .toNativeUtf8();
    _request(req);
    malloc.free(req);
    return c.future;
  }
}
