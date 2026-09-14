#include "flutter_window.h"

#include <optional>
#include <shellapi.h>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

constexpr UINT kTrayCallbackMessage = WM_APP + 1;
constexpr UINT kTrayIconId = 1;
constexpr UINT kOpenCommand = 40001;
constexpr UINT kExitCommand = 40002;

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
  lifecycle_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "jet2drop/windows_lifecycle",
          &flutter::StandardMethodCodec::GetInstance());
  lifecycle_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "requestExit") {
          result->Success();
          RequestExit();
          return;
        }
        if (call.method_name() != "setActiveTransfers") {
          result->NotImplemented();
          return;
        }
        const auto* value = std::get_if<bool>(call.arguments());
        if (value == nullptr) {
          result->Error("bad_arguments", "Expected a boolean value.");
          return;
        }
        has_active_transfers_ = *value;
        result->Success();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  taskbar_created_message_ = RegisterWindowMessageW(L"TaskbarCreated");
  AddTrayIcon();

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
  RemoveTrayIcon();
  lifecycle_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    AddTrayIcon();
    return 0;
  }
  if (message == WM_CLOSE) {
    if (!exit_requested_ && tray_icon_added_) {
      ShowWindow(hwnd, SW_HIDE);
      return 0;
    }
    exit_requested_ = true;
    if (has_active_transfers_) {
      const int choice = MessageBoxW(
          hwnd,
          L"\u4ECD\u6709\u6587\u4EF6\u6B63\u5728\u4F20\u8F93\u3002"
          L"\u9000\u51FA\u4F1A\u4E2D\u65AD\u5F53\u524D\u4EFB\u52A1\uFF0C"
          L"\u786E\u5B9A\u5F7B\u5E95\u9000\u51FA\u5417\uFF1F",
          L"Jet2Drop",
          MB_ICONWARNING | MB_YESNO | MB_DEFBUTTON2);
      if (choice != IDYES) {
        exit_requested_ = false;
        return 0;
      }
      has_active_transfers_ = false;
    }
  }
  if (message == kTrayCallbackMessage) {
    switch (LOWORD(lparam)) {
      case NIN_SELECT:
      case NIN_KEYSELECT:
      case WM_LBUTTONUP:
      case WM_LBUTTONDBLCLK:
        ShowMainWindow();
        return 0;
      case WM_CONTEXTMENU:
      case WM_RBUTTONUP:
        ShowTrayMenu();
        return 0;
    }
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

void FlutterWindow::AddTrayIcon() {
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = GetHandle();
  data.uID = kTrayIconId;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  data.uCallbackMessage = kTrayCallbackMessage;
  data.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(data.szTip, L"Jet2Drop");
  tray_icon_added_ = Shell_NotifyIconW(NIM_ADD, &data) == TRUE;
  if (tray_icon_added_) {
    data.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &data);
  }
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_icon_added_) return;
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = GetHandle();
  data.uID = kTrayIconId;
  Shell_NotifyIconW(NIM_DELETE, &data);
  tray_icon_added_ = false;
}

void FlutterWindow::ShowMainWindow() {
  ShowWindow(GetHandle(), SW_RESTORE);
  SetForegroundWindow(GetHandle());
}

void FlutterWindow::ShowTrayMenu() {
  POINT cursor{};
  GetCursorPos(&cursor);
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) return;
  AppendMenuW(menu, MF_STRING | MF_DEFAULT, kOpenCommand,
              L"\u6253\u5F00 Jet2Drop");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kExitCommand,
              L"\u5F7B\u5E95\u9000\u51FA");
  SetForegroundWindow(GetHandle());
  const UINT command = TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, cursor.x, cursor.y,
      0, GetHandle(), nullptr);
  DestroyMenu(menu);
  PostMessage(GetHandle(), WM_NULL, 0, 0);
  if (command == kOpenCommand) ShowMainWindow();
  if (command == kExitCommand) RequestExit();
}

void FlutterWindow::RequestExit() {
  exit_requested_ = true;
  PostMessage(GetHandle(), WM_CLOSE, 0, 0);
}
