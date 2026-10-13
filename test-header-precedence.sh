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
# The shim prints curl's argv one per line, then — for each -K config curly hands it — the
# header/user values decoded back to the same `Name: value` lines, so counts see both paths.
# Argv lines go to stdout as-is; a test that needs to tell the two apart greps for ARGV:/CFG:
# via CURLY_SHIM_TAG=1.
cat > "$SHIM/curl" <<'SH'
#!/usr/bin/env bash
tag() { [ -n "${CURLY_SHIM_TAG:-}" ] && printf '%s' "$1"; }
prev=""
for a in "$@"; do
  printf '%s%s\n' "$(tag ARGV:)" "$a"
  if [ "$prev" = "-K" ]; then
    while IFS= read -r line; do
      case "$line" in
        'header = "'*'"') v=${line#header = \"}; v=${v%\"} ;;
        'user = "'*'"')   v=${line#user = \"};   v="USER:${v%\"}" ;;
        *) continue ;;
      esac
      v=${v//\\\"/\"}; v=${v//\\\\/\\}
      printf '%s%s\n' "$(tag CFG:)" "$v"
    done < "$a"
  fi
  prev=$a
done
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

# ─── #3: the token never appears in curl's argv ─────────────────────────────────────────
# Sandboxed config so these cases need no real ~/.curly.yaml. The token is a sentinel, never
# a live credential: the real-curl case below runs `ps`, and a transcript that captures it
# must not capture anything worth having.
SB="$SHIM/sb"; mkdir -p "$SB"
SENT="tok_SENTINEL_$$_$RANDOM"
cat > "$SB/curly.yaml" <<YAML
services:
  b:  { host: "http://127.0.0.1:1", auth: bearer, token: "$SENT" }
  h:  { host: "http://127.0.0.1:1", auth: header, auth_header: X-Api-Key, token: "$SENT" }
  c:  { host: "http://127.0.0.1:1", auth: cookie, token: "$SENT" }
  u:  { host: "http://127.0.0.1:1", auth: basic, token: "me:$SENT" }
  q:  { host: "http://127.0.0.1:1", auth: bearer, token: 'a"b\\c$SENT' }
YAML
sbrun() { CURLY_YAML="$SB/curly.yaml" CURLY_SHIM_TAG=1 PATH="$SHIM:$PATH" "$CURLY" "$@" 2>/dev/null; }
for svc in b h c u; do
  out=$(sbrun "$svc" /x)
  check "8$svc auth=$svc: token absent from argv" 0 "$(printf '%s\n' "$out" | grep '^ARGV:' | grep -c "$SENT")"
  check "8$svc auth=$svc: token delivered via -K" 1 "$(printf '%s\n' "$out" | grep '^CFG:' | grep -c "$SENT")"
done
out=$(sbrun q /x)
check "9 quote/backslash in token survives -K escaping" 1 "$(printf '%s\n' "$out" | grep -cF "CFG:Authorization: Bearer a\"b\\c$SENT")"
out=$(printf 'body' | sbrun b /x -d @-)
check "10 caller's stdin body (-d @-) still passes through" 1 "$(printf '%s\n' "$out" | grep -c '^ARGV:@-$')"

# The real thing: real curl, a local listener that reads the request and never answers, so
# curl sits mid-request while `ps` looks at every process on the box. Then the listener's
# capture proves the header still reached the wire — absence from ps alone would also pass
# for a curly that silently stopped authenticating.
if command -v python3 >/dev/null; then
  CAP="$SB/wire.txt"; PORTF="$SB/port"
  python3 -I -c '
import socket,sys,time
s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(1)
open(sys.argv[2],"w").write(str(s.getsockname()[1]))
c,_=s.accept(); d=b""
while b"\r\n\r\n" not in d: d+=c.recv(4096)
open(sys.argv[1],"wb").write(d); time.sleep(30)' "$CAP" "$PORTF" &
  LPID=$!
  for _ in $(seq 50); do [ -s "$PORTF" ] && break; sleep 0.1; done
  printf 'services:\n  live: { host: "http://127.0.0.1:%s", auth: bearer, token: "%s" }\n' "$(cat "$PORTF")" "$SENT" > "$SB/live.yaml"
  CURLY_YAML="$SB/live.yaml" "$CURLY" live /probe --max-time 20 >/dev/null 2>&1 &
  CPID=$!
  for _ in $(seq 50); do [ -s "$CAP" ] && break; sleep 0.1; done
  seen_curl=$(ps -axww -o pid=,args= | grep -c "curl.*127.0.0.1:$(cat "$PORTF")/probe")
  in_ps=$(ps -axww -o args= | grep -v grep | grep -c "$SENT")
  kill "$CPID" "$LPID" 2>/dev/null; wait "$CPID" "$LPID" 2>/dev/null
  check "11a real curl is in flight while ps runs (else 11b proves nothing)" 1 "$([ "$seen_curl" -ge 1 ] && echo 1 || echo 0)"
  check "11b token appears in NO process's argv (ps -axww)" 0 "$in_ps"
  check "11c and it still reached the wire as Authorization" 1 "$(grep -c "^Authorization: Bearer $SENT" "$CAP" 2>/dev/null || echo 0)"
else
  echo "skip 11 — python3 not found for the local listener"
fi

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
