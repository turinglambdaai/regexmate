#pragma once

#include "pch.h"
#include "App.xaml.g.h"

namespace winrt::RivetHost::implementation {

struct App : AppT<App> {
  App();
  void OnLaunched(Microsoft::UI::Xaml::LaunchActivatedEventArgs const&);

 private:
  Microsoft::UI::Xaml::Window window_{nullptr};
};

}  // namespace winrt::RivetHost::implementation
