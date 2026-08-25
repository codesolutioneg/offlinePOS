#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

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
  HANDLE instance_lock = ::CreateMutexW(nullptr, TRUE, L"offline_pos_single_instance");
  if (instance_lock != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND running = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"offline_pos");
    if (running) {
      // Already selling, just behind something. Bring it forward.
      ::ShowWindow(running, SW_RESTORE);
      ::SetForegroundWindow(running);
    } else {
      // Running with no window is the case that used to look like nothing at all
      // happening. A message box needs no Flutter, no database and no console, so
      // it is the one thing that still works when everything else has not started.
      ::MessageBoxW(
          nullptr,
          L"The till is already running on this computer, but it is not "
          L"responding.\r\n\r\nRestart the computer, then open the till again.\r\n"
          L"If it still does not open, call support.",
          L"offline_pos", MB_OK | MB_ICONWARNING);
    }
    return EXIT_SUCCESS;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"offline_pos", origin, size)) {
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
