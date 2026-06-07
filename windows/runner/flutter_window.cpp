#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr wchar_t kFlutterWindowProperty[] =
    L"QueryDock.FlutterWindow.KeyboardGuard";

bool IsModifierKey(WPARAM key) {
  switch (key) {
    case VK_MENU:
    case VK_LMENU:
    case VK_RMENU:
    case VK_CONTROL:
    case VK_LCONTROL:
    case VK_RCONTROL:
    case VK_SHIFT:
    case VK_LSHIFT:
    case VK_RSHIFT:
    case VK_LWIN:
    case VK_RWIN:
      return true;
    default:
      return false;
  }
}

UINT NormalizeVirtualKey(WPARAM key, LPARAM flags) {
  const UINT scan_code = (static_cast<UINT>(flags) >> 16) & 0xFF;
  const bool extended = (static_cast<UINT>(flags) & (1U << 24)) != 0;

  switch (key) {
    case VK_SHIFT:
    case VK_LSHIFT:
    case VK_RSHIFT: {
      const UINT mapped =
          MapVirtualKey(scan_code, MAPVK_VSC_TO_VK_EX);
      return mapped == VK_RSHIFT ? VK_RSHIFT : VK_LSHIFT;
    }
    case VK_CONTROL:
    case VK_LCONTROL:
    case VK_RCONTROL:
      return extended ? VK_RCONTROL : VK_LCONTROL;
    case VK_MENU:
    case VK_LMENU:
    case VK_RMENU:
      return extended ? VK_RMENU : VK_LMENU;
    default:
      return static_cast<UINT>(key);
  }
}

bool IsModifierStateDown(WPARAM key, LPARAM flags) {
  const UINT normalized_key = NormalizeVirtualKey(key, flags);
  if ((GetKeyState(normalized_key) & 0x8000) != 0) {
    return true;
  }

  // Windows sometimes updates only the generic modifier state for the current
  // message. Check it as a fallback before treating the event as stale.
  switch (normalized_key) {
    case VK_LMENU:
    case VK_RMENU:
      return (GetKeyState(VK_MENU) & 0x8000) != 0;
    case VK_LCONTROL:
    case VK_RCONTROL:
      return (GetKeyState(VK_CONTROL) & 0x8000) != 0;
    case VK_LSHIFT:
    case VK_RSHIFT:
      return (GetKeyState(VK_SHIFT) & 0x8000) != 0;
    default:
      return true;
  }
}

UINT PhysicalKeyId(WPARAM key, LPARAM flags) {
  const UINT scan_code = (static_cast<UINT>(flags) >> 16) & 0xFF;
  const UINT extended = (static_cast<UINT>(flags) >> 24) & 0x01;
  return (scan_code << 1) | extended |
         (NormalizeVirtualKey(key, flags) << 16);
}

bool IsRepeatedModifierKeyDown(UINT message, WPARAM key, LPARAM flags) {
  if (message != WM_KEYDOWN && message != WM_SYSKEYDOWN) {
    return false;
  }

  const bool was_previously_down = (flags & (1LL << 30)) != 0;
  if (!was_previously_down) {
    return false;
  }

  return IsModifierKey(key);
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
  flutter_view_window_ = flutter_controller_->view()->GetNativeWindow();
  SetChildContent(flutter_view_window_);

  SetProp(flutter_view_window_, kFlutterWindowProperty, this);
  original_flutter_view_proc_ = reinterpret_cast<WNDPROC>(SetWindowLongPtr(
      flutter_view_window_, GWLP_WNDPROC,
      reinterpret_cast<LONG_PTR>(&FlutterWindow::FlutterViewWindowProc)));
  if (!original_flutter_view_proc_) {
    RemoveProp(flutter_view_window_, kFlutterWindowProperty);
    flutter_view_window_ = nullptr;
    return false;
  }

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
  ResetPhysicalKeyState();
  if (flutter_view_window_ && original_flutter_view_proc_) {
    SetWindowLongPtr(flutter_view_window_, GWLP_WNDPROC,
                     reinterpret_cast<LONG_PTR>(original_flutter_view_proc_));
    RemoveProp(flutter_view_window_, kFlutterWindowProperty);
  }
  flutter_view_window_ = nullptr;
  original_flutter_view_proc_ = nullptr;

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_ACTIVATEAPP && !wparam) {
    ResetPhysicalKeyState();
  }

  // Windows may emit auto-repeat messages for a held modifier. Some Flutter
  // engine versions classify those as another KeyDownEvent instead of a
  // KeyRepeatEvent, which violates HardwareKeyboard's state invariant.
  if (IsRepeatedModifierKeyDown(message, wparam, lparam)) {
    return 0;
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

LRESULT CALLBACK FlutterWindow::FlutterViewWindowProc(
    HWND window, UINT const message, WPARAM const wparam,
    LPARAM const lparam) noexcept {
  auto* flutter_window = reinterpret_cast<FlutterWindow*>(
      GetProp(window, kFlutterWindowProperty));
  if (!flutter_window) {
    return DefWindowProc(window, message, wparam, lparam);
  }
  return flutter_window->HandleFlutterViewMessage(window, message, wparam,
                                                  lparam);
}

LRESULT FlutterWindow::HandleFlutterViewMessage(
    HWND window, UINT const message, WPARAM const wparam,
    LPARAM const lparam) noexcept {
  if (message == WM_KILLFOCUS || message == WM_CANCELMODE) {
    ResetPhysicalKeyState();
  } else if (message == WM_KEYDOWN || message == WM_SYSKEYDOWN) {
    // A delayed Alt/Ctrl/Shift message can arrive after focus changes with no
    // corresponding Windows modifier state. Forwarding it gives Flutter a
    // RawKeyDownEvent with modifiers == 0, which violates RawKeyboard's state
    // invariant.
    if (IsModifierKey(wparam) && !IsModifierStateDown(wparam, lparam)) {
      return 0;
    }

    const UINT key_id = PhysicalKeyId(wparam, lparam);
    if (!pressed_physical_keys_.insert(key_id).second) {
      if (IsModifierKey(wparam)) {
        return 0;
      }

      // Some Windows/Flutter combinations report an auto-repeat as another
      // KeyDownEvent. Repair the sequence so HardwareKeyboard receives a
      // regular up/down pair while held letters, arrows, and Backspace still
      // repeat normally.
      const UINT key_up_message =
          message == WM_SYSKEYDOWN ? WM_SYSKEYUP : WM_KEYUP;
      const LPARAM key_up_flags = lparam | (1LL << 30) | (1LL << 31);
      CallWindowProc(original_flutter_view_proc_, window, key_up_message,
                     wparam, key_up_flags);
    }
  } else if (message == WM_KEYUP || message == WM_SYSKEYUP) {
    const bool was_pressed =
        pressed_physical_keys_.erase(PhysicalKeyId(wparam, lparam)) != 0;
    if (IsModifierKey(wparam) && !was_pressed) {
      return 0;
    }
  }

  return CallWindowProc(original_flutter_view_proc_, window, message, wparam,
                        lparam);
}

void FlutterWindow::ResetPhysicalKeyState() {
  pressed_physical_keys_.clear();
}
