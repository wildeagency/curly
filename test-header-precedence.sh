#!/usr/bin/env bash
# Header precedence: a caller-supplied -H always wins over one curly would add itself,
# whether that header comes from the service's static .headers map or from the auto
# Content-Type on a JSON body.
#
# WHY THIS ASSERTS ARGV AND NOT AN API RESPONSE. The failure being guarded is two headers
# of one name on the wire. curl does not de-duplicate them; the server decides. Slack says
# `invalid_post_type` — loud. Notion returns **200 having silently dropped the entire body**,
# so a query with a filter, a cursor and a page_size returns unfiltered default rows and
# nothing anywhere reports an error. An API-response test would therefore pass on the exact
# service where the bug is invisible. The curl shim below makes the emitted argv the subject,
# which is the property, not a proxy for it.
#
# Run: ./test-header-precedence.sh [path-to-curly]   (defaults to ./curly)
set -uo pipefail
CURLY="${1:-./curly}"
[ -x "$CURLY" ] || { echo "not executable: $CURLY" >&2; exit 2; }
CURLY=$(cd "$(dirname "$CURLY")" && pwd)/$(basename "$CURLY")

SHIM=$(mktemp -d)
trap 'rm -rf "$SHIM"' EXIT
cat > "$SHIM/curl" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\n' "$a"; done
SH
chmod +x "$SHIM/curl"

pass=0 fail=0
# count_hdr <name> -- counts headers curly ITSELF added (separate -H then value form).
run() { PATH="$SHIM:$PATH" "$CURLY" "$@" 2>/dev/null; }
count_hdr() { grep -ci "^$1:" ; }

check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$1"
  else fail=$((fail+1)); printf 'FAIL %s — expected %s, got %s\n' "$1" "$2" "$3"; fi
}

out=$(run slack chat.postMessage -X POST -H 'Content-Type: application/json; charset=utf-8' -d '{}')
check "1 explicit Content-Type + body → exactly one Content-Type" 1 "$(printf '%s\n' "$out" | count_hdr content-type)"
check "1b and it is the caller's" 1 "$(printf '%s\n' "$out" | grep -c 'charset=utf-8')"

out=$(run slack chat.postMessage -X POST -d '{}')
check "2 body, no explicit → curly adds exactly one" 1 "$(printf '%s\n' "$out" | count_hdr content-type)"

out=$(run notion blocks/abc)
check "3 no body → curly adds none" 0 "$(printf '%s\n' "$out" | count_hdr content-type)"

out=$(run slack chat.postMessage -X POST -H'Content-Type: text/plain' -d '{}')
check "4 joined -H form suppresses the auto header" 0 "$(printf '%s\n' "$out" | count_hdr content-type)"

out=$(run slack chat.postMessage -X POST --header='Content-Type: text/plain' -d '{}')
check "5 --header= form suppresses the auto header" 0 "$(printf '%s\n' "$out" | count_hdr content-type)"

out=$(run notion blocks/abc -H 'Notion-Version: 2022-06-28')
check "6 caller overrides a STATIC header → exactly one" 1 "$(printf '%s\n' "$out" | count_hdr notion-version)"
check "6b and it is the caller's" 1 "$(printf '%s\n' "$out" | grep -c '2022-06-28')"

out=$(run notion blocks/abc)
check "7 no override → the static header still ships" 1 "$(printf '%s\n' "$out" | count_hdr notion-version)"

# CONTROL. Not decoration: cases 1 and 6 are the two the fix exists for, and a suite that
# cannot fail on the pre-fix script is not evidence about either of them. Runs the same two
# cases against the pre-fix script and requires BOTH to come back with the duplicate.
#
# PINNED TO A COMMIT, NOT TO HEAD, AND THAT IS THE WHOLE POINT. The first draft read
# `HEAD:curly`, which was the pre-fix commit at the minute it was written and became the
# FIXED commit the minute the fix landed — at which point both controls would quietly
# invert, reporting 1 where they demand 2, and a green suite would go red for a reason
# that has nothing to do with the code under test. A control anchored on a moving
# reference tests the reference. d42cc8f is the last commit before the fix; if it ever
# leaves this repo's history the control is gone and the suite says so rather than passing.
PREFIX_COMMIT=d42cc8f
HEADC="$SHIM/curly.head"
if git -C "$(dirname "$CURLY")" show "$PREFIX_COMMIT:curly" > "$HEADC" 2>/dev/null && [ -s "$HEADC" ]; then
  chmod +x "$HEADC"
  a=$(PATH="$SHIM:$PATH" "$HEADC" slack chat.postMessage -X POST -H 'Content-Type: application/json; charset=utf-8' -d '{}' 2>/dev/null | count_hdr content-type)
  b=$(PATH="$SHIM:$PATH" "$HEADC" notion blocks/abc -H 'Notion-Version: 2022-06-28' 2>/dev/null | count_hdr notion-version)
  check "C1 pre-fix script ($PREFIX_COMMIT) DOES duplicate Content-Type" 2 "$a"
  check "C2 pre-fix script ($PREFIX_COMMIT) DOES duplicate a static header" 2 "$b"
else
  fail=$((fail+1)); echo "FAIL control — could not read $PREFIX_COMMIT:curly; the suite proves nothing without it"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
