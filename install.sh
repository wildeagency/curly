#!/usr/bin/env sh
# curly install.sh — one-shot installer.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/wildeagency/curly/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- protocol tok_xxx
#   curl -fsSL .../install.sh | sh -s -- protocol tok_xxx ghost-user=user_xxx
#
# Any trailing args after `sh -s --` are passed verbatim to `curly init` after
# install. So `... | sh -s -- <service> <token> [key=value ...]` finishes the
# whole setup in one command.
#
# Env vars (override defaults):
#   PREFIX        Install dir for the curly binary (default: ~/.local/bin)
#   REPO          GitHub repo (default: wildeagency/curly)
#   BRANCH        Git branch / tag (default: main)
#   NO_PATH=1     Skip adding $PREFIX to PATH in shell rc

set -eu

REPO="${REPO:-wildeagency/curly}"
BRANCH="${BRANCH:-main}"
PREFIX="${PREFIX:-$HOME/.local/bin}"
NO_PATH="${NO_PATH:-0}"
RAW="https://raw.githubusercontent.com/$REPO/$BRANCH"

say() { printf '%s\n' "$*"; }
ok()  { printf '✓ %s\n' "$*"; }
warn(){ printf '! %s\n' "$*" >&2; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

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

# ─── 4. Starter YAML (only if absent) ───────────────────────────────────────
YAML="${CURLY_YAML:-$HOME/.curly.yaml}"
if [ ! -f "$YAML" ]; then
  curl -fsSL "$RAW/examples/curly.yaml" -o "$YAML" || die "download failed: $RAW/examples/curly.yaml"
  chmod 600 "$YAML"
  ok "wrote starter $YAML (chmod 600)"
else
  ok "kept existing $YAML"
fi

# ─── 5. Hand off to `curly init` if positional args were supplied ───────────
CURLY="$PREFIX/curly"
if [ $# -gt 0 ]; then
  say
  say "→ curly init $*"
  "$CURLY" init "$@"
fi

# ─── 6. Doctor ──────────────────────────────────────────────────────────────
say
"$CURLY" doctor || true
say
say "Try:  curly protocol bootstrap"
