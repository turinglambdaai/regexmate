// RegexMate Linux host — GTK4 window over one embedded Racket CS backend.
// Same core as the CLI: pattern entry, sample text with matches rendered to
// a mono pane, explanation, lint findings and the railroad diagram, served
// by typed RVT1 RPCs into app/backend.rkt.
#include <gtk/gtk.h>

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "GeneratedBackend.hpp"

namespace {

struct AppState {
  GtkWindow* window{nullptr};
  GtkLabel* status{nullptr};
  GtkEntry* pattern{nullptr};
  GtkTextView* sample{nullptr};
  GtkLabel* matches{nullptr};
  GtkLabel* explanation{nullptr};
  GtkLabel* lint{nullptr};
  GtkPicture* diagram{nullptr};
  GtkButton* refresh{nullptr};

  std::unique_ptr<rivet::linux_runtime::Backend> backend;
  std::unique_ptr<rivet_app::API> api;
  std::mutex startup_mutex;
  std::thread startup_thread;
  std::unique_ptr<rivet::linux_runtime::Backend> startup_backend;
  std::string startup_error;
  std::atomic<bool> shutting_down{false};

  void set_status(std::string const& text) {
    gtk_label_set_text(status, text.c_str());
  }
};

AppState g_state;

std::filesystem::path executable_path() {
  return std::filesystem::read_symlink("/proc/self/exe");
}

struct RuntimeLayout {
  std::filesystem::path petite_boot;
  std::filesystem::path scheme_boot;
  std::filesystem::path racket_boot;
  std::filesystem::path core;
};

std::optional<RuntimeLayout> discover_runtime_layout() {
  std::filesystem::path const exe = executable_path();
  std::filesystem::path const root = exe.parent_path();
  RuntimeLayout layout{
      root / "runtime" / "petite.boot",
      root / "runtime" / "scheme.boot",
      root / "runtime" / "racket.boot",
      root / "res" / "core.zo",
  };
  if (std::filesystem::exists(layout.petite_boot) &&
      std::filesystem::exists(layout.scheme_boot) &&
      std::filesystem::exists(layout.racket_boot) &&
      std::filesystem::exists(layout.core)) {
    return layout;
  }
  return std::nullopt;
}

std::string sample_text() {
  GtkTextBuffer* buffer = gtk_text_view_get_buffer(g_state.sample);
  GtkTextIter start, end;
  gtk_text_buffer_get_bounds(buffer, &start, &end);
  return gtk_text_buffer_get_text(buffer, &start, &end, FALSE);
}

// ---- results delivered back on the main loop -------------------------

struct RefreshResult {
  bool ok{false};
  std::string error;
  std::vector<std::vector<std::string>> rows;
  std::string explain;
  std::vector<std::vector<std::string>> lint;
  rivet::Bytes png;
};

int on_refresh_delivered(gpointer user_data) {
  std::unique_ptr<RefreshResult> result(static_cast<RefreshResult*>(user_data));
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.refresh), TRUE);

  if (!result->ok) {
    g_state.set_status("Error: " + result->error);
    return G_SOURCE_REMOVE;
  }

  g_state.set_status("Found " + std::to_string(result->rows.size()) +
                     " match(es)");

  if (result->rows.empty()) {
    gtk_label_set_text(g_state.matches, "(no matches)");
  } else {
    std::string table;
    int index = 1;
    for (auto const& row : result->rows) {
      if (row.size() < 4) continue;
      table += std::to_string(index++) + ". " + row[0] + "  [" + row[1] + "-" +
               row[2] + "]  " + row[3] + " group(s)\n";
    }
    gtk_label_set_text(g_state.matches, table.c_str());
  }

  gtk_label_set_text(g_state.explanation, result->explain.c_str());

  if (result->lint.empty()) {
    gtk_label_set_text(g_state.lint, "(no findings)");
  } else {
    std::string lintText;
    for (auto const& row : result->lint) {
      if (row.size() < 4) continue;
      lintText += "[" + row[0] + "] " + row[1] + " @" + row[2] + ": " +
                  row[3] + "\n";
    }
    gtk_label_set_text(g_state.lint, lintText.c_str());
  }

  if (!result->png.empty()) {
    GBytes* bytes = g_bytes_new(result->png.data(), result->png.size());
    GError* error = nullptr;
    GdkTexture* texture = gdk_texture_new_from_bytes(bytes, &error);
    g_bytes_unref(bytes);
    if (texture != nullptr) {
      gtk_picture_set_paintable(g_state.diagram, GDK_PAINTABLE(texture));
      g_object_unref(texture);
    } else if (error != nullptr) {
      g_error_free(error);
    }
  }

  return G_SOURCE_REMOVE;
}

// The linux client exposes std::future APIs; run the five RPCs on a worker
// thread, bundle their payloads into one RefreshResult and marshal the whole
// thing back to the main loop.
struct StatusOutcome {
  bool ok{false};
  std::string error;
};

int on_refresh_delivered_worker(gpointer user_data) {
  std::unique_ptr<RefreshResult> result(static_cast<RefreshResult*>(user_data));
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.refresh), TRUE);
  if (!result->ok) {
    g_state.set_status("Error: " + result->error);
  }
  return G_SOURCE_REMOVE;
}

void deliver_status(rivet_app::Result<std::string> result) {
  auto* delivered = new StatusOutcome;
  try {
    delivered->ok = result.get() == "ok";
    if (!delivered->ok) delivered->error = "the sample pattern is invalid";
  } catch (std::exception const& error) {
    delivered->error = error.what();
  } catch (...) {
    delivered->error = "unknown backend failure";
  }
  g_idle_add(
      [](gpointer user_data) -> int {
        std::unique_ptr<StatusOutcome> result(
            static_cast<StatusOutcome*>(user_data));
        if (result->ok) {
          g_state.set_status("Embedded Racket CS is ready");
        } else {
          g_state.set_status("Backend error: " + result->error);
        }
        return G_SOURCE_REMOVE;
      },
      delivered);
}

struct StartPack {
  std::string pattern;
  std::string text;
};

int on_refresh_delivered(gpointer user_data);

void run_refresh_on_worker(std::shared_ptr<StartPack> pack) {
  auto* delivered = new RefreshResult;
  try {
    rivet_app::API api(*g_state.backend);
    auto status = api.status(pack->pattern).get();
    if (status != "ok") {
      delivered->error = status;
    } else {
      delivered->rows = api.match_rows(pack->pattern, pack->text).get();
      delivered->explain = api.explain_text(pack->pattern).get();
      delivered->lint = api.lint_rows(pack->pattern).get();
      delivered->png = api.diagram_png(pack->pattern).get();
      delivered->ok = true;
    }
  } catch (std::exception const& error) {
    delivered->error = error.what();
  } catch (...) {
    delivered->error = "unknown backend failure";
  }
  g_idle_add(on_refresh_delivered, delivered);
}

int on_start_refresh(gpointer user_data) {
  std::shared_ptr<StartPack>* pack =
      static_cast<std::shared_ptr<StartPack>*>(user_data);
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.refresh), FALSE);
  std::thread worker(run_refresh_on_worker, *pack);
  worker.detach();
  delete pack;
  return G_SOURCE_REMOVE;
}

void start_refresh() {
  if (g_state.api == nullptr) {
    return;
  }
  auto pack = std::make_shared<StartPack>();
  pack->pattern = gtk_entry_get_text(g_state.pattern);
  pack->text = sample_text();
  g_idle_add(on_start_refresh, new std::shared_ptr<StartPack>(pack));
}

int on_backend_finished(gpointer) {
  if (g_state.startup_thread.joinable()) {
    g_state.startup_thread.join();
  }

  std::unique_ptr<rivet::linux_runtime::Backend> backend;
  std::string error;
  {
    std::lock_guard lock(g_state.startup_mutex);
    backend = std::move(g_state.startup_backend);
    error = std::move(g_state.startup_error);
  }

  if (g_state.shutting_down.load(std::memory_order_acquire)) {
    if (backend != nullptr) {
      backend->stop();
    }
    return G_SOURCE_REMOVE;
  }

  if (!error.empty()) {
    g_state.set_status("Backend error: " + error);
    return G_SOURCE_REMOVE;
  }
  if (backend == nullptr) {
    g_state.set_status("Backend error: startup completed without a backend");
    return G_SOURCE_REMOVE;
  }

  g_state.backend = std::move(backend);
  g_state.api = std::make_unique<rivet_app::API>(*g_state.backend);

  g_state.set_status("Embedded Racket CS is ready");
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.refresh), TRUE);
  (void)g_state.api->status("\\d+", deliver_status);
  return G_SOURCE_REMOVE;
}

void start_backend() {
  auto layout = discover_runtime_layout();
  if (!layout.has_value()) {
    g_state.set_status(
        "Missing Rivet runtime layout (runtime/*.boot, res/core.zo) next to "
        "the executable. Build with raco rivet build/dev.");
    return;
  }

  rivet::linux_runtime::RacketRuntimeConfig config;
  config.executable_path = executable_path().string();
  config.petite_boot = layout->petite_boot.string();
  config.scheme_boot = layout->scheme_boot.string();
  config.racket_boot = layout->racket_boot.string();
  config.backend_bundle = layout->core.string();
  config.module_name = rivet_app::kModuleName;
  config.entry_symbol = rivet_app::kEntryName;

  g_state.startup_thread = std::thread([config = std::move(config)]() mutable {
    auto backend =
        std::make_unique<rivet::linux_runtime::Backend>(std::move(config));
    try {
      backend->start();
      {
        std::lock_guard lock(g_state.startup_mutex);
        g_state.startup_backend = std::move(backend);
      }
    } catch (std::exception const& e) {
      std::lock_guard lock(g_state.startup_mutex);
      g_state.startup_error = e.what();
    }
    g_idle_add(on_backend_finished, nullptr);
  });
}

void on_refresh_clicked(GtkButton*, gpointer) {
  auto pack = std::make_shared<StartPack>();
  pack->pattern = gtk_entry_get_text(g_state.pattern);
  pack->text = sample_text();
  g_idle_add(on_start_refresh, new std::shared_ptr<StartPack>(pack));
}

void on_pattern_activate(GtkEntry*, gpointer) {
  auto pack = std::make_shared<StartPack>();
  pack->pattern = gtk_entry_get_text(g_state.pattern);
  pack->text = sample_text();
  g_idle_add(on_start_refresh, new std::shared_ptr<StartPack>(pack));
}

void on_activate(GtkApplication* app, gpointer) {
  if (g_state.window != nullptr) {
    gtk_window_present(g_state.window);
    return;
  }

  auto* window = gtk_application_window_new(app);
  gtk_window_set_title(GTK_WINDOW(window), "RegexMate");
  gtk_window_set_default_size(GTK_WINDOW(window), 1060, 680);

  auto* root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
  gtk_widget_set_margin_top(root, 16);
  gtk_widget_set_margin_bottom(root, 16);
  gtk_widget_set_margin_start(root, 16);
  gtk_widget_set_margin_end(root, 16);

  auto* pattern_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
  auto* pattern_label = gtk_label_new("Pattern");
  auto* pattern = gtk_entry_new();
  gtk_entry_set_placeholder_text(GTK_ENTRY(pattern), "\\d+");
  gtk_editable_set_text(GTK_EDITABLE(pattern), "\\d+");
  gtk_widget_set_hexpand(pattern, TRUE);
  auto* refresh = gtk_button_new_with_label("Refresh");

  gtk_box_append(GTK_BOX(pattern_row), pattern_label);
  gtk_box_append(GTK_BOX(pattern_row), pattern);
  gtk_box_append(GTK_BOX(pattern_row), refresh);
  gtk_box_append(GTK_BOX(root), pattern_row);

  auto* status = gtk_label_new("Starting embedded Racket CS…");
  gtk_widget_add_css_class(status, "dim-label");
  gtk_widget_set_halign(status, GTK_ALIGN_START);
  gtk_box_append(GTK_BOX(root), status);

  auto* columns = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 16);
  gtk_widget_set_vexpand(columns, TRUE);
  auto* left = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
  gtk_widget_set_hexpand(left, TRUE);
  auto* right = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
  gtk_widget_set_hexpand(right, TRUE);

  auto* sample_title = gtk_label_new(nullptr);
  gtk_label_set_markup(GTK_LABEL(sample_title), "<b>Test text</b>");
  gtk_widget_set_halign(sample_title, GTK_ALIGN_START);
  gtk_box_append(GTK_BOX(left), sample_title);
  auto* sample = gtk_text_view_new();
  gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(sample), GTK_WRAP_WORD_CHAR);
  gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(sample)),
                           "Order 12345 shipped on 2026-09-28 to zip 10115.",
                           -1);
  gtk_widget_set_vexpand(sample, TRUE);
  gtk_widget_set_size_request(sample, -1, 110);
  gtk_box_append(GTK_BOX(left), sample);

  auto* matches_title = gtk_label_new(nullptr);
  gtk_label_set_markup(GTK_LABEL(matches_title), "<b>Matches</b>");
  gtk_widget_set_halign(matches_title, GTK_ALIGN_START);
  gtk_box_append(GTK_BOX(left), matches_title);
  auto* matches = gtk_label_new("(no matches)");
  gtk_widget_add_css_class(matches, "monospace");
  gtk_widget_set_halign(matches, GTK_ALIGN_START);
  gtk_widget_set_valign(matches, GTK_ALIGN_START);
  gtk_label_set_xalign(GTK_LABEL(matches), 0.0);
  gtk_label_set_yalign(GTK_LABEL(matches), 0.0);
  gtk_label_set_selectable(matches, TRUE);
  gtk_widget_set_vexpand(matches, TRUE);
  gtk_box_append(GTK_BOX(left), matches);

  auto* explain_title = gtk_label_new(nullptr);
  gtk_label_set_markup(GTK_LABEL(explain_title), "<b>Explanation</b>");
  gtk_widget_set_halign(explain_title, GTK_ALIGN_START);
  gtk_box_append(GTK_BOX(right), explain_title);
  auto* explanation = gtk_label_new(nullptr);
  gtk_widget_add_css_class(explanation, "monospace");
  gtk_label_set_selectable(explanation, TRUE);
  gtk_label_set_xalign(GTK_LABEL(explanation), 0.0);
  gtk_label_set_yalign(GTK_LABEL(explanation), 0.0);
  gtk_widget_set_hexpand(explanation, TRUE);
  gtk_widget_set_vexpand(explanation, TRUE);
  gtk_box_append(GTK_BOX(right), explanation);

  auto* lint_title = gtk_label_new(nullptr);
  gtk_label_set_markup(GTK_LABEL(lint_title), "<b>Lint findings</b>");
  gtk_widget_set_halign(lint_title, GTK_ALIGN_START);
  gtk_box_append(GTK_BOX(right), lint_title);
  auto* lint = gtk_label_new("(no findings)");
  gtk_widget_add_css_class(lint, "monospace");
  gtk_widget_set_halign(lint, GTK_ALIGN_START);
  gtk_widget_set_valign(lint, GTK_ALIGN_START);
  gtk_label_set_xalign(GTK_LABEL(lint), 0.0);
  gtk_label_set_yalign(GTK_LABEL(lint), 0.0);
  gtk_label_set_selectable(lint, TRUE);
  gtk_box_append(GTK_BOX(right), lint);

  auto* diagram_title = gtk_label_new(nullptr);
  gtk_label_set_markup(GTK_LABEL(diagram_title), "<b>Railroad diagram</b>");
  gtk_widget_set_halign(diagram_title, GTK_ALIGN_START);
  gtk_box_append(GTK_BOX(right), diagram_title);
  auto* diagram = gtk_picture_new();
  gtk_widget_set_vexpand(diagram, TRUE);
  gtk_widget_set_hexpand(diagram, TRUE);
  gtk_box_append(GTK_BOX(right), diagram);

  auto* scroll_left = gtk_scrolled_window_new();
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll_left), left);
  gtk_widget_set_vexpand(scroll_left, TRUE);
  auto* scroll_right = gtk_scrolled_window_new();
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll_right), right);
  gtk_widget_set_vexpand(scroll_right, TRUE);

  gtk_box_append(GTK_BOX(columns), scroll_left);
  gtk_box_append(GTK_BOX(columns), scroll_right);
  gtk_box_append(GTK_BOX(root), columns);
  gtk_window_set_child(GTK_WINDOW(window), root);

  g_state.window = GTK_WINDOW(window);
  g_state.status = GTK_LABEL(status);
  g_state.pattern = GTK_ENTRY(pattern);
  g_state.sample = GTK_TEXT_VIEW(sample);
  g_state.matches = GTK_LABEL(matches);
  g_state.explanation = GTK_LABEL(explanation);
  g_state.lint = GTK_LABEL(lint);
  g_state.diagram = GTK_PICTURE(diagram);
  g_state.refresh = GTK_BUTTON(refresh);

  g_signal_connect(refresh, "clicked", G_CALLBACK(on_refresh_clicked), nullptr);
  g_signal_connect(pattern, "activate", G_CALLBACK(on_pattern_activate),
                   nullptr);

  gtk_window_present(GTK_WINDOW(window));
  start_backend();
}

void on_shutdown(GApplication*, gpointer) {
  g_state.shutting_down.store(true, std::memory_order_release);
  if (g_state.startup_thread.joinable()) {
    g_state.startup_thread.join();
  }

  std::unique_ptr<rivet::linux_runtime::Backend> startup_backend;
  {
    std::lock_guard lock(g_state.startup_mutex);
    startup_backend = std::move(g_state.startup_backend);
  }
  if (startup_backend != nullptr) {
    startup_backend->stop();
  }
  if (g_state.backend != nullptr) {
    g_state.backend->stop();
  }
}

}  // namespace

int main(int argc, char** argv) {
  auto* app = gtk_application_new("site.jrtx.regexmate",
                                  G_APPLICATION_DEFAULT_FLAGS);
  g_signal_connect(app, "activate", G_CALLBACK(on_activate), nullptr);
  g_signal_connect(app, "shutdown", G_CALLBACK(on_shutdown), nullptr);
  int const status = g_application_run(G_APPLICATION(app), argc, argv);
  g_object_unref(app);
  return status;
}
