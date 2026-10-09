#!/bin/bash
# Run the repository's CPU tests: tools/test_*.py, tools/test_*.js and, given a built 1401.app,
# tools/test_optional_diagnostics.sh. macOS only: the tests call xcrun, swiftc, kmutil, diskutil, plutil and ditto.
# They need neither a GPU nor an installed driver.
#
#   tools/run_tests.sh [path/to/1401.app]          logs: out/tests/<test>.log
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd); cd "$REPO" || exit 2
APP=${1:-}; LOGS=$REPO/out/tests; mkdir -p "$LOGS"
pass=0; fail=0; failed=""
run() {   # run <name> <command...>
  local name=$1 log; shift; log=$LOGS/$name.log
  if "$@" >"$log" 2>&1; then pass=$((pass+1)); echo "ok    $name"
  else fail=$((fail+1)); failed="$failed $name"; echo "FAIL  $name"; tail -20 "$log" | sed 's/^/      /'; fi
}
for t in tools/test_*.py; do
  name=$(basename "$t" .py)
  case $name in
    test_diagnostics_prerequisites)   # takes the built preflight checker; nothing to check without the app
      if [ -n "$APP" ]; then run "$name" python3 -I "$t" "$APP/Contents/Resources/nullmoth-diagnostics-preflight"
      else echo "skip  $name (pass the built 1401.app to run it)"; fi;;
    *) run "$name" python3 -I "$t";;
  esac
done
for t in tools/test_*.js; do run "$(basename "$t" .js)" node "$t"; done
if [ -n "$APP" ]; then run test_optional_diagnostics bash tools/test_optional_diagnostics.sh "$APP"
else echo "skip  test_optional_diagnostics (pass the built 1401.app to run it)"; fi
echo; echo "$pass passed, $fail failed${failed:+:$failed}   (logs in out/tests)"
[ "$fail" = 0 ]
