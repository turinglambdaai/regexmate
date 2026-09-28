# RegexMate

The regex workbench for the agent era — validate, match, explain, replace, graph, batch-test and lint regular expressions from a single cross-platform CLI, over a versioned JSON contract, an MCP server and exit codes that never lie.

![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

**English** · [中文](README.zh-CN.md)

## Why

Regex tooling today is either web-only (regex101), search-oriented (ripgrep) or silent (grep). RegexMate is a small, honest CLI that does four things well and speaks JSON natively:

- **validate** — check a pattern against the Racket `pregexp` flavor, single-line error messages
- **match** — run a pattern against text or stdin; highlighted in a terminal, structured over a pipe
- **explain** — narrate every part of a pattern in plain English or 中文
- **replace** — substitute with backreferences, with a replacement count
- **graph** — render a railroad diagram as SVG, for specs and pull requests
- **test** — assert a pattern against JSON cases and get per-case evidence: the write → test → refine loop agents need
- **lint** — deterministic static findings (catastrophic-backtracking nesting, quantified assertions, empty/duplicate/shadowed alternation branches), `--strict` gates CI
- **mcp** — a stdio MCP server exposing all seven tools natively to coding agents
- **schema** — the machine-readable contract, described by the tool itself

Everything ships as a standalone binary — no Racket installation required on target machines. A [`SKILL.md`](SKILL.md) ships in the repository for agent platforms that load skill cards.

## Install

**Standalone binary** (Windows / Linux / macOS): grab an archive from [Releases](https://github.com/turinglambdaai/regexmate/releases), unzip, run.

**Racket package:**

```bash
raco pkg install https://github.com/turinglambdaai/regexmate.git
```

**From source** (Racket 9.x):

```bash
git clone https://github.com/turinglambdaai/regexmate
cd regexmate
raco make main.rkt
racket run-tests.rkt          # test suite
raco exe -o regexmate main.rkt  # produce your own binary
```

## Quick start

```console
$ regexmate validate '^\d{3}-\d{4}$'
Pattern: ^\d{3}-\d{4}$
✓ Valid syntax

$ regexmate match '\d+' 'abc 123 def 456'
Found 2 match(es):
  at 4-7: "123"
  at 12-15: "456"

$ regexmate explain '(?:\d{2,4}|[a-z]+)(?=x)'
Pattern: (?:\d{2,4}|[a-z]+)(?=x)

Components:
  1. [group] (?:\d{2,4}|[a-z]+)
       ← Non-capturing group (?:...): Digit (\d) × {2,4} | Character class: [a-z] × +
  2. [lookaround] (?=x)
       ← Positive lookahead (?=...): Literal: x

$ regexmate replace '(\w+)@(\w+)' '\1 AT \2' 'mail a@b'
Replaced 1 occurrence(s).
Result: mail a AT b

$ regexmate graph 'ab(c|d)*' -o diagram.svg
SVG saved to: diagram.svg
```

## Self-update

```console
$ regexmate update --check
Latest release: v1.2.0 (installed: 1.1.0)

$ regexmate update
Downloading regexmate-windows-x86_64-v1.2.0.zip …
Verifying checksum…
Installing …
Updated to v1.2.0. Run `regexmate --version` to confirm.
```

Standalone installs update themselves in place from GitHub Releases: the download's SHA-256 is verified against the published checksum, and the running binary is swapped safely (renamed aside, cleaned up on next start). `--json` emits the standard envelope for agents and scripts. Source and `raco pkg` installs are pointed at `git pull` / `raco pkg update` instead.

## MCP server

```json
{
  "mcpServers": {
    "regexmate": {
      "command": "regexmate",
      "args": ["mcp"]
    }
  }
}
```

Newline-delimited JSON-RPC 2.0 over stdio, protocol `2024-11-05`. Tools: `regexmate_validate`, `regexmate_match`, `regexmate_explain`, `regexmate_replace`, `regexmate_graph`, `regexmate_test`, `regexmate_lint` — each with an input schema discoverable via `tools/list`.

## Agent workflow

```console
$ printf '{"cases":[{"text":"2026-09-28","expect":"match","contains":"2026"},{"text":"2026-13-01","expect":"no-match"}]}' | regexmate test '\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])'
  ✓ "2026-09-28"
  ✓ "2026-13-01"
Passed 2 of 2 case(s).

$ regexmate lint '(a+)+|a|'
2 finding(s):
  [warning] nested-quantifier at 0: nested quantifiers over a group can backtrack catastrophically on non-matching input
  [warning] empty-branch at 8: alternative 2 is empty — it matches the empty string, usually a bug

$ regexmate schema --json   # the contract, from the tool itself
```

## JSON contract (`regexmate/v1`)

Every command accepts `--json` and emits a single-line envelope with stable keys: `schema`, `command`, `ok`.

```console
$ regexmate match '(\w+)@(\w+)' 'mail a@b' --json
{"command":"match","count":1,"matches":[{"end":8,"groups":[{"end":6,"index":1,"name":null,"start":5,"value":"a"},{"end":8,"index":2,"name":null,"start":7,"value":"b"}],"start":5,"value":"a@b"}],"ok":true,"pattern":"(\\w+)@(\\w+)","schema":"regexmate/v1","text":"mail a@b"}
```

Contract rules:

- Spans are absolute indices, `[start, end)` — end exclusive.
- Capture groups are 1-based; `name` is reserved for future named-group support; absent groups are `null`, never missing keys.
- Errors carry a single-line `error` string (no embedded newlines).
- `graph --json` embeds the SVG markup; `graph -o FILE --json` reports `output` and `bytes`.

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | ok — match found / pattern valid / replacements done |
| `1` | invalid regular expression |
| `2` | usage error (unknown command or flag) |
| `3` | valid pattern, zero matches / zero replacements |

## Regex flavor

RegexMate validates and matches with Racket's `pregexp` engine. Supported: `. ^ $ * + ? {n,m}` (greedy and lazy), `( ) (?: )`, lookarounds `(?=) (?!) (?<=) (?<!)`, atomic groups `(?>)`, flag groups `(?i:…) (?is:…) (?-i:…)`, character classes with ranges / negation / POSIX names (`[:alpha:]`), escapes `\d \D \w \W \s \S \b \B`, backreferences `\1`–`\9`, and unicode classes `\p{…}` / `\P{…}`.

Not supported by the engine (and therefore rejected by `validate`): named groups `(?<name>…)`, `\A`/`\z` anchors, `\x41` hex escapes. `explain` and `graph` degrade gracefully on valid-but-unmodelable syntax.

## Localization

Human output is English by default. `--lang zh` or the `REGEXMATE_LANG=zh` environment variable switches every message, including `explain` descriptions. `NO_COLOR` disables ANSI highlighting.

## Development


```bash
racket run-tests.rkt      # unit tests
bash scripts/smoke.sh     # CLI end-to-end smoke test
racket scripts/check-version.rkt v1.0.0   # release gate
```

CI runs the unit tests and smoke test on Ubuntu, Windows and macOS against Racket 9.2; tagged pushes build standalone binaries for all three platforms and publish a GitHub release with SHA-256 checksums.

## Project structure

```
regexmate/
├── main.rkt                 # CLI entry point
├── version.rkt              # runtime version (must match info.rkt)
├── info.rkt                 # Racket package metadata
├── core/
│   ├── ast.rkt              # regex AST data structures
│   ├── regex-parser.rkt     # recursive-descent parser (pregexp-aligned)
│   ├── regex-engine.rkt     # matching / replacing on pregexp
│   └── i18n.rkt             # en/zh message tables
├── output/
│   ├── json-format.rkt      # regexmate/v1 envelopes
│   ├── human-format.rkt     # bilingual human output + explainer
│   ├── highlight.rkt        # ANSI match highlighting
│   └── railroad.rkt         # AST → pict → SVG diagrams
├── tests/                   # rackunit suites
├── scripts/                 # smoke.sh, check-version.rkt
├── docs/                    # product homepage (GitHub Pages)
└── .github/workflows/       # ci.yml, release.yml
```

## Roadmap

- Desktop GUI on the same core (diagrams, live match table, explain pane)
- MCP server exposing the regex tools as native agent tools
- Flavor linting (catastrophic backtracking warnings, portability checks)
- Package-manager distribution (Homebrew, winget, AUR)

## License

[MIT](LICENSE)
