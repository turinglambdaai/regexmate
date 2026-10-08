---
name: regexmate
description: Validate, test, lint, explain, replace and graph regular expressions via CLI or MCP — use whenever creating, reviewing, debugging or modifying any regex.
---

# RegexMate

Agent-first regex workbench. Install as a standalone binary (see https://regexmate.jrtx.site/), via `raco pkg install https://github.com/turinglambdaai/regexmate.git`, or connect the MCP server (`regexmate mcp`, stdio transport).

## When to use

- You wrote or are about to write a regex → **test** it against samples and **lint** it before shipping.
- You inherited a regex you don't understand → **explain** it.
- You need matches with positions/groups from a shell script or tool call → **match** (`--json`).
- You need to document a pattern → **graph** it as SVG.
- You need a starting point for a common need (email, date, URL, password…) → **cookbook**: `regexmate cookbook` lists commented, test-verified starter patterns; `regexmate cookbook <id>` prints per-segment teaching notes — pass them to the user.

## Core workflow (always do this for non-trivial patterns)

1. `regexmate validate '<pattern>'` — syntax check first. Invalid patterns return a `hint` field in JSON with the fix — read it before retrying.
2. `regexmate test '<pattern>'` with JSON cases on stdin — assert both positives and negatives:
   ```json
   {"cases":[
     {"text":"2026-09-28","expect":"match","contains":"2026"},
     {"text":"2026-13-01","expect":"no-match"}
   ]}
   ```
   Exit 0 = all pass, 3 = failures (read `results[].reason`), 1 = invalid regex.
3. `regexmate lint '<pattern>'` — fix findings before shipping: `nested-quantifier` (ReDoS risk), `quantified-assertion`, `empty-branch`, `duplicate-branch`, `shadowed-branch` (an earlier alternative makes a later one unreachable — reorder).
4. Only then hand the pattern to the user.

## Command cheat sheet

```bash
regexmate match '(\w+)@(\w+)' 'mail a@b' --json   # spans + groups
cat file.txt | regexmate match 'ERROR \d+' -      # stdin input
regexmate replace '(\w+)@(\w+)' '\1 at \2' 'a@b'  # \1 group refs
regexmate explain '(?:\d{2,4}|[a-z]+)(?=x)'       # plain-language breakdown
regexmate graph 'ab(c|d)*' -o diagram.svg         # railroad SVG
regexmate schema                                  # machine-readable contract
```

## Contract notes

- Every JSON envelope carries `schema: "regexmate/v1"`, `command`, `ok`.
- Spans are absolute `[start, end)`; capture groups are 1-based, `null` when absent.
- Exit codes: `0` ok · `1` invalid regex · `2` usage · `3` valid pattern, zero matches/replacements or failing cases (lint `--strict`).

## Regex flavor

Racket `pregexp`: lookarounds `(?=) (?!) (?<=) (?<!)`, atomic `(?>)`, flag groups `(?i:)`, POSIX classes `[:alpha:]`, `\p{…}`. **No** named groups `(?<name>)`, no `\A`/`\z`, no `\x41` — `validate` rejects those.
