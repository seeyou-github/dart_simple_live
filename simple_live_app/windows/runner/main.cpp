#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// 单例互斥体名与窗口类名（窗口类名与 win32_window.cpp 保持一致）
constexpr const wchar_t kSingleInstanceMutex[] =
    L"SimpleLive_Desktop_SingleInstance";
// 唤醒事件名：已有实例用它等待「再次启动」的请求
constexpr const wchar_t kShowWindowEvent[] = L"SimpleLive_Desktop_ShowWindow";
constexpr const wchar_t kRunnerWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr const wchar_t kWindowTitle[] = L"Live";

// 自定义消息：已有实例收到唤醒请求后，交回窗口线程处理
constexpr UINT kMsgShowWindow = WM_APP + 1;

// 等待已有实例创建唤醒事件的最长时间。对方可能还在创建窗口 / 恢复窗口
// 尺寸，这段时间内事件可能尚未创建，所以要短暂重试而不是直接放弃。
constexpr int kOpenEventRetries = 30;
constexpr int kOpenEventIntervalMs = 100;

// 激活窗口：最小化则还原，并置于前台
void ActivateWindow(HWND hwnd) {
  if (hwnd == nullptr) {
    return;
  }
  if (::IsIconic(hwnd)) {
    ::ShowWindow(hwnd, SW_RESTORE);
  } else {
    ::ShowWindow(hwnd, SW_SHOW);
  }
  ::SetForegroundWindow(hwnd);
}

// 打开已有实例的唤醒事件（对方可能尚未创建，短暂重试）
HANDLE OpenShowWindowEvent() {
  for (int i = 0; i < kOpenEventRetries; ++i) {
    HANDLE event = ::OpenEventW(EVENT_MODIFY_STATE, FALSE, kShowWindowEvent);
    if (event != nullptr) {
      return event;
    }
    ::Sleep(kOpenEventIntervalMs);
  }
  return nullptr;
}

// 兜底：按窗口类 + 标题查找。
// 不按「只有窗口类」查找：Flutter 桌面应用的窗口类名都相同，
// 那样会命中其它 Flutter 程序的窗口。
HWND FindRunnerWindow() {
  return ::FindWindowW(kRunnerWindowClass, kWindowTitle);
}

// 事件触发后由线程池回调，把处理动作抛回窗口线程
VOID CALLBACK ShowWindowWaitCallback(PVOID context, BOOLEAN /*timer_fired*/) {
  ::PostMessage(static_cast<HWND>(context), kMsgShowWindow, 0, 0);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when a debugger is present.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // 单例控制：已有实例在运行则唤醒它的窗口后直接退出。
  // 第二个进程不会创建窗口和 Flutter 引擎，因此也不会出现异常退出弹框。
  HANDLE single_instance_mutex =
      ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutex);
  if (single_instance_mutex != nullptr &&
      ::GetLastError() == ERROR_ALREADY_EXISTS) {
    // 优先通过事件通知已有实例（由它自己唤窗口，最可靠）；
    // 事件不可用时退化成直接查找窗口。
    HANDLE show_event = OpenShowWindowEvent();
    if (show_event != nullptr) {
      ::SetEvent(show_event);
      ::CloseHandle(show_event);
    } else {
      ActivateWindow(FindRunnerWindow());
    }
    ::CloseHandle(single_instance_mutex);
    return EXIT_SUCCESS;
  }

  // 在创建窗口之前就建好事件，缩短「第二次启动找不到事件」的时间窗
  HANDLE show_event = ::CreateEventW(nullptr, FALSE, FALSE, kShowWindowEvent);

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
  if (!window.Create(L"Live", origin, size)) {
    if (show_event != nullptr) {
      ::CloseHandle(show_event);
    }
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // 监听唤醒事件：收到后由窗口线程激活窗口
  HANDLE wait_handle = nullptr;
  if (show_event != nullptr) {
    ::RegisterWaitForSingleObject(&wait_handle, show_event,
                                  ShowWindowWaitCallback, window.GetHandle(),
                                  INFINITE, WT_EXECUTEINWAITTHREAD);
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (wait_handle != nullptr) {
    ::UnregisterWaitEx(wait_handle, INVALID_HANDLE_VALUE);
  }
  if (show_event != nullptr) {
    ::CloseHandle(show_event);
  }
  if (single_instance_mutex != nullptr) {
    ::ReleaseMutex(single_instance_mutex);
    ::CloseHandle(single_instance_mutex);
  }
  return EXIT_SUCCESS;
}
