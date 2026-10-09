#!/bin/bash
# Run the translator's test suites (translator/translator and translator/wrapper) and compare the failures with
# translator/known-failing-tests.txt, the list of published tests that assert emitter behaviour or spirv-val verdicts
# this tree does not produce. The run fails on any failure outside that list, and names listed tests that now pass so
# the list can shrink. Logs: out/tests/cargo-test-<crate>.log
#
#   translator/run_tests.sh
#
# Needs cargo and spirv-val on PATH (brew install spirv-tools): nearly every test validates the module it emits, and
# the spirv-val version can move the verdict-dependent entries of the list.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd); X=$REPO/translator; LOGS=$REPO/out/tests; mkdir -p "$LOGS"
KNOWN=$X/known-failing-tests.txt; TD=${CARGO_TARGET_DIR:-$X/target}
command -v cargo >/dev/null 2>&1 || { echo "STOP: cargo not found; install a stable Rust toolchain (https://rustup.rs)"; exit 2; }
command -v spirv-val >/dev/null 2>&1 || { echo "STOP: spirv-val not on PATH (brew install spirv-tools); the tests validate every module they emit"; exit 2; }
[ -f "$KNOWN" ] || { echo "STOP: $KNOWN is missing"; exit 2; }
echo "spirv-val: $(spirv-val --version 2>&1 | head -1)"
: > "$LOGS/failed-tests.txt"; rc=0
for crate in translator wrapper; do
  log=$LOGS/cargo-test-$crate.log
  cargo test --release --no-fail-fast --manifest-path "$X/$crate/Cargo.toml" --target-dir "$TD" > "$log" 2>&1
  if grep -qE 'could not compile|^error\[E[0-9]+\]' "$log"; then
    echo "STOP: $crate tests did not build; see $log"; grep -E -m 5 'could not compile|^error\[E[0-9]+\]' "$log"; rc=1; continue
  fi
  grep -E '^test result' "$log" | sed "s/^test result/$crate/"
  grep -E '^test .* \.\.\. FAILED$' "$log" | sed -E "s/^test (.*) \.\.\. FAILED$/$crate::\1/" >> "$LOGS/failed-tests.txt"
done
failed=$(sort -u "$LOGS/failed-tests.txt" | grep -v '^$')
known=$(grep -vE '^#|^$' "$KNOWN" | sort -u)
new=$(comm -23 <(printf '%s\n' "$failed" | grep -v '^$') <(printf '%s\n' "$known" | grep -v '^$'))
fixed=$(comm -13 <(printf '%s\n' "$failed" | grep -v '^$') <(printf '%s\n' "$known" | grep -v '^$'))
[ -z "$fixed" ] || { echo; echo "listed in $KNOWN but passing now (remove them from the list):"; printf '%s\n' "$fixed" | sed 's/^/  /'; }
if [ -n "$new" ]; then
  echo; echo "FAILED outside $KNOWN:"; printf '%s\n' "$new" | sed 's/^/  /'
  for t in $new; do name=${t#*::}; awk -v n="$name" '$0 ~ "^---- "n" stdout ----"{p=1} p{print "    "$0; c++} c>6{exit}' "$LOGS"/cargo-test-*.log; done
  rc=1
else
  echo; echo "no failure outside the known list ($(printf '%s\n' "$failed" | grep -c .) known failures reproduced)"
fi
exit $rc
