#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

// Lets native popup menus (the tray menu) follow Windows dark mode (1903+).
// These uxtheme exports are ordinal-only; skip silently when missing.
static void AllowDarkMenus() {
  HMODULE ux = ::LoadLibraryExW(L"uxtheme.dll", nullptr,
                                LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (!ux) return;
  typedef int(WINAPI * SetPreferredAppModeFn)(int);
  typedef void(WINAPI * FlushMenuThemesFn)();
  auto set_mode = reinterpret_cast<SetPreferredAppModeFn>(
      ::GetProcAddress(ux, MAKEINTRESOURCEA(135)));
  auto flush = reinterpret_cast<FlushMenuThemesFn>(
      ::GetProcAddress(ux, MAKEINTRESOURCEA(136)));
  if (set_mode) set_mode(1);  // AllowDark: follow the system setting
  if (flush) flush();
}

// If the app is already running, hands the command-line arguments to it and
// returns true, so this process can leave before the Flutter engine starts.
// The windows_single_instance plugin does the same from Dart, but only once the
// engine is up, and leaving from there takes seconds. Same protocol as the
// plugin (lib/main.dart: ensureSingleInstance): a mutex marks the running
// instance, and it reads a JSON array of strings from a named pipe.
static bool HandOffToRunningInstance(const std::vector<std::string>& args) {
  HANDLE mutex = ::OpenMutexW(
      SYNCHRONIZE, FALSE, L"google_messages_web_single_instance.win.mutex");
  if (!mutex) return false;
  ::CloseHandle(mutex);

  // Let the running instance bring its own window to the front.
  ::AllowSetForegroundWindow(ASFW_ANY);

  std::string json = "[";
  for (size_t i = 0; i < args.size(); ++i) {
    if (i > 0) json += ',';
    json += '"';
    for (unsigned char c : args[i]) {
      if (c == '"' || c == '\\') {
        json += '\\';
        json += static_cast<char>(c);
      } else if (c < 0x20) {
        char escaped[8];
        ::wsprintfA(escaped, "\\u%04x", c);
        json += escaped;
      } else {
        json += static_cast<char>(c);
      }
    }
    json += '"';
  }
  json += ']';

  const wchar_t kPipe[] = L"\\\\.\\pipe\\google_messages_web_single_instance";
  // The pipe serves one client at a time, and does not exist yet while the
  // other instance is still starting: retry briefly, then fall back to Dart.
  for (int attempt = 0; attempt < 10; ++attempt) {
    HANDLE pipe = ::CreateFileW(kPipe, GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                                0, nullptr);
    if (pipe != INVALID_HANDLE_VALUE) {
      DWORD written = 0;
      BOOL ok = ::WriteFile(pipe, json.data(), static_cast<DWORD>(json.size()),
                            &written, nullptr);
      ::CloseHandle(pipe);
      return ok != FALSE;
    }
    if (::GetLastError() == ERROR_PIPE_BUSY) {
      ::WaitNamedPipeW(kPipe, 200);
    } else {
      ::Sleep(100);
    }
  }
  return false;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  if (HandOffToRunningInstance(command_line_arguments)) {
    return EXIT_SUCCESS;
  }
  // "--quit" with nothing running: there is nothing to do, so don't start up.
  for (const auto& arg : command_line_arguments) {
    if (arg == "--quit") return EXIT_SUCCESS;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  AllowDarkMenus();

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"google_messages_web", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
