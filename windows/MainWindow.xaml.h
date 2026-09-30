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
  void Pattern_KeyDown(winrt::Windows::Foundation::IInspectable const& sender,
                       winrt::Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const& args);

 private:
  winrt::fire_and_forget InitializeBackendAsync();
  winrt::fire_and_forget RefreshAsync();
  winrt::fire_and_forget ShowDiagram(rivet::Bytes const& png);
  void SetStatus(bool ok, winrt::hstring const& message);
  void ApplyResults(std::string const& error,
                    std::vector<std::vector<std::string>> rows,
                    std::string const& explain,
                    rivet::Bytes const& png);

  std::shared_ptr<rivet::windows::Backend> backend_;
  bool busy_ = false;
};

}  // namespace winrt::RivetHost::implementation

namespace winrt::RivetHost::factory_implementation {

struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow> {};

}  // namespace winrt::RivetHost::factory_implementation
