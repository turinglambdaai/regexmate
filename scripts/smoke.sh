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
