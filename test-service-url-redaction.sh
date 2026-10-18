#!/usr/bin/env bash
# `curly services` / `curly init` must never print a secret that lives in a service URL.
#
# Telegram's API puts the bot token in the path (https://api.telegram.org/bot<id>:<token>/),
# so a raw host listing writes a live credential into every terminal and agent transcript
# that runs `curly services`. The display layer redacts; requests still use the real URL.
#
# Uses a synthetic config via $CURLY_YAML only — never reads a real .curly.yaml.
# Run: ./test-service-url-redaction.sh [path-to-curly]   (defaults to ./curly)
set -uo pipefail
CURLY="${1:-./curly}"
[ -x "$CURLY" ] || { echo "not executable: $CURLY" >&2; exit 2; }
CURLY=$(cd "$(dirname "$CURLY")" && pwd)/$(basename "$CURLY")

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CURLY_YAML="$TMP/curly.yaml"
cat > "$CURLY_YAML" <<'YAML'
services:
  tg:
    host: https://api.telegram.org/bot123456:AAFakeTokenForTestOnly/
    auth: none
  plain:
    host: https://api.example.com/v1
    auth: none
  userinfo:
    host: https://alice:s3cretpw@db.example.com/api
    auth: none
  qtoken:
    host: https://hooks.example.com/in?page=2&Token=qsecretvalue&api_key=ksecretvalue
    auth: none
YAML
chmod 600 "$CURLY_YAML"

pass=0 fail=0
check() { # check <label> <0|1 expected grep hit> <pattern> <haystack>
  if printf '%s\n' "$4" | grep -qF -- "$3"; then got=1; else got=0; fi
  if [ "$got" = "$2" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$1"
  else fail=$((fail+1)); printf 'FAIL %s\n' "$1"; fi
}

out=$("$CURLY" services 2>&1)
check "1 telegram bot token is not shown"            0 "AAFakeTokenForTestOnly" "$out"
check "1b telegram host shows bot<REDACTED>"          1 "https://api.telegram.org/bot<REDACTED>/" "$out"
check "2 plain URL is unchanged"                      1 "https://api.example.com/v1" "$out"
check "3 userinfo password is not shown"              0 "s3cretpw" "$out"
check "3b userinfo is replaced, host kept"            1 "https://<REDACTED>@db.example.com/api" "$out"
check "4 query token is not shown"                    0 "qsecretvalue" "$out"
check "4b query api_key is not shown"                 0 "ksecretvalue" "$out"
check "4c credential params are masked"               1 "Token=<REDACTED>&api_key=<REDACTED>" "$out"
check "5 non-secret query param is kept"              1 "?page=2&" "$out"

init_out=$("$CURLY" init tg2 tok_unused host=https://api.telegram.org/bot654321:AAInitFakeToken/ auth=none 2>&1)
check "6 init confirmation hides the bot token"       0 "AAInitFakeToken" "$init_out"
check "6b init still stores the real host (request path unchanged)" 1 \
  "bot654321:AAInitFakeToken" "$(yq -r '.services.tg2.host' "$CURLY_YAML")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
