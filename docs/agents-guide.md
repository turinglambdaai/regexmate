# Agent workflow guide

How a coding agent (Claude Code, Codex, Cursor, …

) uses RegexMate to produce regexes it can stand behind. The loop is always the same: **write → validate → test → lint → ship**.

## Setup

Either install the binary once:

```bash
# grab the single-file exe (Windows) or the tarball (macOS) from GitHub Releases
```

…or connect the MCP server so the tools appear natively:

```json
{
  "mcpServers": {
    "regexmate": { "command": "regexmate", "args": ["mcp"] }
  }
}
```

MCP tools: `regexmate_validate`, `regexmate_match`, `regexmate_explain`, `regexmate_replace`, `regexmate_graph`, `regexmate_test`, `regexmate_lint`, `regexmate_cookbook`.

## The loop

### 1. Write, then validate — invalid patterns return a repair `hint` in the JSON; read it before retrying

```bash
regexmate validate '^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$'
```

Exit code 0 = valid, 1 = invalid with a single-line error. Never hand a pattern to the user before this passes.

### 2. Test against cases

Write the assertions as JSON — positives, negatives and content checks:

```bash
regexmate test '^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$' <<'EOF'
{"cases":[
  {"text":"2026-09-30","expect":"match","contains":"2026"},
  {"text":"2026-13-01","expect":"no-match"},
  {"text":"2026-9-30","expect":"no-match"},
  {"text":"","expect":"no-match"}
]}
EOF
```

Exit 0 = every case passed. Exit 3 = at least one failed; read `results[].reason` for the evidence. Exit 1 = the regex itself is broken.

### 3. Lint before shipping

```bash
regexmate lint '(a+)+|a|' --strict
```

Findings you may see:

| Rule | Meaning |
|------|---------|
| `nested-quantifier` | nested unbounded quantifiers — catastrophic backtracking (ReDoS) risk |
| `quantified-assertion` | a quantifier over a lookaround/anchor has no effect or hides a bug |
| `empty-branch` | an empty alternative matches everything — usually a bug |
| `duplicate-branch` | the same alternative appears twice |
| `shadowed-branch` | an earlier alternative always wins, so a later one is unreachable — reorder |
| `portability` | the construct will not behave the same outside Racket (atomic groups, scoped flags, POSIX/unicode classes, backreferences) |
| `redundant-atomic` | an atomic group over a single element does nothing |

`--strict` turns any finding into exit code 3, so a CI job can gate on it.

### 4. Ship — and prove it

Everything the tool prints in `--json` mode carries `schema`, `command` and `ok`. Capture the `test` output as the evidence artifact for your change; run `regexmate graph '<pattern>' -o diagram.svg` and attach the diagram to the pull request.

## Worked example: extracting versions from changelog lines

```bash
$ regexmate match '^\[v(\d+\.\d+\.\d+)\] - (\d{4}-\d{2}-\d{2})' --json <<'EOF'
[v1.2.0] — 2026-09-30 fixed the parser
[v1.1.0] — 2026-09-28 added the MCP server
EOF
{"command":"match","count":2,…}

$ regexmate replace '^\[v(\d+\.\d+\.\d+)\] - (\d{4}-\d{2}-\d{2})' '- version \1 (released \2)' <<'EOF'
[v1.2.0] — 2026-09-30 fixed the parser
EOF
- version 1.2.0 (released 2026-09-30)
```

## Contract notes

- Envelopes carry `schema: "regexmate/v1"`, `command`, `ok`.
- Spans are absolute `[start, end)`; capture groups are 1-based and `null` when absent.
- `regexmate schema` prints the whole contract for programmatic discovery.

## Regex flavor

Racket `pregexp`: lookarounds `(?=) (?!) (?<=) (?<!)`, atomic groups `(?>)`, flag groups `(?i:…)`, POSIX classes `[:alpha:]`, unicode classes `\p{…}`, backreferences `\1`–`\9`. No named groups `(?<name>…)`, no `\A`/`\z`, no `\x41` — `validate` rejects those up front, and `lint` flags portability-sensitive constructs.
