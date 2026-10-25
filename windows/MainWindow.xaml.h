#pragma once

#include "pch.h"
#include "MainWindow.g.h"

#include <string>
#include <vector>

namespace winrt::RivetHost::implementation {

struct MainWindow : MainWindowT<MainWindow> {
  MainWindow();

  void Refresh_Click(winrt::Windows::Foundation::IInspectable const& sender,
                     Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void MenuCheckUpdates_Click(winrt::Windows::Foundation::IInspectable const& sender,
                              Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void MenuAbout_Click(winrt::Windows::Foundation::IInspectable const& sender,
                       Microsoft::UI::Xaml::RoutedEventArgs const& args);
  // The generated CRTP base wires XAML events, so handlers stay public.
  void MatchList_SelectionChanged(
      winrt::Windows::Foundation::IInspectable const& sender,
      winrt::Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const& args);

 private:
  winrt::fire_and_forget InitializeBackendAsync();
  winrt::fire_and_forget RefreshAsync();
  winrt::fire_and_forget CheckUpdatesAsync();
  void PresentUpdateReport(std::vector<std::string> const& report,
                           std::string const& error);
  winrt::fire_and_forget ShowHostDialog(std::wstring const& title,
                                        std::wstring const& body,
                                        std::wstring const& primary_button,
                                        std::function<void()> on_primary);
  winrt::fire_and_forget ShowDiagram(rivet::Bytes const& png);
  void QueueRefresh();
  void SetStatus(bool ok, winrt::hstring const& message);
  void ApplyResults(std::string const& error,
                    std::vector<std::vector<std::string>> rows,
                    std::string const& explain,
                    rivet::Bytes const& png,
                    std::vector<std::vector<std::string>> lint,
                    std::wstring const& text);
  void RepaintMatchRanges(winrt::Microsoft::UI::Text::ITextDocument const& doc,
                          std::wstring const& text, int inspected);

  // The engine reports code-point offsets; RichEdit ranges are UTF-16 units.
  // Convert so highlights and inspection land on the same characters.
  static int Utf16FromCodePoint(std::wstring const& text, int code_point);

  std::shared_ptr<rivet::windows::Backend> backend_;
  bool busy_ = false;
  winrt::Microsoft::UI::Dispatching::DispatcherQueueTimer refresh_timer_{nullptr};
  std::wstring seeded_text_;
  // UTF-16 spans of the current match list plus the result set they belong
  // to; inspection selection tracks one result set (see ApplyResults).
  std::vector<std::pair<int, int>> match_spans_utf16_;
  std::vector<std::vector<std::string>> match_rows_;
  bool updating_match_list_ = false;
};

}  // namespace winrt::RivetHost::implementation

namespace winrt::RivetHost::factory_implementation {

struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow> {};

}  // namespace winrt::RivetHost::factory_implementation
