#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <windowsx.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Flutter 视图那个子窗口的原始窗口过程。
WNDPROC g_flutter_child_proc = nullptr;

// 子窗口把"标题栏 / 四边"这几处**让给顶层窗口**：返回 `HTTRANSPARENT`
// 之后系统会去问父窗口，父窗口的 `WM_NCHITTEST` 就会回 HTCAPTION / HTLEFT…
// 于是拖动、双击最大化、贴边缩放都由系统原生完成。
//
// 为什么必须从子窗口让：Flutter 视图铺满整个客户区，鼠标永远落在它上面，
// 顶层窗口的 `WM_NCHITTEST` 根本收不到 —— 这也是上一版"拖动没反应"的原因。
LRESULT CALLBACK FlutterChildWindowProc(HWND window,
                                        UINT const message,
                                        WPARAM const wparam,
                                        LPARAM const lparam) {
  if (message == WM_NCHITTEST) {
    HWND parent = GetParent(window);
    if (parent) {
      POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      ScreenToClient(parent, &point);
      RECT client;
      GetClientRect(parent, &client);
      const UINT dpi = GetDpiForWindow(parent);
      const int border = MulDiv(6, dpi, 96);
      const int caption = MulDiv(44, dpi, 96);
      const int buttons = MulDiv(200, dpi, 96);
      const bool on_edge =
          point.x < border || point.y < border ||
          point.x >= client.right - border || point.y >= client.bottom - border;
      const bool on_caption =
          point.y < caption && point.x < client.right - buttons;
      if (on_caption || (!IsZoomed(parent) && on_edge)) {
        return HTTRANSPARENT;
      }
    }
  }
  return CallWindowProc(g_flutter_child_proc, window, message, wparam, lparam);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  // 「无边框窗口」的按钮通道：Flutter 侧画最小化 / 最大化 / 关闭，
  // 真正执行还是走系统命令（SW_MINIMIZE / SW_MAXIMIZE / WM_CLOSE）。
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "guideline/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        HWND hwnd = GetHandle();
        if (method == "minimize") {
          ShowWindow(hwnd, SW_MINIMIZE);
          result->Success();
        } else if (method == "maximizeRestore") {
          ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
          result->Success();
        } else if (method == "close") {
          PostMessage(hwnd, WM_CLOSE, 0, 0);
          result->Success();
        } else if (method == "isMaximized") {
          result->Success(flutter::EncodableValue(IsZoomed(hwnd) != 0));
        } else {
          result->NotImplemented();
        }
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 给 Flutter 子窗口装上转发：顶部标题栏与四边交给顶层窗口判命中。
  HWND child = flutter_controller_->view()->GetNativeWindow();
  g_flutter_child_proc = reinterpret_cast<WNDPROC>(SetWindowLongPtr(
      child, GWLP_WNDPROC,
      reinterpret_cast<LONG_PTR>(FlutterChildWindowProc)));

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 无边框窗口的三条判定必须**先于** Flutter 的顶层窗口处理：引擎会把
  // WM_NCCALCSIZE 这类消息自己转给 DefWindowProc，之后再交给我们已经晚了。
  switch (message) {
    case WM_NCCALCSIZE:
    case WM_NCHITTEST:
    case WM_GETMINMAXINFO:
      return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
    default:
      break;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
