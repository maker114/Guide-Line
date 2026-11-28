#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>
#include <windowsx.h>

#include <cstdio>
#include <string>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// 窗口位置 / 大小 / 最大化状态的存档名。
//
// 目录与 `lib/platform/data_directory.dart` 里的 `desktopFolderName` 一致：
// 电脑端数据都落在 `%LOCALAPPDATA%\GuideLine`。窗口状态**不是数据** ——
// 不进备份、不进导出，删掉只是回到"居中 + 默认大小"。
constexpr const wchar_t kWindowStateFileName[] = L"window.state";

struct WindowState {
  RECT rect{};
  bool maximized = false;
  bool valid = false;
};

// `%LOCALAPPDATA%\GuideLine`；拿不到环境变量时返回空串（只是不记忆窗口，不影响启动）。
std::wstring WindowStateDirectory() {
  wchar_t buffer[1024] = {};
  const DWORD length =
      GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, 1024);
  if (length == 0 || length >= 1024) {
    return std::wstring();
  }
  std::wstring directory(buffer, length);
  directory += L"\\GuideLine";
  CreateDirectoryW(directory.c_str(), nullptr);
  return directory;
}

bool ReadWindowState(WindowState* state) {
  const std::wstring directory = WindowStateDirectory();
  if (directory.empty()) {
    return false;
  }
  const std::wstring path = directory + L"\\" + kWindowStateFileName;
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  char text[256] = {};
  DWORD read = 0;
  const BOOL ok = ReadFile(file, text, sizeof(text) - 1, &read, nullptr);
  CloseHandle(file);
  if (!ok || read == 0) {
    return false;
  }
  long x = 0, y = 0, width = 0, height = 0;
  int maximized = 0;
  if (sscanf_s(text, "x=%ld y=%ld w=%ld h=%ld max=%d", &x, &y, &width,
               &height, &maximized) != 5) {
    return false;
  }
  if (width <= 0 || height <= 0) {
    return false;
  }
  state->rect = RECT{x, y, x + width, y + height};
  state->maximized = maximized != 0;
  state->valid = true;
  return true;
}

void WriteWindowState(const RECT& rect, bool maximized) {
  const std::wstring directory = WindowStateDirectory();
  if (directory.empty()) {
    return;
  }
  char text[256] = {};
  const int length =
      sprintf_s(text, sizeof(text), "x=%ld y=%ld w=%ld h=%ld max=%d\n",
                rect.left, rect.top, rect.right - rect.left,
                rect.bottom - rect.top, maximized ? 1 : 0);
  if (length <= 0) {
    return;
  }
  const std::wstring path = directory + L"\\" + kWindowStateFileName;
  const std::wstring temporary = path + L".tmp";
  HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  DWORD written = 0;
  WriteFile(file, text, static_cast<DWORD>(length), &written, nullptr);
  FlushFileBuffers(file);
  CloseHandle(file);
  MoveFileExW(temporary.c_str(), path.c_str(),
              MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
}

// 存档里的矩形至少要有这么一块落在某个显示器的工作区里，才算"看得见"。
bool IsUsableOnScreen(const RECT& rect) {
  HMONITOR monitor = MonitorFromRect(&rect, MONITOR_DEFAULTTONULL);
  if (monitor == nullptr) {
    return false;
  }
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (!GetMonitorInfo(monitor, &info)) {
    return false;
  }
  RECT overlap{};
  if (!IntersectRect(&overlap, &rect, &info.rcWork)) {
    return false;
  }
  return (overlap.right - overlap.left) >= 120 &&
         (overlap.bottom - overlap.top) >= 60;
}

// 把矩形夹进最近那个显示器的工作区：换过显示器 / 分辨率变小之后也不会跑到屏幕外。
void ClampToWorkArea(RECT* rect) {
  HMONITOR monitor = MonitorFromRect(rect, MONITOR_DEFAULTTONEAREST);
  if (monitor == nullptr) {
    return;
  }
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (!GetMonitorInfo(monitor, &info)) {
    return;
  }
  const RECT work = info.rcWork;
  int width = rect->right - rect->left;
  int height = rect->bottom - rect->top;
  const int work_width = work.right - work.left;
  const int work_height = work.bottom - work.top;
  if (width > work_width) width = work_width;
  if (height > work_height) height = work_height;
  int left = rect->left;
  int top = rect->top;
  if (left < work.left) left = work.left;
  if (top < work.top) top = work.top;
  if (left + width > work.right) left = work.right - width;
  if (top + height > work.bottom) top = work.bottom - height;
  rect->left = left;
  rect->top = top;
  rect->right = left + width;
  rect->bottom = top + height;
}

void CenterOnNearestMonitor(RECT* rect) {
  HMONITOR monitor = MonitorFromRect(rect, MONITOR_DEFAULTTONEAREST);
  if (monitor == nullptr) {
    monitor = MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
  }
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (!GetMonitorInfo(monitor, &info)) {
    return;
  }
  const RECT work = info.rcWork;
  const int width = rect->right - rect->left;
  const int height = rect->bottom - rect->top;
  const int left = work.left + (work.right - work.left - width) / 2;
  const int top = work.top + (work.bottom - work.top - height) / 2;
  rect->left = left;
  rect->top = top;
  rect->right = left + width;
  rect->bottom = top + height;
}

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(),
      WS_POPUP | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  initial_rect_ = RECT{
      Scale(origin.x, scale_factor),
      Scale(origin.y, scale_factor),
      Scale(origin.x, scale_factor) + Scale(size.width, scale_factor),
      Scale(origin.y, scale_factor) + Scale(size.height, scale_factor),
  };
  // 先按存档摆好，再建 Flutter 视图 —— 视图的初始尺寸取自客户区，
  // 晚一步就会先按默认大小建一次、再被撑开（闪一下）。
  RestorePlacement();

  UpdateTheme(window);

  return OnCreate();
}

void Win32Window::RestorePlacement() {
  WindowState state;
  const bool restored = ReadWindowState(&state);
  RECT rect = restored ? state.rect : initial_rect_;

  // 存档落在看不见的地方（换显示器 / 分辨率变小 / 显示器被拔掉）⇒ 当作没有存档，
  // 居中到当前显示器 —— 比"窗口在屏幕外、只能靠任务栏找回来"强。
  if (!restored || !IsUsableOnScreen(rect)) {
    rect = initial_rect_;
    CenterOnNearestMonitor(&rect);
  } else {
    ClampToWorkArea(&rect);
  }

  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  placement.rcNormalPosition = rect;
  placement.showCmd = restored && state.maximized ? SW_SHOWMAXIMIZED
                                                  : SW_SHOWNORMAL;
  SetWindowPlacement(window_handle_, &placement);
  start_maximized_ = placement.showCmd == SW_SHOWMAXIMIZED;
}

void Win32Window::SavePlacement() {
  if (!window_handle_) {
    return;
  }
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  if (!GetWindowPlacement(window_handle_, &placement)) {
    return;
  }
  // 最小化时 `showCmd` 是 SW_SHOWMINIMIZED，但 `rcNormalPosition` 仍是还原后的
  // 位置 / 大小 —— 正好是下次该恢复的东西。
  const bool maximized = IsZoomed(window_handle_) != 0 ||
                         placement.showCmd == SW_SHOWMAXIMIZED;
  WriteWindowState(placement.rcNormalPosition, maximized);
}

bool Win32Window::Show() {
  // `SW_SHOWNORMAL` 会把最大化状态还原掉，所以恢复时要用 `SW_SHOWMAXIMIZED`。
  return ShowWindow(window_handle_,
                    start_maximized_ ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_DESTROY:
      // 程序内销毁（不经过 WM_CLOSE）时也把最后的摆放记下来。
      SavePlacement();
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_CLOSE:
      SavePlacement();
      break;

    case WM_EXITSIZEMOVE:
      // 拖完 / 拉完边框：这时用户已经定下了新的位置与大小，记下来。
      SavePlacement();
      break;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_NCCALCSIZE: {
      // 无边框：客户区直接铺满整个窗口，原生标题栏与边框都不画。
      // 窗口样式仍保留 WS_OVERLAPPEDWINDOW —— 这样贴边分屏、最小化动画、
      // Alt+Space 系统菜单都还在，只是"看不见了"。
      if (wparam == TRUE) {
        auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
        if (IsZoomed(hwnd)) {
          // 最大化时窗口会比工作区大出一圈，这里按工作区校正一次，
          // 否则内容贴边会被裁掉几个像素。
          MONITORINFO monitor_info{};
          monitor_info.cbSize = sizeof(monitor_info);
          if (GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                             &monitor_info)) {
            params->rgrc[0] = monitor_info.rcWork;
          }
        }
        return 0;
      }
      break;
    }

    case WM_NCHITTEST: {
      // 没有原生边框之后，拖动与缩放都要自己判：四边 6dp 交给系统缩放，
      // 顶部 44dp 当标题栏（可拖、可双击最大化），右侧给窗口按钮留出来。
      POINT cursor{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      ScreenToClient(hwnd, &cursor);
      RECT client;
      GetClientRect(hwnd, &client);
      const UINT dpi = GetDpiForWindow(hwnd);
      const int border = MulDiv(6, dpi, 96);
      const bool left = cursor.x < border;
      const bool right = cursor.x >= client.right - border;
      const bool top = cursor.y < border;
      const bool bottom = cursor.y >= client.bottom - border;

      if (!IsZoomed(hwnd)) {
        if (top && left) return HTTOPLEFT;
        if (top && right) return HTTOPRIGHT;
        if (bottom && left) return HTBOTTOMLEFT;
        if (bottom && right) return HTBOTTOMRIGHT;
        if (left) return HTLEFT;
        if (right) return HTRIGHT;
        if (top) return HTTOP;
        if (bottom) return HTBOTTOM;
      }

      return HTCLIENT;
    }

    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      const UINT dpi = GetDpiForWindow(hwnd);
      info->ptMinTrackSize.x = MulDiv(900, dpi, 96);
      info->ptMinTrackSize.y = MulDiv(620, dpi, 96);
      return 0;
    }

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }

  // 圆角：Windows 11 的 DWM 会把整个窗口按圆角裁切（自绘标题栏的外框一起圆）。
  // Windows 10 上这个属性不被识别，调用失败即可，不影响其它行为。
#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#ifndef DWMWCP_ROUND
#define DWMWCP_ROUND 2
#endif
  const int corner_preference = DWMWCP_ROUND;
  DwmSetWindowAttribute(window, DWMWA_WINDOW_CORNER_PREFERENCE,
                        &corner_preference, sizeof(corner_preference));
}
