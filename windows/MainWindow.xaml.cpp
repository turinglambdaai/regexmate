#include "pch.h"
#include "MainWindow.xaml.h"
#if __has_include("MainWindow.g.cpp")
#include "MainWindow.g.cpp"
#endif
#include "GeneratedBackend.hpp"

#include <DispatcherQueue.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <winrt/Microsoft.UI.Windowing.h>  // AppWindow projection for SetIcon
#include <winrt/Windows.System.h>
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

  // WinUI shows a generic placeholder in the title bar unless the window is
  // handed an icon explicitly. The brand icon is compiled into the exe as
  // resource ID 1 (rivet.rktd windows-icon); projects without a windows-icon
  // declaration keep the placeholder.
  if (HICON const icon =
          ::LoadIconW(::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(1))) {
    AppWindow().SetIcon(winrt::Microsoft::UI::IconId{
        static_cast<std::uint64_t>(reinterpret_cast<UINT_PTR>(icon))});
  }
  // seed the sample text and remember it, so refresh only re-applies match
  // formatting and never clobbers what the user typed
  auto doc = TextBox().Document();
  seeded_text_ = L"Order 12345 shipped on 2026-09-28 to zip 10115.";
  doc.SetText(winrt::Microsoft::UI::Text::TextSetOptions::None, seeded_text_);

  refresh_timer_ = DispatcherQueue().CreateTimer();
  refresh_timer_.Interval(std::chrono::milliseconds(300));
  refresh_timer_.IsRepeating(false);
  refresh_timer_.Tick([weak = get_weak()](auto&, auto&) {
    if (auto window = weak.get()) {
      window->RefreshAsync();
    }
  });

  PatternBox().TextChanged([weak = get_weak()](auto const&, auto const&) {
    if (auto window = weak.get()) {
      window->QueueRefresh();
    }
  });
  TextBox().TextChanged([weak = get_weak()](auto const&, auto const&) {
    if (auto window = weak.get()) {
      window->QueueRefresh();
    }
  });

  InitializeBackendAsync();
}

void MainWindow::QueueRefresh() {
  if (!refresh_timer_) {
    return;
  }
  refresh_timer_.Start();
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

void MainWindow::MenuCheckUpdates_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  CheckUpdatesAsync();
}

void MainWindow::MenuAbout_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  (void)ShowHostDialog(
      L"About Regexmate",
      std::wstring(L"RegexMate ") + winrt::to_hstring(rivet_app::kVersion).c_str() +
          L"\n\nLive regular-expression workbench backed by an embedded "
          L"Racket engine. Released under the MIT License.",
      L"", nullptr);
}

winrt::fire_and_forget MainWindow::CheckUpdatesAsync() {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = backend_;
  if (backend == nullptr || !backend->running()) {
    SetStatus(false, winrt::hstring(L"Racket backend is not running"));
    co_return;
  }
  SetStatus(true, winrt::hstring(L"Checking for updates…"));

  co_await winrt::resume_background();
  std::string error;
  std::vector<std::string> report;
  try {
    rivet_app::API api(*backend);
    report = api.update_check().get();
  } catch (std::exception const& e) {
    error = e.what();
  }

  dispatcher.TryEnqueue([weak, report = std::move(report),
                         error = std::move(error)]() mutable {
    if (auto window = weak.get()) {
      window->PresentUpdateReport(report, error);
    }
  });
}

// Mirrors the macOS host's update-report presentation: the backend's
// read-only update-check report is a small line protocol.
void MainWindow::PresentUpdateReport(std::vector<std::string> const& report,
                                     std::string const& error) {
  auto const open_releases = [] {
    try {
      winrt::Windows::System::Launcher::LaunchUriAsync(
          winrt::Windows::Foundation::Uri{
              L"https://github.com/turinglambdaai/regexmate/releases/latest"});
    } catch (...) {
      // Launcher can be unavailable on stripped-down systems; the URL is
      // also in the README.
    }
  };
  if (!error.empty()) {
    (void)ShowHostDialog(L"Check failed", winrt::to_hstring(error).c_str(), L"",
                         nullptr);
    return;
  }
  if (!report.empty() && report.front() == "up-to-date") {
    (void)ShowHostDialog(
        L"You're up to date",
        std::wstring(L"RegexMate ") + winrt::to_hstring(rivet_app::kVersion).c_str() +
            L" is the latest stable build.",
        L"", nullptr);
    return;
  }
  if (!report.empty() && report.front() == "available") {
    auto const version = report.size() > 1 ? winrt::to_hstring(report[1])
                                           : winrt::hstring(L"(unknown)");
    (void)ShowHostDialog(
        std::wstring(L"RegexMate ") + std::wstring(version) +
            L" is available",
        L"Download the latest installer, or run `regexmate update` for a "
        L"portable install — then restart the app.",
        L"Open Releases", open_releases);
    return;
  }
  if (!report.empty() && report.front() == "offline") {
    auto const detail = report.size() > 1 ? winrt::to_hstring(report[1])
                                          : winrt::hstring(
                              L"The update manifest could not be fetched.");
    (void)ShowHostDialog(L"Check failed", detail.c_str(), L"", nullptr);
    return;
  }
  (void)ShowHostDialog(L"Check failed",
                       L"Unexpected update-check report.", L"",
                       nullptr);
}

winrt::fire_and_forget MainWindow::ShowHostDialog(
    std::wstring const& title, std::wstring const& body,
    std::wstring const& primary_button, std::function<void()> on_primary) {
  auto dialog = Microsoft::UI::Xaml::Controls::ContentDialog{};
  dialog.Title(winrt::box_value(title));
  dialog.Content(winrt::box_value(body));
  if (!primary_button.empty()) {
    dialog.PrimaryButtonText(primary_button);
    dialog.DefaultButton(
        Microsoft::UI::Xaml::Controls::ContentDialogButton::Primary);
  }
  dialog.CloseButtonText(L"OK");
  dialog.XamlRoot(Content().XamlRoot());

  auto const weak = get_weak();
  Microsoft::UI::Xaml::Controls::ContentDialogResult result{};
  try {
    result = co_await dialog.ShowAsync();
  } catch (...) {
    co_return;  // another dialog is already up; the flow can be retried
  }
  if (result ==
          Microsoft::UI::Xaml::Controls::ContentDialogResult::Primary &&
      on_primary && weak.get()) {
    on_primary();
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
  winrt::hstring text_h;
  TextBox().Document().GetText(winrt::Microsoft::UI::Text::TextGetOptions::None, text_h);
  std::wstring text_w{text_h};
  auto const text = winrt::to_string(text_w);

  co_await winrt::resume_background();
  std::string error;
  std::vector<std::vector<std::string>> rows;
  std::string explain;
  std::vector<std::vector<std::string>> lint;
  rivet::Bytes png;
  try {
    rivet_app::API api(*backend);
    auto const status = api.status(pattern).get();
    if (status != "ok") {
      error = status;
    } else {
      rows = api.match_rows(pattern, text).get();
      explain = api.explain_text(pattern).get();
      lint = api.lint_rows(pattern).get();
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
                         explain = std::move(explain), png = std::move(png),
                         lint = std::move(lint), text_w = std::move(text_w)]() mutable {
    if (auto window = weak.get()) {
      window->busy_ = false;
      window->RefreshButton().IsEnabled(true);
      window->ApplyResults(error, std::move(rows), std::move(explain), std::move(png), std::move(lint), text_w);
    }
  });
}

void MainWindow::ApplyResults(std::string const& error,
                              std::vector<std::vector<std::string>> rows,
                              std::string const& explain,
                              rivet::Bytes const& png,
                              std::vector<std::vector<std::string>> lint,
                              std::wstring const& text) {
  if (!error.empty()) {
    // An invalid pattern is an error state, not a zero-match result.
    // Everything the dead result set painted — sample highlights, lint
    // findings, the previous pattern's diagram, the inspection selection —
    // clears with it (interaction contract, shared state rules 2 and 4);
    // only the explanation panel keeps the previous pattern's content.
    SetStatus(false, winrt::to_hstring(error));
    match_rows_.clear();
    match_spans_utf16_.clear();
    updating_match_list_ = true;
    MatchList().Items().Clear();
    updating_match_list_ = false;
    MatchList().Visibility(winrt::Microsoft::UI::Xaml::Visibility::Collapsed);
    MatchEmpty().Text(L"Fix the pattern to match");
    MatchEmpty().Visibility(winrt::Microsoft::UI::Xaml::Visibility::Visible);
    RepaintMatchRanges(TextBox().Document(), text, -1);
    LintList().Text(L"(no findings)");
    Diagram().Source(nullptr);
    return;
  }

  SetStatus(true, winrt::hstring(L"Found " + std::to_wstring(rows.size()) + L" match(es)"));

  if (lint.empty()) {
    LintList().Text(L"(no findings)");
  } else {
    std::wstring lintText;
    for (auto const& row : lint) {
      if (row.size() < 4) continue;
      std::wstring severity = std::wstring(winrt::to_hstring(row[0]));
      lintText += (severity == L"warning" ? L"[!] " : L"- ") +
                  std::wstring(winrt::to_hstring(row[1])) + L" @" +
                  std::wstring(winrt::to_hstring(row[2])) + L": " +
                  std::wstring(winrt::to_hstring(row[3])) + L"\n";
    }
    LintList().Text(lintText);
  }

  // Highlight matches inside the test text, then rebuild the match list.
  // The inspection selection tracks one result set: an unchanged result list
  // keeps the selected row, a changed one resets it, so a live edit can
  // never leave the selection pointing at a removed or shifted match.
  {
    bool const same = rows == match_rows_;
    match_rows_ = rows;
    match_spans_utf16_.clear();
    for (auto const& row : rows) {
      if (row.size() < 4) {
        match_spans_utf16_.emplace_back(-1, -1);  // keep list alignment
        continue;
      }
      auto const start = std::stoi(row[1]);
      auto const end = std::stoi(row[2]);
      auto const u16_start = Utf16FromCodePoint(text, start);
      auto const u16_end = Utf16FromCodePoint(text, end);
      auto const length = static_cast<int>(text.size());
      if (u16_start < 0 || u16_end > length || u16_end < u16_start) {
        match_spans_utf16_.emplace_back(-1, -1);
        continue;
      }
      match_spans_utf16_.emplace_back(u16_start, u16_end);
    }

    auto doc = TextBox().Document();
    updating_match_list_ = true;
    auto list = MatchList();
    int const keep = same ? list.SelectedIndex() : -1;
    list.Items().Clear();
    if (rows.empty()) {
      list.Visibility(winrt::Microsoft::UI::Xaml::Visibility::Collapsed);
      MatchEmpty().Text(L"(no matches)");
      MatchEmpty().Visibility(winrt::Microsoft::UI::Xaml::Visibility::Visible);
    } else {
      MatchEmpty().Visibility(winrt::Microsoft::UI::Xaml::Visibility::Collapsed);
      list.Visibility(winrt::Microsoft::UI::Xaml::Visibility::Visible);
      int index = 1;
      for (auto const& row : rows) {
        if (row.size() < 4) continue;
        // Keep the hstrings alive: their c_str() feeds the strings below.
        winrt::hstring const matched = winrt::to_hstring(row[0]);
        winrt::hstring const start = winrt::to_hstring(row[1]);
        winrt::hstring const end = winrt::to_hstring(row[2]);
        auto item = winrt::Microsoft::UI::Xaml::Controls::TextBlock();
        item.Text(std::to_wstring(index) + L". " +
                  std::wstring(row[0].empty() ? L"∅" : matched) + L"   [" +
                  std::wstring(start) + L", " + std::wstring(end) + L")" +
                  L"   " + std::wstring(winrt::to_hstring(row[3])) + L" group(s)");
        // One assistive name spelling out the inspection contract: which
        // match of how many, the matched text or zero-width position, the
        // span and the capture-group count.
        std::wstring name = L"Match " + std::to_wstring(index) + L" of " +
                            std::to_wstring(rows.size()) + L": ";
        if (row[0].empty()) {
          name += L"zero-width match at character " + std::wstring(start);
        } else {
          name += L"'" + std::wstring(matched) + L"', characters " +
                  std::wstring(start) + L" to " + std::wstring(end);
        }
        auto const groups = std::stoi(row[3]);
        if (groups > 0) {
          name += L", " + std::to_wstring(groups) +
                  (groups == 1 ? L" capture group" : L" capture groups");
        }
        winrt::Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(
            item, winrt::hstring(name));
        list.Items().Append(item);
        ++index;
      }
      if (keep >= 0 && keep < static_cast<int>(rows.size())) {
        list.SelectedIndex(keep);
      }
    }
    updating_match_list_ = false;
    RepaintMatchRanges(doc, text, list.SelectedIndex());
  }

  ExplainText().Text(winrt::to_hstring(explain));

  if (!png.empty()) {
    ShowDiagram(png);
  }
}

// The engine reports code-point offsets; RichEdit ranges count UTF-16 units.
// Convert each boundary so highlights and inspection land on the same
// characters (a surrogate pair is one code point but two units).
int MainWindow::Utf16FromCodePoint(std::wstring const& text, int code_point) {
  int units = 0;
  while (code_point > 0 && units < static_cast<int>(text.size())) {
    wchar_t const c = text[static_cast<std::size_t>(units)];
    bool const surrogatePair =
        c >= 0xD800 && c <= 0xDBFF &&
        units + 1 < static_cast<int>(text.size()) &&
        text[static_cast<std::size_t>(units + 1)] >= 0xDC00 &&
        text[static_cast<std::size_t>(units + 1)] <= 0xDFFF;
    units += surrogatePair ? 2 : 1;
    --code_point;
  }
  return units;
}

// Repaint the sample formatting: every match gets the base tint, the
// inspected match gets the accent treatment so the selection stays visible
// without stealing keyboard focus from the list.
void MainWindow::RepaintMatchRanges(
    winrt::Microsoft::UI::Text::ITextDocument const& doc,
    std::wstring const& text, int inspected) {
  auto const length = static_cast<int32_t>(text.size());
  if (length <= 0) {
    return;
  }
  auto all = doc.GetRange(0, length);
  auto format = all.CharacterFormat();
  format.Bold(winrt::Microsoft::UI::Text::FormatEffect::Off);
  format.BackgroundColor(winrt::Windows::UI::Colors::Transparent());
  format.ForegroundColor(winrt::Windows::UI::Colors::Black());
  all.CharacterFormat(format);
  for (int i = 0; i < static_cast<int>(match_spans_utf16_.size()); ++i) {
    auto const [start, end] = match_spans_utf16_[static_cast<std::size_t>(i)];
    if (start < 0 || end <= start) {
      continue;
    }
    // ITextDocument.GetRange takes (start, end) positions, not a length.
    // Passing a length made RichEdit normalize every reversed range by
    // swapping its bounds, so the five per-match highlights merged into one
    // contiguous band across the middle of the sample (verified on
    // Windows 11 25H2: `Order 12345 shipped on 2026-09-28 to zip` painted,
    // `Or` and ` 10115.` did not — exactly the union of the swapped spans).
    auto range = doc.GetRange(start, end);
    auto matchFormat = range.CharacterFormat();
    matchFormat.Bold(winrt::Microsoft::UI::Text::FormatEffect::On);
    if (i == inspected) {
      matchFormat.BackgroundColor(
          winrt::Windows::UI::Color{0xFF, 0x03, 0x7A, 0x55});
      matchFormat.ForegroundColor(winrt::Windows::UI::Colors::White());
    } else {
      matchFormat.BackgroundColor(
          winrt::Windows::UI::Color{0xFF, 0x90, 0xEE, 0xAE});
    }
    range.CharacterFormat(matchFormat);
  }
}

// Activating a row inspects the match: the editor selection moves to the
// same span (a zero-width match collapses the caret at that offset).
void MainWindow::MatchList_SelectionChanged(
    winrt::Windows::Foundation::IInspectable const& sender,
    winrt::Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&) {
  if (updating_match_list_) {
    return;
  }
  auto list = sender.as<winrt::Microsoft::UI::Xaml::Controls::ListView>();
  int const selected = list.SelectedIndex();
  auto doc = TextBox().Document();
  winrt::hstring text_h;
  doc.GetText(winrt::Microsoft::UI::Text::TextGetOptions::None, text_h);
  std::wstring const text{text_h};
  RepaintMatchRanges(doc, text, selected);
  if (selected >= 0 && selected < static_cast<int>(match_spans_utf16_.size())) {
    auto const [start, end] =
        match_spans_utf16_[static_cast<std::size_t>(selected)];
    if (start >= 0) {
      doc.Selection().SetRange(start, end);
    }
  }
  // Surface the inspection next to the match count: the same summary a
  // screen-reader user hears from the row name.
  std::wstring status = L"Found " + std::to_wstring(match_rows_.size()) +
                        L" match(es)";
  if (selected >= 0 && selected < static_cast<int>(match_rows_.size()) &&
      match_rows_[static_cast<std::size_t>(selected)].size() >= 4) {
    auto const& row = match_rows_[static_cast<std::size_t>(selected)];
    status += L" \u00b7 inspecting match " + std::to_wstring(selected + 1) +
              L" of " + std::to_wstring(match_rows_.size()) + L": ";
    if (row[0].empty()) {
      status += L"zero-width at character " + std::wstring(winrt::to_hstring(row[1]));
    } else {
      status += L"'" + std::wstring(winrt::to_hstring(row[0])) + L"' [" +
                std::wstring(winrt::to_hstring(row[1])) + L", " +
                std::wstring(winrt::to_hstring(row[2])) + L")";
    }
  }
  SetStatus(true, winrt::hstring(status));
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
