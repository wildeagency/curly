#!/usr/bin/env bash
# `curly doctor` must report whether each token WORKS, not merely whether it is present —
# and must never print a token, even when the API echoes it back in an error body.
#
# Hermetic: a local stub server (python3) plays the API, and the config is a synthetic
# file via $CURLY_YAML — never reads a real .curly.yaml. Labelled control: a known-good
# token must read ok, so a probe that rejects everything cannot pass.
# Run: ./test-doctor-validation.sh [path-to-curly]   (defaults to ./curly)
set -uo pipefail
CURLY="${1:-./curly}"
[ -x "$CURLY" ] || { echo "not executable: $CURLY" >&2; exit 2; }
CURLY=$(cd "$(dirname "$CURLY")" && pwd)/$(basename "$CURLY")
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 2; }

TMP=$(mktemp -d)
cat > "$TMP/stub.py" <<'PY'
import http.server, json, sys
GOOD = "Bearer good-token-AAAA"
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        auth = self.headers.get("Authorization", "")
        if self.path == "/me":            # bearer API; 401 body ECHOES the token, like OpenAI's
            return self.send(200, {"id": 1}) if auth == GOOD else self.send(401, {"error": "bad key " + auth})
        if self.path == "/auth.test":     # Slack-shaped: always 200, verdict in .ok
            if auth == GOOD: return self.send(200, {"ok": True})
            if auth.endswith("expired"): return self.send(200, {"ok": False, "error": "token_expired"})
            return self.send(200, {"ok": False, "error": "invalid_auth"})
        if self.path == "/scoped": return self.send(403, {"error": "forbidden"})
        if self.path == "/down":   return self.send(503, {"error": "loading"})
        return self.send(404, {"error": "nope"})
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); body = self.rfile.read(n)
        ok = self.headers.get("Authorization") == GOOD and b"viewer" in body
        return self.send(200, {"data": {}}) if ok else self.send(401, {"error": "no"})
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_port, flush=True)
s.serve_forever()
PY
python3 -I "$TMP/stub.py" > "$TMP/port" &
STUB=$!
trap 'kill $STUB 2>/dev/null; wait $STUB 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
PORT=$(cat "$TMP/port")
[ -n "$PORT" ] || { echo "stub failed to start" >&2; exit 2; }
H="http://127.0.0.1:$PORT"

export CURLY_YAML="$TMP/curly.yaml"
cat > "$CURLY_YAML" <<YAML
services:
  control-good:  {host: "$H", auth: bearer, token: good-token-AAAA,      check: /me}
  bad-401:       {host: "$H", auth: bearer, token: BADTOKEN-401-ZZZZ,    check: /me}
  slack-good:    {host: "$H", auth: bearer, token: good-token-AAAA,      check: /auth.test}
  slack-bad:     {host: "$H", auth: bearer, token: BADTOKEN-SLACK-ZZZZ,  check: /auth.test}
  slack-expired: {host: "$H", auth: bearer, token: BADTOKEN-expired,     check: /auth.test}
  post-good:     {host: "$H", auth: bearer, token: good-token-AAAA,      check: /gql, check_body: '{"query":"{ viewer { id } }"}'}
  scoped:        {host: "$H", auth: bearer, token: good-token-AAAA,      check: /scoped}
  flaky:         {host: "$H", auth: bearer, token: good-token-AAAA,      check: /down}
  wrongpath:     {host: "$H", auth: bearer, token: good-token-AAAA,      check: /nowhere}
  nocheck:       {host: "$H", auth: bearer, token: good-token-AAAA}
  disabled:      {host: "$H", auth: bearer, token: good-token-AAAA,      check: false}
  empty:         {host: "$H", auth: bearer, token: ""}
  dead:          {host: "http://127.0.0.1:1", auth: bearer, token: good-token-AAAA, check: /me}
YAML
chmod 600 "$CURLY_YAML"

OUT=$("$CURLY" doctor 2>&1); RC=$?
OFF=$("$CURLY" doctor --offline 2>&1); OFFRC=$?

pass=0 fail=0
row() { printf '%s\n' "$OUT" | grep -E "^  $1 " ; }
check() { # check <label> <svc> <expected substring>
  if row "$2" | grep -qF -- "$3"; then pass=$((pass+1)); printf 'ok   %s\n' "$1"
  else fail=$((fail+1)); printf 'FAIL %s — got: %s\n' "$1" "$(row "$2")"; fi
}
check "CONTROL: known-good token reads ok"          control-good  "ok (verified"
check "bad token reads INVALID (401)"               bad-401       "INVALID"
check "slack-shaped good reads ok"                  slack-good    "ok (verified"
check "slack-shaped 200 ok:false reads INVALID"     slack-bad     "INVALID — invalid_auth"
check "slack token_expired reads EXPIRED"           slack-expired "EXPIRED"
check "POST check with body reads ok"               post-good     "ok (verified: POST"
check "403 reads REJECTED"                          scoped        "REJECTED"
check "503 is unverified, not invalid"              flaky         "unverified — HTTP 503"
check "404 hints at a wrong check path"             wrongpath     "check path wrong"
check "no check path: present, unverified"          nocheck       "present, unverified"
check "check: false skips the probe"                disabled      "check disabled"
check "empty token still MISSING"                   empty         "MISSING TOKEN"
check "unreachable host reads unreachable"          dead          "unreachable"

t() { # t <label> <0=pass|nonzero=fail>
  if [ "$2" = 0 ]; then pass=$((pass+1)); printf 'ok   %s\n' "$1"; else fail=$((fail+1)); printf 'FAIL %s\n' "$1"; fi; }
printf '%s' "$OUT$OFF" | grep -qE "BADTOKEN|good-token-AAAA"; t "no token ever printed (stub echoes it in 401 body)" "$(( $? == 0 ))"
[ "$RC" = 1 ];    t "doctor exits 1 when a token is invalid" $?
printf '%s\n' "$OFF" | grep -E "^  bad-401 " | grep -qF "not checked: --offline"; t "--offline makes no probe, reads presence" $?
[ "$OFFRC" = 0 ]; t "--offline exits 0 (nothing judged invalid)" $?

echo "---"; echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
