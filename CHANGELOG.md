# Changelog

All notable changes to RegexMate are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed
- Relicensed MIT → BUSL-1.1 (Change Date 2030-10-22). Use remains free for
  any purpose, including internal production use, CI pipelines and AI-agent
  invocation; what is not granted is distribution as a competing regex
  workbench or offering the Work as a hosted or commercial service. Each
  version converts to MIT four years after its first public distribution,
  whichever comes first; all versions up to and including 0.7.0 remain MIT.
- Windows icon redrawn full-bleed: a brand-green (#037A55) squircle with a
  white `.*` glyph (`branding/app-icon-windows.svg` → `app.ico`). The old
  `.ico` reused the macOS Big Sur inset-card artwork, which rendered as a
  shrunken near-invisible white tile in the taskbar and Explorer next to
  the family's full-bleed icons. The macOS `.icns` keeps the Apple-template
  artwork unchanged; the Linux desktop icon switches to the same full-bleed
  artwork (`linux-icon` → `branding/app-icon-linux-512.png`), matching the
  family's deb/rpm/AppImage convention.
- "Check for Updates…" moved into the App menu directly below About on
  macOS (was the File menu), per the family menu convention.

### Added
- Windows and Linux hosts gain the missing manual "Check for Updates…"
  entry as a Help menu (with About Regexmate beside it), wired to the
  backend's existing read-only update-check RPC; the macOS host already
  had it.

## [0.7.0] — 2026-10-15

### Added

- **Human installers on every platform** alongside the portable archives:
  `dmg` on macOS (arm64 and, new, Intel x64), `msi` on Windows, and
  `deb` / `rpm` / `AppImage` on Linux (x64 and, new, arm64) — all built by
  `raco rivet release` with a launch smoke, an SBOM and third-party notices
  per leg. The portable CLI+GUI archives keep their exact layout and stay
  the self-update payload; the Windows standalone exe is unchanged.
- **Feedback entrance**: `.github/ISSUE_TEMPLATE` bug/feature templates
  with a docs contact link.
- **Check for Updates in the GUI** (macOS pilot): a read-only app-menu item
  (⇧⌘U) backed by the new `update-check` backend RPC, which walks the same
  verified-manifest path as `regexmate update --check` and reports
  up-to-date / available <version> / offline <reason>. Applying an update
  remains the CLI's job — the GUI never mutates its own bundle. The RPC is
  generated into all three hosts; wiring the Windows/Linux UIs is left for
  real-machine acceptance passes.

### Changed

- `scripts/check-version.rkt` is the single release gate: VERSION,
  info.rkt, version.rkt, rivet.rktd and the README badges (en/zh) must
  state one version — the badge shipped stale on 0.6.3 because nothing
  checked it.
- `rivet-schema.json` is committed as the backend-contract baseline and
  gated in CI with `raco rivet schema check`.
- Removed `packaging/aur`: distribution is GitHub Releases only.


## [0.6.3] — 2026-10-14

The `update-stable.json` byte-level alias retires: there is no pre-0.6.1
installed base to keep self-updating, so releases publish the signed
`update-manifest.json` only (the versionless installer download aliases
are unaffected).

## [0.6.2] — 2026-10-14

Engineering alignment with the family benchmark (taskly). No CLI behavior
changes.

### Added

- **User manual** at `docs/guide.html` (live on the site under 手册 /
  Manual): a five-minute start, one section per command with real output
  produced by the binary, the MCP server setup, the versioned JSON
  contract and an FAQ (platform coverage, MCP config, updating,
  uninstalling) — bilingual via the same `data-i18n` dictionary mechanism
  as the homepage, linked from the site nav and both READMEs

### Changed

- **The signing tools and the engine share one pin**: CI and release
  workflows install Rivet from `rivet.git#v0.11.0` instead of floating on
  the package catalog, the release signing leg checks out the same
  `v0.11.0` ref before linking the manifest signer, and
  `setup-embed-racket` runs at the tagged ref — the tool versions that
  sign and build a release can no longer drift
- **Host packages consume the Rivet platform as a package target**: the
  Linux host links `rivet::platform` via `add_subdirectory` and the
  Windows host references `rivet-host.vcxproj` via `ProjectReference`,
  replacing hand-copied Rivet translation units — rivet adding a source
  file no longer needs a downstream change
- **The Linux release leg rides rivet's own tooling end to end**: it
  builds on `ubuntu-latest` (the rivet platform configures with
  `gtk4>=4.10`), switches to the embeddable runtime through rivet's
  pinned `setup-embed-racket` action and keeps the Rivet install
  idempotent across the two Racket installations
- The site drops the version pill (the homepage no longer states a
  version), aligns the palette with the family values, upgrades dark mode
  to the full scheme (manual toggle with `localStorage` persistence and a
  no-flash inline head script) and defaults to Chinese with the shared
  `data-i18n` dictionary pattern
- A `VERSION` file now sits at the repository root, matching the family
  convention

## [0.6.1] — 2026-10-11

Naming and feed alignment with the family packaging benchmark (taskly).
No behavior changes beyond the manifest location.

### Changed

- Release assets rename to the family scheme `regexmate-<version>-<os>-<arch>.<ext>`
  (`regexmate-0.6.1-linux-x86_64.tar.gz`, `regexmate-0.6.1-macos-arm64.tar.gz`,
  `regexmate-0.6.1-windows-x86_64.zip`, plus
  `regexmate-0.6.1-windows-x86_64-standalone.exe`) — the version moves out
  of the middle of the file name and the macOS arch follows the family
  spelling
- The signed update feed publishes as `update-manifest.json` (family
  convention); a byte-identical `update-stable.json` alias keeps pre-0.6.1
  builds self-updating until the field has moved on

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
