#!/bin/bash
# RegexMate CLI smoke test — run from repo root
set -u
R="racket main.rkt"
PASS=0; FAIL=0

check() { # desc expected_exit actual_exit
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 (expected exit $2, got $3)"; fi
}

# validate
$R validate '^\d+$' >/dev/null; check "validate ok" 0 $?
$R validate '(' >/dev/null; check "validate invalid" 1 $?
$R validate '^\d+$' --json >/dev/null; check "validate json ok" 0 $?

# match
$R match '\d+' 'abc 123' >/dev/null; check "match found" 0 $?
$R match 'zzz' 'abc 123' >/dev/null; check "match none" 3 $?
$R match '(' 'abc' >/dev/null; check "match invalid" 1 $?
$R match '\d+' 'abc 123' --json >/dev/null; check "match json" 0 $?
echo "piped text" | $R match 'text' - >/dev/null; check "match stdin" 0 $?

# explain
$R explain '\d+' >/dev/null; check "explain" 0 $?
$R explain '\d+' --lang zh >/dev/null; check "explain zh" 0 $?
$R explain '\d+' --json >/dev/null; check "explain json" 0 $?

# replace
$R replace 'a+' 'x' 'baaad' >/dev/null; check "replace" 0 $?
$R replace 'zz' 'x' 'baaad' >/dev/null; check "replace none" 3 $?
$R replace 'a+' 'x' 'baaad' --json >/dev/null; check "replace json" 0 $?

# graph
$R graph 'a(b|c)*' -o /tmp/smoke.svg >/dev/null; check "graph file" 0 $?
test -s /tmp/smoke.svg; check "graph file exists" 0 $?
$R graph 'a(b|c)*' --json >/dev/null; check "graph json" 0 $?
$R graph 'a(b|c)*' >/dev/null; check "graph stdout" 0 $?

# schema
$R schema >/dev/null; check "schema" 0 $?
$R schema --json >/dev/null; check "schema json" 0 $?

# lint
$R lint '(a+)+' --json >/dev/null; check "lint findings" 0 $?
$R lint '^[a-z]+$' >/dev/null; check "lint clean" 0 $?
$R lint '^[a-z]+$' --strict >/dev/null; check "lint strict clean" 0 $?
$R lint '(a+)+' --strict >/dev/null; check "lint strict findings" 3 $?
$R lint '(' >/dev/null; check "lint invalid" 1 $?

# test
printf '{"cases":[{"text":"a1","expect":"match"}]}' | $R test '\d' >/dev/null; check "test pass" 0 $?
printf '{"cases":[{"text":"abc","expect":"match"}]}' | $R test '\d' >/dev/null; check "test fail" 3 $?
printf '[{"text":"a1"}]' | $R test '\d' --json >/dev/null; check "test bare array json" 0 $?
printf 'not json' | $R test '\d' >/dev/null; check "test bad input" 2 $?
$R test '(' >/dev/null; check "test invalid pattern" 1 $?

# mcp (stdio JSON-RPC)
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"regexmate_match","arguments":{"pattern":"[0-9]+","text":"a1"}}}' \
  > /tmp/mcp-smoke-in.jsonl
$R mcp < /tmp/mcp-smoke-in.jsonl > /tmp/mcp-smoke.out 2>/dev/null; check "mcp server runs" 0 $?
grep -q '"serverInfo"' /tmp/mcp-smoke.out; check "mcp initialize" 0 $?
grep -q 'regexmate_validate' /tmp/mcp-smoke.out; check "mcp tools/list" 0 $?
grep -q '"isError":false' /tmp/mcp-smoke.out; check "mcp tools/call" 0 $?
# notification produced no response line
test "$(wc -l < /tmp/mcp-smoke.out)" -eq 3; check "mcp notification silent" 0 $?

# update (source mode refuses, exit 2)
$R update --check >/dev/null 2>&1; check "update check from source" 2 $?
$R update --check --json >/dev/null 2>&1; check "update json from source" 2 $?
$R update now >/dev/null 2>&1; check "update extra args" 2 $?
$R schema >/dev/null 2>&1 && $R schema | grep -q '"update"'; check "schema lists update" 0 $?

# misc
$R --version >/dev/null; check "version" 0 $?
$R --version --json >/dev/null; check "version json" 0 $?
$R --help >/dev/null; check "help" 0 $?
$R >/dev/null; check "no args" 2 $?
$R bogus 'x' >/dev/null; check "unknown command" 2 $?
$R match '\d+' --json --bogus >/dev/null 2>&1; check "unknown flag" 2 $?
$R validate '\d+' --lang fr >/dev/null 2>&1; check "bad lang" 2 $?

echo "SMOKE: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
