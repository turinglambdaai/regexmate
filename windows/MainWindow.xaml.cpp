#include "pch.h"
#include "MainWindow.xaml.h"
#if __has_include("MainWindow.g.cpp")
#include "MainWindow.g.cpp"
#endif
#include "GeneratedBackend.hpp"

#include <DispatcherQueue.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <winrt/base.h>  // resume_foreground lives in winrt (C++/WinRT base)

#include <stdexcept>

namespace winrt::RivetHost::implementation {
namespace {

std::filesystem::path executable_path() {
  std::wstring buffer(32768, L'\0');
  auto const length = ::GetModuleFileNameW(nullptr, buffer.data(),
                                          static_cast<DWORD>(buffer.size()));
  if (length == 0 || length == buffer.size()) {
    throw std::runtime_error("GetModuleFileNameW failed");
  }
  buffer.resize(length);
  return std::filesystem::path(buffer);
}

std::string utf8(std::filesystem::path const& path) {
  auto const wide = path.wstring();
  if (wide.empty()) {
    return {};
  }
  auto const size = ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                          wide.data(),
                                          static_cast<int>(wide.size()),
                                          nullptr, 0, nullptr, nullptr);
  if (size <= 0) {
    throw std::runtime_error("WideCharToMultiByte failed");
  }
  std::string result(static_cast<std::size_t>(size), '\0');
  if (::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                            wide.data(), static_cast<int>(wide.size()),
                            result.data(), size, nullptr, nullptr) != size) {
    throw std::runtime_error("WideCharToMultiByte failed");
  }
  return result;
}

rivet::windows::RacketRuntimeConfig runtime_config() {
  auto const exe = executable_path();
  auto const root = exe.parent_path();
  auto const runtime = root / L"runtime";

  rivet::windows::RacketRuntimeConfig config;
  config.executable_path = utf8(exe);
  config.petite_boot = utf8(runtime / L"petite.boot");
  config.scheme_boot = utf8(runtime / L"scheme.boot");
  config.racket_boot = utf8(runtime / L"racket.boot");
  config.backend_bundle = utf8(root / L"res" / L"core.zo");
  config.module_name = rivet_app::kModuleName;
  config.entry_symbol = rivet_app::kEntryName;
  config.dll_dir = runtime.wstring();
  return config;
}

}  // namespace

MainWindow::MainWindow() {
  InitializeComponent();
  Title(L"RegexMate");
  InitializeBackendAsync();
}

winrt::fire_and_forget MainWindow::InitializeBackendAsync() {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = std::make_shared<rivet::windows::Backend>(runtime_config());

  try {
    // Booting the embedded runtime can block on file I/O, so only startup is
    // moved off the UI thread. RPC/State traffic below is completion-driven.
    co_await winrt::resume_background();

    backend->start();

    dispatcher.TryEnqueue([weak, backend = std::move(backend)]() mutable {
      if (auto window = weak.get()) {
        window->backend_ = std::move(backend);
        try {
          rivet_app::API api(*window->backend_);
          auto const callbackDispatcher = window->DispatcherQueue();
          auto const callbackWeak = window->get_weak();
          (void)api.status_async("\\d+",
              [callbackDispatcher, callbackWeak](rivet_app::Result<std::string> result) {
                try {
                  (void)result.get();
                  callbackDispatcher.TryEnqueue([callbackWeak] {
                    if (auto current = callbackWeak.get()) {
                      current->SetStatus(true, L"Embedded Racket CS is ready");
                    }
                  });
                } catch (std::exception const& e) {
                  auto message = std::string(e.what());
                  callbackDispatcher.TryEnqueue(
                      [callbackWeak, message = std::move(message)] {
                        if (auto current = callbackWeak.get()) {
                          current->SetStatus(false, winrt::to_hstring(message));
                        }
                      });
                }
              });
          window->RefreshAsync();
        } catch (std::exception const& e) {
          window->SetStatus(false, winrt::to_hstring(e.what()));
        }
      } else {
        // Never destroy the last Backend reference on its own reader thread.
        std::thread([backend = std::move(backend)]() mutable {
          backend->stop();
        }).detach();
      }
    });
  } catch (std::exception const& e) {
    auto message = e.what();
    dispatcher.TryEnqueue([weak, message = std::move(message)] {
      if (auto window = weak.get()) {
        window->SetStatus(false, winrt::to_hstring(message));
      }
    });
  }
}

void MainWindow::Refresh_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  RefreshAsync();
}

void MainWindow::Pattern_KeyDown(
    winrt::Windows::Foundation::IInspectable const&,
    winrt::Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const& args) {
  if (args.Key() == winrt::Windows::System::VirtualKey::Enter) {
    RefreshAsync();
  }
}

winrt::fire_and_forget MainWindow::RefreshAsync() {
  if (busy_) {
    co_return;
  }
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = backend_;
  if (backend == nullptr || !backend->running()) {
    SetStatus(false, winrt::hstring(L"Racket backend is not running"));
    co_return;
  }

  busy_ = true;
  RefreshButton().IsEnabled(false);
  auto const pattern = winrt::to_string(PatternBox().Text());
  auto const text = winrt::to_string(TextBox().Text());

  co_await winrt::resume_background();
  std::string error;
  std::vector<std::vector<std::string>> rows;
  std::string explain;
  rivet::Bytes png;
  try {
    rivet_app::API api(*backend);
    auto const status = api.status(pattern).get();
    if (status != "ok") {
      error = status;
    } else {
      rows = api.match_rows(pattern, text).get();
      explain = api.explain_text(pattern).get();
      png = api.diagram_png(pattern).get();
      if (png.empty()) {
        // diagram failed: surface the backend's staged diagnostic
        auto const diag = api.diagram_diag(pattern).get();
        if (!diag.empty()) explain += "\n[diagram] " + diag;
      }
    }
  } catch (std::exception const& e) {
    error = e.what();
  }

  dispatcher.TryEnqueue([weak, error, rows = std::move(rows),
                         explain = std::move(explain), png = std::move(png)]() mutable {
    if (auto window = weak.get()) {
      window->busy_ = false;
      window->RefreshButton().IsEnabled(true);
      window->ApplyResults(error, std::move(rows), std::move(explain), std::move(png));
    }
  });
}

void MainWindow::ApplyResults(std::string const& error,
                              std::vector<std::vector<std::string>> rows,
                              std::string const& explain,
                              rivet::Bytes const& png) {
  if (!error.empty()) {
    SetStatus(false, winrt::to_hstring(error));
    MatchList().Text(L"(invalid pattern)");
    return;
  }

  SetStatus(true, winrt::hstring(L"Found " + std::to_wstring(rows.size()) + L" match(es)"));

  std::wstring table;
  if (rows.empty()) {
    table = L"(no matches)";
  } else {
    for (std::size_t i = 0; i < rows.size(); ++i) {
      auto const& row = rows[i];
      table += std::to_wstring(i + 1) + L". " + winrt::to_hstring(row[0]) +
               L"   [" + winrt::to_hstring(row[1]) + L"-" +
               winrt::to_hstring(row[2]) + L"]   " +
               winrt::to_hstring(row[3]) + L" group(s)\n";
    }
  }
  MatchList().Text(table);

  ExplainText().Text(winrt::to_hstring(explain));

  if (!png.empty()) {
    ShowDiagram(png);
  }
}

void MainWindow::SetStatus(bool ok, winrt::hstring const& message) {
  Status().Severity(ok ? Microsoft::UI::Xaml::Controls::InfoBarSeverity::Success
                       : Microsoft::UI::Xaml::Controls::InfoBarSeverity::Error);
  Status().Message(message);
  Status().IsOpen(true);
}

winrt::fire_and_forget MainWindow::ShowDiagram(rivet::Bytes const& png) {
  auto const weak = get_weak();
  auto const dispatcher = DispatcherQueue();
  try {
    auto stream = winrt::Windows::Storage::Streams::InMemoryRandomAccessStream();
    auto writer = winrt::Windows::Storage::Streams::DataWriter(stream);
    writer.WriteBytes(winrt::array_view<uint8_t const>(png.data(),
                                                       png.data() + png.size()));
    co_await writer.StoreAsync();
    writer.DetachStream();
    dispatcher.TryEnqueue([weak, stream]() mutable {
      if (auto window = weak.get()) {
        try {
          stream.Seek(0);
          auto bitmap = winrt::Microsoft::UI::Xaml::Media::Imaging::BitmapImage();
          bitmap.SetSource(stream);
          window->Diagram().Source(bitmap);
        } catch (winrt::hresult_error const& e) {
          window->SetStatus(false, winrt::to_hstring(e.message()));
        }
      }
    });
  } catch (std::exception const& e) {
    auto const dispatcher2 = DispatcherQueue();
    auto const weak2 = get_weak();
    auto message = std::string(e.what());
    dispatcher2.TryEnqueue([weak2, message = std::move(message)] {
      if (auto window = weak2.get()) {
        window->SetStatus(false, winrt::to_hstring(message));
      }
    });
  }
}

}  // namespace winrt::RivetHost::implementation
