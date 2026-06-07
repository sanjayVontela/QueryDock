#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>
#include <unordered_set>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  static LRESULT CALLBACK FlutterViewWindowProc(
      HWND window, UINT const message, WPARAM const wparam,
      LPARAM const lparam) noexcept;
  LRESULT HandleFlutterViewMessage(HWND window, UINT const message,
                                   WPARAM const wparam,
                                   LPARAM const lparam) noexcept;
  void ResetPhysicalKeyState();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  HWND flutter_view_window_ = nullptr;
  WNDPROC original_flutter_view_proc_ = nullptr;
  std::unordered_set<UINT> pressed_physical_keys_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
