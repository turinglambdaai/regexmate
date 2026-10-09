# Changelog

All notable changes to RegexMate are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.6.0] — 2026-10-09

The trust release: online updates now verify a signature before they touch
your install.

### Added

- **Ed25519-verified online updates**: `regexmate update` and
  `regexmate update --check` now read an Ed25519-signed channel manifest
  (`update-stable.json`, published alongside every release) instead of
  probing the GitHub API. The signature is checked against the public key
  embedded in the binary (key id `regexmate-2026-10`) before anything else,
  then the download's byte size and SHA-256 are checked against that same
  signed manifest — a compromised mirror can no longer serve a tampered
  archive. Release CI signs one merged manifest covering exactly the
  shipped artifacts: the Linux and macOS archives, the Windows archive and
  the Windows standalone exe.

### Changed

- **Updates cover the whole install**: the CLI, its runtime and the bundled
  GUI are all swapped in place (renamed aside; leftovers cleaned on next
  start). The GUI is refreshed by the same update — restart the app
  afterwards. Standalone single-file Windows installs update to the
  standalone exe artifact.
- **Update flow is one request**: the check fetches a single signed
  manifest instead of hitting the rate-limited GitHub releases API —
  friendlier for agents and CI that run `regexmate update --check` often.

## [0.5.0] — 2026-10-08

The learning release: regex is a skill, and the workbench now teaches it.

### Added

- **`cookbook` command**: a built-in library of 23 commented starter
  patterns across 7 topics (contact, date-time, web, numbers, text, code,
  log) — every recipe carries the pattern, a sample it demonstrably
  matches, per-segment teaching notes and variants. `regexmate cookbook`
  lists; `regexmate cookbook email` (or a topic like `web`) prints full
  detail in English or 中文; `--json` emits the structured envelope.
- **Repair hints on invalid patterns**: `validate '[unclosed'` now says how
  to fix it ("a character class opens with [ and must close with ] — e.g.
  [a-z0-9]"), in human output and as an optional `hint` field on the JSON
  error envelope (additive, contract stays v1). Agents self-correct instead
  of trial-and-error.
- **MCP tool `regexmate_cookbook`**: agents can pull verified, annotated
  patterns and pass the teaching along — listing, ids and topics all work
  over tools/call. `regexmate_validate` responses now include the repair
  hint.
- **Shell completions and `schema` list the new command.**

### Fixed

- **Lint findings are fully localized**: under `--lang zh` the finding
  sentences themselves were still English; every rule now renders from
  bilingual templates (nested quantifiers, empty/shadowed branches,
  portability notes and friends).

## [0.4.0] — 2026-10-02

The desktop app ships on every platform, and the railroad diagram grows real
geometry.

### Added

- **macOS desktop GUI** (SwiftUI host, same embedded Racket core): toolbar
  pattern bar with live refresh as you type, match pills highlighted inside
  the sample text, a match list with spans and group counts (click a row to
  select the range in the sample), plain-language explanation, lint findings
  with severity chips, and the railroad diagram. ⌘R re-runs; the toolbar
  share button exports the self-contained HTML report. Ships in the macOS
  archive as `regexmate-gui.app`.
- **Linux desktop GUI redesigned** (GTK4): the pattern field moves into the
  headerbar with the same 300 ms live refresh, matches are highlighted inside
  the sample text (alpha-tinted so both Adwaita themes read right), matches
  render as a real list with spans and group counts, severity-colored lint
  findings, and a bottom status bar with dot and counts — styled with theme
  symbolic colors, no hard-coded neutrals.
- **App icon** on macOS and Windows: a mono `/…/` literal on an accent pill
  in the RegexMate palette (Big Sur squircle, Windows .ico from one source
  SVG in `branding/`).
- **Railroad diagram geometry**: quantifiers render as a proper loop over the
  element — the flow line runs straight through the node's center and the
  quantifier label sits in the loop line; alternations get fork rails with
  connector stubs; every diagram carries entry/exit tracks. Node palette
  follows the RegexMate brand (green escapes, blue classes, amber anchors,
  accent group frames) instead of ad-hoc pastels. Applies to the GUI PNG, the
  HTML report and the CLI `graph` SVG on all platforms.
- Adaptive diagram resolution: the PNG render density scales with the
  pattern's size (capped), so the in-app diagram stays sharp.

### Fixed

- The macOS GUI host compiles and launches again: it now calls the generated
  snake_case RPC surface (`match_rows`, `lint_rows`, …) and pins the Rivet
  runtime working directory so the packaged app resolves its staged foreign
  libraries (libpng et al).
- `railroad-svg` (library API) destructured `parse-regex-safe`'s result
  incorrectly and always errored; the CLI `graph` path was unaffected.

## [0.3.0] — 2026-09-30

The report era: HTML evidence reports, shell completions and the lint panel in the desktop app.

### Added

- **`report` command**: one HTML file with everything — pattern, matches, highlighted sample, plain-language explanation, lint findings, test results and the railroad diagram. Feed it stdin, a text file and an optional `--cases` JSON; write with `-o`. Zero network, evidence for PRs and CI.
- **`completions` command**: shell completion scripts for bash, zsh and PowerShell.
- **Desktop lint panel** (Windows GUI): findings render with severity, rule, position and message alongside matches and explanation.
- **Linux desktop GUI**: the same four-pane app on GTK4, distributed in the Linux archive.
- Report and lint RPCs are also available over the MCP bridge.

## [0.2.1] — 2026-09-30

### Added

- **Single-file Windows CLI** (`regexmate-standalone-windows-x86_64-*.exe`): the whole CLI — including railroad-diagram rendering — embedded in one executable. This is also the winget/scoop-friendly artifact.

## [0.2.0] — 2026-09-30

The workbench tightens: live feedback inside the desktop app.

### Added

- **Live refresh** — pattern and test text re-evaluate as you type (300 ms debounce); the Refresh button and Enter remain for explicit runs.
- **Match highlighting** — matches are bolded and tinted inside the test text itself, so the sample reads like a test report.

### Fixed

- Diagram decoding no longer deadlocks the UI thread (the async completion was blocked by its own `.get()`), and the image stream is rewound before decoding — the railroad diagram now displays reliably.

## [0.1.0] — 2026-09-30

Initial release of the rebuilt RegexMate: an agent-era regex workbench with a
native desktop app on Windows.

### CLI (Windows, Linux, macOS)

- `validate`, `match`, `explain`, `replace`, `graph`, `test`, `lint` — seven
  verbs over one versioned JSON contract (`regexmate/v1`).
- `schema` — the contract describes itself for agent discovery; `update` —
  online self-update with SHA-256 verification; `mcp` — stdio MCP server
  exposing seven tools to coding agents.
- Typed RPC surface, explicit exit codes (0/1/2/3), stdin input, bilingual
  human output (`--lang en|zh`), `NO_COLOR`.
- Regex coverage aligned with Racket's pregexp: lookarounds, atomic groups,
  flag groups, POSIX and unicode classes, backreferences; lint covers
  catastrophic backtracking, dead branches and cross-engine portability.

### Desktop GUI (Windows)

- Native WinUI 3 application built with [Rivet](https://github.com/turinglambdaai/rivet):
  pattern field, test text, match table with absolute spans, plain-language
  explanation and a live railroad diagram — the same Racket core as the CLI,
  embedded in the app process. No WebView, no Electron.
- macOS and Linux GUI hosts are planned; the CLI covers those platforms today.

### Engineering

- 59 unit tests, 46 CLI smoke checks, three-platform CI.
- Release archives: CLI for all platforms; the Windows archive additionally
  contains the native GUI. SHA-256 checksums published per artifact.
