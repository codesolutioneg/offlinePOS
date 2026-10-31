#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Puts this exe in the current user's Startup so the till opens with Windows.
// A debug build under build\windows is skipped so a developer machine is not
// registered.
void RegisterStartup() {
  if (::IsDebuggerPresent()) return;
  wchar_t path[MAX_PATH] = {};
  const DWORD n = ::GetModuleFileNameW(nullptr, path, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) return;
  if (wcsstr(path, L"\\build\\windows\\") != nullptr) return;

  HKEY key = nullptr;
  if (::RegOpenKeyExW(HKEY_CURRENT_USER,
                      L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0,
                      KEY_SET_VALUE, &key) != ERROR_SUCCESS) {
    return;
  }
  std::wstring command = L"\"";
  command += path;
  command += L"\"";
  ::RegSetValueExW(key, L"Dishflow", 0, REG_SZ,
                   reinterpret_cast<const BYTE*>(command.c_str()),
                   static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  ::RegCloseKey(key);
}

HWND FindRunningTill(const std::wstring& title) {
  HWND running = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", title.c_str());
  if (!running) {
    running = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Dishflow");
  }
  if (!running) {
    running = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"offline_pos");
  }
  return running;
}

// A second double-click, or Startup plus the shortcut, must not open another
// till. Bring the one already running forward, including when it is minimized.
void BringTillForward(HWND running) {
  if (::IsIconic(running)) {
    ::ShowWindow(running, SW_RESTORE);
  } else {
    ::ShowWindow(running, SW_SHOW);
  }
  const HWND foreground = ::GetForegroundWindow();
  const DWORD foreground_thread =
      foreground ? ::GetWindowThreadProcessId(foreground, nullptr) : 0;
  const DWORD target_thread = ::GetWindowThreadProcessId(running, nullptr);
  const DWORD current = ::GetCurrentThreadId();
  const bool attach_foreground =
      foreground_thread != 0 && foreground_thread != current;
  const bool attach_target = target_thread != 0 && target_thread != current;
  if (attach_foreground) {
    ::AttachThreadInput(current, foreground_thread, TRUE);
  }
  if (attach_target) {
    ::AttachThreadInput(current, target_thread, TRUE);
  }
  ::SetForegroundWindow(running);
  ::BringWindowToTop(running);
  if (attach_target) {
    ::AttachThreadInput(current, target_thread, FALSE);
  }
  if (attach_foreground) {
    ::AttachThreadInput(current, foreground_thread, FALSE);
  }
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // One till per machine. Without this, a second launch opens the same database
  // file the first one holds and dies on it, and an operator who sees nothing
  // happen launches it again, stacking processes that each go nowhere. Held for
  // the life of the process, released by Windows when it exits however it exits.
  // The handle is checked before the error code is believed: a mutex that could
  // not be created at all must not be read as another till already running, or a
  // shop is left with a message box and no way to sell.
  //
  // OFFLINE_POS_INSTANCE names a test copy with its own database (see
  // lib/core/config/test_instance.dart), so it gets its own lock and title.
  std::wstring lock_name = L"offline_pos_single_instance";
  std::wstring title = L"Dishflow";
  wchar_t instance_name[32] = {};
  if (::GetEnvironmentVariableW(L"OFFLINE_POS_INSTANCE", instance_name, 32) > 0 &&
      instance_name[0] != L'\0') {
    lock_name += L"_";
    lock_name += instance_name;
    title += L" ";
    title += instance_name;
  }
  HANDLE instance_lock = ::CreateMutexW(nullptr, TRUE, lock_name.c_str());
  if (instance_lock != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    // The first copy may still be creating its window (Startup and a shortcut
    // at the same moment). Wait for it, then show that one. Never open a second.
    HWND running = nullptr;
    for (int i = 0; i < 50 && running == nullptr; ++i) {
      running = FindRunningTill(title);
      if (running == nullptr) ::Sleep(100);
    }
    if (running) {
      BringTillForward(running);
    } else {
      // Running with no window is the case that used to look like nothing at all
      // happening. A message box needs no Flutter, no database and no console, so
      // it is the one thing that still works when everything else has not started.
      ::MessageBoxW(
          nullptr,
          L"The till is already running on this computer, but it is not "
          L"responding.\r\n\r\nRestart the computer, then open the till again.\r\n"
          L"If it still does not open, call support.",
          L"Dishflow", MB_OK | MB_ICONWARNING);
    }
    ::CloseHandle(instance_lock);
    return EXIT_SUCCESS;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  // A till runs full screen with no title bar, so nothing but the app's own Quit
  // closes it. `--windowed` brings the normal frame back for support work.
  bool windowed = false;
  for (const auto& arg : command_line_arguments) {
    if (arg == "--windowed") windowed = true;
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  window.SetKiosk(!windowed && !::IsDebuggerPresent());
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(title.c_str(), origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  RegisterStartup();

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
