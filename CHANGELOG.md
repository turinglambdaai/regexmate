# Changelog

All notable changes to RegexMate are documented here. Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is SemVer.

## [1.0.0] — 2026-09-28

First productized release: agent-first regex CLI with a stable JSON contract, standalone binaries and a product homepage.

### Added

- `replace` command with backreference substitution and replacement count.
- `match` JSON output now includes per-match capture groups: `index`, `name`, `value`, `start`, `end`; absent groups are `null`.
- Versioned JSON contract: every envelope carries `schema: "regexmate/v1"`, `command` and `ok`; single-line error strings.
- Explicit exit codes: 0 ok · 1 invalid regex · 2 usage error · 3 valid pattern, zero matches/replacements.
- Bilingual human output (`--lang en|zh`, `REGEXMATE_LANG`): every message including `explain` descriptions.
- Parser support for lookarounds `(?=) (?!) (?<=) (?<!)`, atomic groups `(?>)`, flag groups `(?i:…)`, backreferences `\1`–`\9`, POSIX classes `[:alpha:]`, `\d`-family inside character classes, and unicode classes `\p{…}` / `\P{…}`.
- `--version`, `--help`, `-` stdin input for `match`/`replace`, `NO_COLOR` support.
- Standalone binary builds for Windows, Linux and macOS via GitHub Actions, with SHA-256 checksums.
- Product homepage under `docs/` with real tool-generated railroad diagrams.

### Changed

- Clean node type names in JSON output (`literal`, `quantifier`, `group`, `lookaround`, … instead of internal `re-*` names).
- Compile errors are cleaned to a single friendly line (no `pregexp:` prefix, no embedded newlines).
- Repackaged as an installable Racket package (`info.rkt`, collection `regexmate`).

### Fixed

- Character-class items with symbolic escapes (`[\d-]`) no longer confuse the explain/visualizer formatters.
- Empty matches no longer stall the match scan.
