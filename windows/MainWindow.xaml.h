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

 private:
  winrt::fire_and_forget InitializeBackendAsync();
  winrt::fire_and_forget RefreshAsync();
  winrt::fire_and_forget ShowDiagram(rivet::Bytes const& png);
  void QueueRefresh();
  void SetStatus(bool ok, winrt::hstring const& message);
  void ApplyResults(std::string const& error,
                    std::vector<std::vector<std::string>> rows,
                    std::string const& explain,
                    rivet::Bytes const& png,
                    std::wstring const& text);

  std::shared_ptr<rivet::windows::Backend> backend_;
  bool busy_ = false;
  winrt::Microsoft::UI::Dispatching::DispatcherQueueTimer refresh_timer_{nullptr};
  std::wstring seeded_text_;
};

}  // namespace winrt::RivetHost::implementation

namespace winrt::RivetHost::factory_implementation {

struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow> {};

}  // namespace winrt::RivetHost::factory_implementation
