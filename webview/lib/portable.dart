// 포터블(설치 없이 쓰는) 버전: 설정과 로그인 정보를 프로그램 옆 Data 폴더에 둔다.
//
//   GoogleMessagesWeb-Portable\
//     GoogleMessagesWeb.exe   ← 실행 파일 (App\google_messages_web.exe 를 연다)
//     App\                    ← 프로그램 (여기에 빈 파일 `portable` 이 있으면 포터블 모드)
//     Data\                   ← 설정(shared_preferences.json)과 WebView2 프로필
import 'dart:io';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';

/// 포터블 모드에서 쓰는 Data 폴더. 설치본이면 null.
String? portableDataDir;

/// 앱 데이터 폴더(%APPDATA%\...)만 Data 폴더로 바꾼다. 임시 폴더 등은 그대로 둔다.
class _PortablePathProvider extends PathProviderWindows {
  _PortablePathProvider(this.dataDir);
  final String dataDir;

  @override
  Future<String?> getApplicationSupportPath() async => dataDir;
}

/// 실행 파일 옆에 `portable` 파일이 있으면 데이터 위치를 `..\Data` 로 돌린다.
/// 설정을 처음 읽기 전에 불러야 한다. Data 폴더를 만들 수 없으면(읽기 전용 매체 등)
/// 설치본처럼 %APPDATA% 를 쓴다.
void setUpPortableMode() {
  if (!Platform.isWindows) return;
  try {
    final sep = Platform.pathSeparator;
    final exeDir = File(Platform.resolvedExecutable).parent;
    if (!File('${exeDir.path}${sep}portable').existsSync()) return;
    final data = Directory('${exeDir.parent.path}${sep}Data')
      ..createSync(recursive: true);
    final provider = _PortablePathProvider(data.path);
    PathProviderPlatform.instance = provider;
    final store = SharedPreferencesStorePlatform.instance;
    if (store is SharedPreferencesWindows) {
      // ignore: invalid_use_of_visible_for_testing_member
      store.pathProvider = provider;
    }
    portableDataDir = data.path;
  } catch (_) {
    // 설치본과 같은 위치를 쓴다
  }
}
