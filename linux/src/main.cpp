// RegexMate Linux host — GTK4 window over one embedded Racket CS backend.
// Same core as the CLI: a headerbar pattern field with live refresh, sample
// text with matches highlighted in place, a match list, explanation, lint
// findings and the railroad diagram, served by typed RVT1 RPCs into
// app/backend.rkt. Styling uses theme symbolic colors so light and dark
// Adwaita both read right.
#include <gtk/gtk.h>

#include <atomic>
#include <charconv>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "GeneratedBackend.hpp"

namespace {

// Brand tokens (docs/styles.css). Accent is fixed; neutrals come from the
// theme via symbolic colors in the CSS below.
constexpr char const* kAccent = "#037A55";
constexpr char const* kDanger = "#D92D20";
constexpr char const* kWarning = "#B54708";
constexpr char const* kAmber = "#B54708";

constexpr char const* kCss = R"css(
  window { background-color: @theme_bg_color; }
  .card { background: @theme_base_color; border: 1px solid @borders; border-radius: 10px; }
  .pad { padding: 6px 10px; }
  .caption { font-weight: 700; font-size: 88%; letter-spacing: 0.08em; opacity: 0.6; }
  .statusbar { border-top: 1px solid @borders; padding: 5px 14px 7px; }
  .statusbar label { font-size: 90%; }
  .statusdot { font-size: 80%; }
  entry { border-radius: 8px; }
  listbox.matchlist row { padding: 4px 8px; }
  .match-index { opacity: 0.45; font-family: monospace; font-size: 85%; }
  .match-span { opacity: 0.45; font-family: monospace; font-size: 85%; }
  .match-groups { color: #037A55; font-size: 85%; }
)css";

struct AppState {
  GtkWindow* window{nullptr};
  GtkEntry* pattern{nullptr};
  GtkTextView* sample{nullptr};
  GtkTextTag* match_tag{nullptr};
  GtkLabel* matches_caption{nullptr};
  GtkListBox* matches_list{nullptr};
  GtkLabel* explanation{nullptr};
  GtkLabel* lint_caption{nullptr};
  GtkLabel* lint{nullptr};
  GtkPicture* diagram{nullptr};
  GtkButton* refresh{nullptr};
  GtkLabel* status_dot{nullptr};
  GtkLabel* status_text{nullptr};
  GtkLabel* status_counts{nullptr};

  std::unique_ptr<rivet::linux_runtime::Backend> backend;
  std::unique_ptr<rivet_app::API> api;
  std::mutex startup_mutex;
  std::thread startup_thread;
  std::unique_ptr<rivet::linux_runtime::Backend> startup_backend;
  std::string startup_error;
  std::atomic<bool> shutting_down{false};

  guint debounce_id{0};
  std::atomic<int> generation{0};

  void set_status(char const* dot_color, std::string const& text) {
    std::string markup = std::string("<span foreground=\"") + dot_color +
                         "\">●</span>";
    gtk_label_set_markup(status_dot, markup.c_str());
    gtk_label_set_text(status_text, text.c_str());
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

// ---- sample highlighting ---------------------------------------------

void clear_highlights() {
  GtkTextBuffer* buffer = gtk_text_view_get_buffer(g_state.sample);
  GtkTextIter start, end;
  gtk_text_buffer_get_bounds(buffer, &start, &end);
  gtk_text_buffer_remove_tag(buffer, g_state.match_tag, &start, &end);
}

void apply_highlights(std::vector<std::vector<std::string>> const& rows) {
  GtkTextBuffer* buffer = gtk_text_view_get_buffer(g_state.sample);
  GtkTextIter start, end;
  gtk_text_buffer_get_bounds(buffer, &start, &end);
  int const length = gtk_text_iter_get_offset(&end);
  for (auto const& row : rows) {
    if (row.size() < 4) continue;
    int begin = 0;
    int stop = 0;
    std::from_chars(row[1].data(), row[1].data() + row[1].size(), begin);
    std::from_chars(row[2].data(), row[2].data() + row[2].size(), stop);
    if (begin < 0 || stop > length || stop <= begin) continue;
    GtkTextIter a, b;
    gtk_text_buffer_get_iter_at_offset(buffer, &a, begin);
    gtk_text_buffer_get_iter_at_offset(buffer, &b, stop);
    gtk_text_buffer_apply_tag(buffer, g_state.match_tag, &a, &b);
  }
}

// ---- results delivered back on the main loop -------------------------

struct RefreshResult {
  int generation{0};
  bool ok{false};
  std::string error;  // backend-reported pattern problem when !ok
  std::vector<std::vector<std::string>> rows;
  std::string explain;
  std::vector<std::vector<std::string>> lint;
  rivet::Bytes png;
};

GtkWidget* make_match_row(int index, std::string const& text,
                          std::string const& start, std::string const& end,
                          std::string const& groups) {
  auto* row = gtk_list_box_row_new();
  auto* box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
  gtk_widget_set_margin_start(box, 6);
  gtk_widget_set_margin_end(box, 6);

  auto* ordinal = gtk_label_new(std::to_string(index).c_str());
  gtk_widget_add_css_class(ordinal, "match-index");

  auto* value = gtk_label_new(text.empty() ? "∅" : text.c_str());
  gtk_widget_add_css_class(value, "match-text");
  gtk_label_set_ellipsize(GTK_LABEL(value), PANGO_ELLIPSIZE_END);
  gtk_widget_set_hexpand(value, TRUE);
  gtk_widget_set_halign(value, GTK_ALIGN_START);

  auto* span = gtk_label_new(("[" + start + ", " + end + ")").c_str());
  gtk_widget_add_css_class(span, "match-span");

  gtk_box_append(GTK_BOX(box), ordinal);
  gtk_box_append(GTK_BOX(box), value);
  gtk_box_append(GTK_BOX(box), span);
  int group_count = 0;
  std::from_chars(groups.data(), groups.data() + groups.size(), group_count);
  if (group_count > 0) {
    auto* badge = gtk_label_new(
        (group_count == 1 ? "1 group" : groups + " groups").c_str());
    gtk_widget_add_css_class(badge, "match-groups");
    gtk_box_append(GTK_BOX(box), badge);
  }
  gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), box);
  return row;
}

void clear_match_list() {
  while (GtkWidget* child =
             gtk_widget_get_first_child(GTK_WIDGET(g_state.matches_list))) {
    gtk_list_box_remove(g_state.matches_list, child);
  }
}

void set_counts(int matches, int findings) {
  std::string counts = std::to_string(matches) + " match" +
                       (matches == 1 ? "" : "es") + "  ·  " +
                       std::to_string(findings) + " finding" +
                       (findings == 1 ? "" : "s");
  gtk_label_set_text(g_state.status_counts, counts.c_str());
  std::string caption = "MATCHES · " + std::to_string(matches);
  gtk_label_set_text(g_state.matches_caption, caption.c_str());
  std::string lint_caption = "LINT FINDINGS · " + std::to_string(findings);
  gtk_label_set_text(g_state.lint_caption, lint_caption.c_str());
}

int on_refresh_delivered(gpointer user_data) {
  std::unique_ptr<RefreshResult> result(static_cast<RefreshResult*>(user_data));
  if (result->generation != g_state.generation.load(std::memory_order_acquire)) {
    return G_SOURCE_REMOVE;  // superseded by a newer refresh
  }

  if (!result->ok) {
    g_state.set_status(kDanger, result->error);
    clear_highlights();
    clear_match_list();
    auto* empty = gtk_list_box_row_new();
    gtk_list_box_row_set_selectable(GTK_LIST_BOX_ROW(empty), FALSE);
    gtk_list_box_row_set_activatable(GTK_LIST_BOX_ROW(empty), FALSE);
    auto* hint = gtk_label_new("Fix the pattern to match");
    gtk_widget_set_halign(hint, GTK_ALIGN_CENTER);
    gtk_widget_add_css_class(hint, "dim");
    gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(empty), hint);
    gtk_list_box_append(g_state.matches_list, empty);
    gtk_label_set_text(g_state.explanation, "—");
    gtk_label_set_text(g_state.lint, "");
    gtk_picture_set_paintable(g_state.diagram, nullptr);
    set_counts(0, 0);
    return G_SOURCE_REMOVE;
  }

  g_state.set_status(kAccent, "Embedded Racket CS is ready");

  clear_match_list();
  if (result->rows.empty()) {
    auto* empty = gtk_list_box_row_new();
    gtk_list_box_row_set_selectable(GTK_LIST_BOX_ROW(empty), FALSE);
    gtk_list_box_row_set_activatable(GTK_LIST_BOX_ROW(empty), FALSE);
    auto* hint = gtk_label_new("No matches");
    gtk_widget_set_halign(hint, GTK_ALIGN_CENTER);
    gtk_widget_add_css_class(hint, "dim");
    gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(empty), hint);
    gtk_list_box_append(g_state.matches_list, empty);
  } else {
    int index = 1;
    for (auto const& row : result->rows) {
      if (row.size() < 4) continue;
      gtk_list_box_append(
          g_state.matches_list,
          make_match_row(index++, row[0], row[1], row[2], row[3]));
    }
  }

  apply_highlights(result->rows);
  gtk_label_set_text(g_state.explanation,
                     result->explain.empty() ? "—" : result->explain.c_str());

  if (result->lint.empty()) {
    gtk_label_set_text(g_state.lint, "");
  } else {
    std::string lint_text;
    for (auto const& row : result->lint) {
      if (row.size() < 4) continue;
      char const* color = kAccent;
      if (row[0] == "error") color = kDanger;
      if (row[0] == "warning") color = kWarning;
      lint_text += std::string("<span foreground=\"") + color +
                   "\" weight=\"bold\" size=\"8300\">" + row[0] +
                   "</span>  <b>" + row[1] + "</b> <span alpha=\"5000\">@" +
                   row[2] + "</span>  " + row[3] + "\n";
    }
    gtk_label_set_markup(g_state.lint, lint_text.c_str());
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
  } else {
    gtk_picture_set_paintable(g_state.diagram, nullptr);
  }

  set_counts(static_cast<int>(result->rows.size()),
             static_cast<int>(result->lint.size()));
  return G_SOURCE_REMOVE;
}

// The linux client exposes std::future APIs; run the five RPCs on a worker
// thread, bundle their payloads into one RefreshResult and marshal the whole
// thing back to the main loop.
struct StartPack {
  int generation;
  std::string pattern;
  std::string text;
};

void run_refresh_on_worker(std::shared_ptr<StartPack> pack) {
  auto* delivered = new RefreshResult;
  delivered->generation = pack->generation;
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

void start_refresh() {
  if (g_state.backend == nullptr) return;
  int const gen = g_state.generation.fetch_add(1, std::memory_order_acq_rel) + 1;
  g_state.set_status(kAmber, "Running…");
  clear_highlights();
  auto pack = std::make_shared<StartPack>();
  pack->generation = gen;
  pack->pattern = gtk_entry_buffer_get_text(gtk_entry_get_buffer(g_state.pattern));
  pack->text = sample_text();
  std::thread worker(run_refresh_on_worker, pack);
  worker.detach();
}

gboolean on_debounce_fired(gpointer) {
  g_state.debounce_id = 0;
  start_refresh();
  return G_SOURCE_REMOVE;
}

// Live refresh: re-run 300 ms after the last keystroke (matches the macOS
// and Windows hosts).
void schedule_refresh() {
  if (g_state.backend == nullptr) return;
  if (g_state.debounce_id != 0) {
    g_source_remove(g_state.debounce_id);
  }
  g_state.debounce_id = g_timeout_add(300, on_debounce_fired, nullptr);
}

void on_sample_changed(GtkTextBuffer*, gpointer) {
  clear_highlights();
  schedule_refresh();
}

void on_pattern_changed(GtkEntryBuffer*, guint, guint, gpointer) {
  schedule_refresh();
}

void on_refresh_clicked(GtkButton*, gpointer) { start_refresh(); }

void on_pattern_activate(GtkEntry*, gpointer) { start_refresh(); }

// ---- startup ----------------------------------------------------------

struct StatusOutcome {
  bool ok{false};
  std::string error;
};

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
    g_state.set_status(kDanger, "Backend error: " + error);
    return G_SOURCE_REMOVE;
  }
  if (backend == nullptr) {
    g_state.set_status(kDanger, "Backend error: startup completed without a backend");
    return G_SOURCE_REMOVE;
  }

  g_state.backend = std::move(backend);
  g_state.api = std::make_unique<rivet_app::API>(*g_state.backend);

  g_state.set_status(kAccent, "Embedded Racket CS is ready");
  schedule_refresh();
  return G_SOURCE_REMOVE;
}

void start_backend() {
  auto layout = discover_runtime_layout();
  if (!layout.has_value()) {
    g_state.set_status(
        kDanger,
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

// ---- ui construction --------------------------------------------------

GtkWidget* make_caption(char const* text) {
  auto* caption = gtk_label_new(text);
  gtk_widget_add_css_class(caption, "caption");
  gtk_widget_set_halign(caption, GTK_ALIGN_START);
  return caption;
}

void on_activate(GtkApplication* app, gpointer) {
  if (g_state.window != nullptr) {
    gtk_window_present(g_state.window);
    return;
  }

  // Brand CSS once per display.
  auto* provider = gtk_css_provider_new();
  gtk_css_provider_load_from_data(provider, kCss, -1);
  gtk_style_context_add_provider_for_display(
      gdk_display_get_default(), GTK_STYLE_PROVIDER(provider),
      GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  g_object_unref(provider);

  auto* window = gtk_application_window_new(app);
  gtk_window_set_title(GTK_WINDOW(window), "RegexMate");
  gtk_window_set_default_size(GTK_WINDOW(window), 1160, 690);

  // Headerbar: the pattern field is the app's command surface.
  auto* header = gtk_header_bar_new();
  auto* title_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  auto* pattern = gtk_entry_new();
  gtk_entry_set_placeholder_text(GTK_ENTRY(pattern), "\\d+");
  gtk_editable_set_text(GTK_EDITABLE(pattern), "\\d+");
  gtk_editable_set_width_chars(GTK_EDITABLE(pattern), 44);
  gtk_widget_set_hexpand(pattern, TRUE);
  gtk_box_append(GTK_BOX(title_box), pattern);
  gtk_header_bar_set_title_widget(GTK_HEADER_BAR(header), title_box);
  auto* refresh = gtk_button_new_from_icon_name("view-refresh-symbolic");
  gtk_widget_set_tooltip_text(refresh, "Run (Enter also runs)");
  gtk_header_bar_pack_end(GTK_HEADER_BAR(header), refresh);
  gtk_window_set_titlebar(GTK_WINDOW(window), header);

  auto* root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  auto* columns = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 14);
  gtk_widget_set_vexpand(columns, TRUE);
  gtk_widget_set_margin_top(columns, 14);
  gtk_widget_set_margin_bottom(columns, 14);
  gtk_widget_set_margin_start(columns, 16);
  gtk_widget_set_margin_end(columns, 16);

  auto* left = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
  gtk_widget_set_hexpand(left, TRUE);
  auto* right = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
  gtk_widget_set_hexpand(right, TRUE);

  gtk_box_append(GTK_BOX(left), make_caption("TEST TEXT"));
  auto* sample = gtk_text_view_new();
  gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(sample), GTK_WRAP_WORD_CHAR);
  gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(sample)),
                           "Order 12345 shipped on 2026-09-28 to zip 10115.",
                           -1);
  gtk_widget_add_css_class(sample, "card");
  gtk_widget_add_css_class(sample, "pad");
  // Fixed-height card with internal scrolling for long samples.
  auto* sample_scroll = gtk_scrolled_window_new();
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(sample_scroll), sample);
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(sample_scroll),
                                 GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_widget_set_size_request(sample_scroll, -1, 170);
  gtk_box_append(GTK_BOX(left), sample_scroll);

  auto* matches_caption = make_caption("MATCHES");
  gtk_box_append(GTK_BOX(left), matches_caption);
  auto* matches_list = gtk_list_box_new();
  gtk_widget_add_css_class(matches_list, "card");
  gtk_widget_add_css_class(matches_list, "matchlist");
  gtk_widget_set_vexpand(matches_list, TRUE);
  auto* matches_scroll = gtk_scrolled_window_new();
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(matches_scroll),
                                matches_list);
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(matches_scroll),
                                 GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_widget_set_vexpand(matches_scroll, TRUE);
  gtk_box_append(GTK_BOX(left), matches_scroll);

  gtk_box_append(GTK_BOX(right), make_caption("EXPLANATION"));
  auto* explanation = gtk_label_new("—");
  gtk_widget_add_css_class(explanation, "card");
  gtk_widget_add_css_class(explanation, "pad");
  gtk_label_set_selectable(GTK_LABEL(explanation), TRUE);
  gtk_label_set_wrap(GTK_LABEL(explanation), TRUE);
  gtk_label_set_xalign(GTK_LABEL(explanation), 0.0);
  gtk_label_set_yalign(GTK_LABEL(explanation), 0.0);
  gtk_box_append(GTK_BOX(right), explanation);

  auto* lint_caption = make_caption("LINT FINDINGS");
  gtk_box_append(GTK_BOX(right), lint_caption);
  auto* lint = gtk_label_new("");
  gtk_widget_add_css_class(lint, "card");
  gtk_widget_add_css_class(lint, "pad");
  gtk_label_set_selectable(GTK_LABEL(lint), TRUE);
  gtk_label_set_wrap(GTK_LABEL(lint), TRUE);
  gtk_label_set_xalign(GTK_LABEL(lint), 0.0);
  gtk_label_set_yalign(GTK_LABEL(lint), 0.0);
  gtk_box_append(GTK_BOX(right), lint);

  gtk_box_append(GTK_BOX(right), make_caption("RAILROAD DIAGRAM"));
  auto* diagram = gtk_picture_new();
  gtk_widget_add_css_class(diagram, "card");
  gtk_widget_add_css_class(diagram, "pad");
  gtk_picture_set_can_shrink(GTK_PICTURE(diagram), TRUE);
  gtk_widget_set_size_request(diagram, -1, 210);
  gtk_box_append(GTK_BOX(right), diagram);

  auto* scroll_right = gtk_scrolled_window_new();
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll_right), right);
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll_right),
                                 GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_widget_set_vexpand(scroll_right, TRUE);

  gtk_box_append(GTK_BOX(columns), left);
  gtk_box_append(GTK_BOX(columns), scroll_right);
  gtk_box_append(GTK_BOX(root), columns);

  // Bottom status bar: dot, message, counts.
  auto* statusbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  gtk_widget_add_css_class(statusbar, "statusbar");
  auto* status_dot = gtk_label_new(nullptr);
  gtk_widget_add_css_class(status_dot, "statusdot");
  auto* status_text = gtk_label_new("Starting embedded Racket CS…");
  gtk_widget_set_hexpand(status_text, TRUE);
  gtk_widget_set_halign(status_text, GTK_ALIGN_START);
  gtk_label_set_ellipsize(GTK_LABEL(status_text), PANGO_ELLIPSIZE_END);
  auto* status_counts = gtk_label_new("0 matches  ·  0 findings");
  gtk_box_append(GTK_BOX(statusbar), status_dot);
  gtk_box_append(GTK_BOX(statusbar), status_text);
  gtk_box_append(GTK_BOX(statusbar), status_counts);
  gtk_box_append(GTK_BOX(root), statusbar);

  gtk_window_set_child(GTK_WINDOW(window), root);

  g_state.window = GTK_WINDOW(window);
  g_state.pattern = GTK_ENTRY(pattern);
  g_state.sample = GTK_TEXT_VIEW(sample);
  g_state.matches_caption = GTK_LABEL(matches_caption);
  g_state.matches_list = GTK_LIST_BOX(matches_list);
  g_state.explanation = GTK_LABEL(explanation);
  g_state.lint_caption = GTK_LABEL(lint_caption);
  g_state.lint = GTK_LABEL(lint);
  g_state.diagram = GTK_PICTURE(diagram);
  g_state.refresh = GTK_BUTTON(refresh);
  g_state.status_dot = GTK_LABEL(status_dot);
  g_state.status_text = GTK_LABEL(status_text);
  g_state.status_counts = GTK_LABEL(status_counts);

  // Accent-tinted highlight tag; alpha keeps it legible in light and dark.
  GdkRGBA tint = {0.01, 0.48, 0.33, 0.18};
  g_state.match_tag = gtk_text_buffer_create_tag(
      gtk_text_view_get_buffer(g_state.sample), "rm-match", nullptr);
  g_object_set(g_state.match_tag, "background-rgba", &tint, nullptr);

  g_signal_connect(refresh, "clicked", G_CALLBACK(on_refresh_clicked), nullptr);
  g_signal_connect(pattern, "activate", G_CALLBACK(on_pattern_activate),
                   nullptr);
  g_signal_connect(gtk_entry_get_buffer(GTK_ENTRY(pattern)), "changed",
                   G_CALLBACK(on_pattern_changed), nullptr);
  g_signal_connect(gtk_text_view_get_buffer(g_state.sample), "changed",
                   G_CALLBACK(on_sample_changed), nullptr);

  gtk_window_present(GTK_WINDOW(window));
  start_backend();
}

void on_shutdown(GApplication*, gpointer) {
  g_state.shutting_down.store(true, std::memory_order_release);
  if (g_state.debounce_id != 0) {
    g_source_remove(g_state.debounce_id);
    g_state.debounce_id = 0;
  }
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
                                  G_APPLICATION_FLAGS_NONE);
  g_signal_connect(app, "activate", G_CALLBACK(on_activate), nullptr);
  g_signal_connect(app, "shutdown", G_CALLBACK(on_shutdown), nullptr);
  int const status = g_application_run(G_APPLICATION(app), argc, argv);
  g_object_unref(app);
  return status;
}
