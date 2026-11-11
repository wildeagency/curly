#!/usr/bin/env sh
# curly install.sh: one-shot installer.
#
# Usage. Fetch it, read it, then run it. Don't pipe it into sh.
#   curl -fsSLo curly-install.sh https://raw.githubusercontent.com/wildeagency/curly/main/install.sh
#   less curly-install.sh
#   sh curly-install.sh protocol            # install, then set up protocol.supply
#   sh curly-install.sh                     # install only
#   sh curly-install.sh protocol ghost-user=user_xxx
#
# The optional trailing args are `<service> [key=value ...]` and go to
# `curly init`. That command prompts for the token with input hidden. A token
# is never an argument here: argv lands in shell history and `ps`. A bare
# second argument (no `=`) is refused for that reason.
#
# Env vars (override defaults):
#   PREFIX        Install dir for the curly binary (default: ~/.local/bin)
#   REPO          GitHub repo (default: wildeagency/curly)
#   BRANCH        Git branch / tag (default: main)
#   RAW           Base URL the binary is fetched from (default: built from REPO
#                 and BRANCH; file:// works, for testing a checkout)
#   NO_PATH=1     Skip adding $PREFIX to PATH in shell rc

set -eu

REPO="${REPO:-wildeagency/curly}"
BRANCH="${BRANCH:-main}"
PREFIX="${PREFIX:-$HOME/.local/bin}"
NO_PATH="${NO_PATH:-0}"
RAW="${RAW:-https://raw.githubusercontent.com/$REPO/$BRANCH}"

say() { printf '%s\n' "$*"; }
ok()  { printf '✓ %s\n' "$*"; }
warn(){ printf '! %s\n' "$*" >&2; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

# ─── 0. Validate args before touching anything ──────────────────────────────
SERVICE="${1:-}"
if [ -n "$SERVICE" ]; then
  case "$SERVICE" in
    *[!a-zA-Z0-9_-]*) die "bad service name '$SERVICE' (usage: sh install.sh [service [key=value ...]])" ;;
  esac
  shift
  for a in "$@"; do
    case "$a" in
      *=*) ;;
      *) die "'$SERVICE' takes key=value extras only. A bare value looks like a token, and tokens never go on the command line. curly will prompt for it with input hidden." ;;
    esac
  done
fi

# ─── 1. Dependency check ────────────────────────────────────────────────────
missing=
for d in curl yq jq; do have "$d" || missing="$missing $d"; done

if [ -n "$missing" ]; then
  warn "Missing:$missing"
  if have brew; then
    say  "→ brew install$missing"
    # shellcheck disable=SC2086
    brew install $missing
  elif have apt-get; then
    die  "Install with: sudo apt-get install -y$missing  (then re-run this installer)"
  elif have dnf; then
    die  "Install with: sudo dnf install -y$missing  (then re-run this installer)"
  else
    die  "Install$missing manually, then re-run."
  fi
fi
ok "deps: curl yq jq"

# ─── 2. Drop the curly binary ───────────────────────────────────────────────
mkdir -p "$PREFIX"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
curl -fsSL "$RAW/curly" -o "$TMP" || die "download failed: $RAW/curly"
chmod +x "$TMP"
mv "$TMP" "$PREFIX/curly"
ok "installed: $PREFIX/curly"
CURLY="$PREFIX/curly"

# ─── 3. PATH wiring ─────────────────────────────────────────────────────────
case ":${PATH:-}:" in
  *":$PREFIX:"*) on_path=1 ;;
  *) on_path=0 ;;
esac

if [ "$on_path" -eq 0 ] && [ "$NO_PATH" != "1" ]; then
  marker='# Added by curly install.sh'
  rc_updated=0
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [ -f "$rc" ] || continue
    if ! grep -qF "$PREFIX" "$rc"; then
      {
        printf '\n%s\n' "$marker"
        # shellcheck disable=SC2016  # $PATH must stay literal in the rc file
        printf 'export PATH="%s:$PATH"\n' "$PREFIX"
      } >> "$rc"
      ok "PATH wired in $rc"
      rc_updated=1
    fi
  done
  if [ "$rc_updated" -eq 1 ]; then
    warn "Reload your shell or: export PATH=\"$PREFIX:\$PATH\""
  fi
fi

# ─── 4. Configure the named service (hidden token prompt) ───────────────────
# No starter YAML: `curly init` creates ~/.curly.yaml at chmod 600 with only
# the services you name. A template full of placeholders sends junk headers.
INIT_RAN=0
if [ -n "$SERVICE" ]; then
  say
  if [ "$SERVICE" = protocol ]; then
    say "Get a token: sign in at https://protocol.supply/api-keys → New key, then copy it."
  fi
  say "→ curly init $SERVICE${1:+ $*}"
  if [ -t 0 ] && [ -t 1 ]; then
    "$CURLY" init "$SERVICE" "$@" && INIT_RAN=1
  elif [ -t 1 ] && (: </dev/tty) 2>/dev/null; then
    # stdin is not a terminal (piped in?): read the hidden prompt from the tty.
    "$CURLY" init "$SERVICE" "$@" </dev/tty && INIT_RAN=1
  else
    warn "No terminal to prompt on. Run this yourself, in a terminal you control:"
    warn "  curly init $SERVICE${1:+ $*}"
  fi
fi

# ─── 5. Doctor ──────────────────────────────────────────────────────────────
say
"$CURLY" doctor || true
say
if [ "$SERVICE" = protocol ] && [ "$INIT_RAN" -eq 1 ]; then
  say "Try:   curly protocol bootstrap"
  say "Next:  wire your agent. See https://protocol.supply/@protocol/onboarding"
elif [ -z "$SERVICE" ]; then
  say "Next:  curly init <service>   (e.g. curly init protocol; it prompts for the token, hidden)"
fi
