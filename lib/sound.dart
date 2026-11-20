import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// 알림 소리 파일(mp3·wav 등)을 재생한다.
/// Windows 는 시스템 재생기(MCI), macOS 는 기본 재생 도구(afplay)를 쓴다.
void playSoundFile(String path) {
  if (!File(path).existsSync()) return;
  try {
    if (Platform.isWindows) {
      final mci = DynamicLibrary.open('winmm.dll').lookupFunction<
          Uint32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32, IntPtr),
          int Function(
              Pointer<Utf16>, Pointer<Utf16>, int, int)>('mciSendStringW');
      void run(String cmd) {
        final p = cmd.toNativeUtf16();
        mci(p, nullptr, 0, 0);
        calloc.free(p);
      }

      run('close gmsound');
      run('open "$path" type mpegvideo alias gmsound');
      run('play gmsound');
    } else if (Platform.isMacOS) {
      Process.start('/usr/bin/afplay', [path]);
    }
  } catch (_) {}
}

/// Windows 클립보드가 바뀔 때마다 늘어나는 번호 (다른 플랫폼은 0)
int clipboardSequence() {
  if (!Platform.isWindows) return 0;
  try {
    return DynamicLibrary.open('user32.dll').lookupFunction<Uint32 Function(),
        int Function()>('GetClipboardSequenceNumber')();
  } catch (_) {
    return 0;
  }
}
