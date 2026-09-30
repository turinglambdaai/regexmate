# Changelog

All notable changes to RegexMate are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
