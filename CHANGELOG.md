# Changelog

All notable changes to RegexMate are documented here. Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is SemVer.

## [1.2.0] — 2026-09-28

Self-update: `regexmate update` brings standalone installs to the latest GitHub release without any package manager.

### Added

- **`update` command**: checks the latest GitHub release, downloads the platform archive, verifies its SHA-256 against the published checksum, extracts and swaps the install in place. `--check` reports without installing; `--json` emits the standard envelope (`current`, `latest`, `updateAvailable`, `action`). Non-interactive by default — built for agents and scripts.
- Swap safety on all three platforms: the running binary is renamed aside (works even on Windows while the process is live), stale `.old` runtime files are cleaned on the next startup.
- Checksums are enforced: a mismatched download aborts the update before anything is touched.
- Pure-Racket SHA-256 (verified against FIPS 180-4 test vectors including padding boundaries) — no new dependencies.

### Notes

- Update requires a standalone binary install; source/pkg installs are pointed at `git pull` / `raco pkg update`.
- `schema` now lists the `update` command.

## [1.1.0] — 2026-09-28

The agent-era release: MCP server, batch testing with evidence, static risk analysis and a self-describing contract.

### Added

- **MCP server** (`regexmate mcp`): stdio JSON-RPC 2.0, newline-delimited — exposes `regexmate_validate`, `regexmate_match`, `regexmate_explain`, `regexmate_replace`, `regexmate_graph`, `regexmate_test` and `regexmate_lint` as agent tools with input schemas. UTF-8 forced on both directions; notifications never produce output.
- **`test` command**: assert a pattern against JSON cases (`text` / `expect: match|no-match` / `contains`) and get per-case evidence with reasons. Exit 0 all pass, 3 failures, 1 invalid regex.
- **`lint` command**: deterministic static findings — `nested-quantifier` (catastrophic backtracking risk), `quantified-assertion`, `empty-branch`, `duplicate-branch`, `shadowed-branch` — each with rule id, approximate position, severity and message. `--strict` turns findings into exit code 3 for CI gating.
- **`schema` command**: machine-readable description of every command, flag, exit code and MCP tool — the contract describes itself.
- **`SKILL.md`**: agent skill card for platforms that load repository skills.

### Changed

- `--help` now lists nine commands; usage text is bilingual.
- 49 unit tests and 42 smoke checks, including an end-to-end MCP session test.

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
