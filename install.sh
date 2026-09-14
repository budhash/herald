#!/usr/bin/env bash
# install.sh — install herald (the CLI + its Claude skill).
#
#   curl -fsSL https://github.com/budhash/herald/releases/latest/download/install.sh | bash
#   ./install.sh                     # from a clone, or beside a downloaded herald
#   ./install.sh --uninstall         # remove what this installed, nothing else
#   ./install.sh --dry-run           # show every action, change nothing
#
# Installs:
#   <prefix>/herald                          the CLI            (prefix: ~/.local/bin)
#   ~/.claude/skills/herald/SKILL.md         the companion skill, written by `herald skill install`
#
# herald is a SINGLE self-sufficient file — the skill is embedded in it, so there is no archive to
# unpack and nothing else to keep in sync. This script only fetches, verifies and places it.
#
# herald is a bash 3.2 script with two runtime deps — `herdr` and `jq`. This installer does NOT
# install them: herdr is a terminal multiplexer whose upgrade can break live sessions, so silently
# pulling it in behind a one-liner would be the wrong call. It checks, reports, and tells you how.
set -euo pipefail

REPO="budhash/herald"
PREFIX="${HERALD_PREFIX:-$HOME/.local/bin}"
SKILL_DIR="${HERALD_SKILL_DIR:-$HOME/.claude/skills/herald}"
DRYRUN=""
ACTION="install"

RED=''; GRN=''; YEL=''; DIM=''; OFF=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
fi
info() { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$GRN" "$OFF" "$*"; }
warn() { printf '%s!%s %s\n' "$YEL" "$OFF" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }
run()  { if [ -n "$DRYRUN" ]; then printf '%sDRY:%s %s\n' "$DIM" "$OFF" "$*"; else "$@"; fi; }

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) ACTION="uninstall" ;;
    --dry-run|-n) DRYRUN=1 ;;
    --prefix) shift; PREFIX="${1:?--prefix needs a path}" ;;
    --prefix=*) PREFIX="${1#*=}" ;;
    -h|--help) usage ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

# ── locate the payload ────────────────────────────────────────────────────────
# Either herald sits next to us (a clone, or a manual download), or we were piped
# from curl and must fetch a release. Piped-from-stdin is why $0 is not a reliable anchor.
SRC=""
_self_dir() { CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P; }
if d="$(_self_dir)" && [ -f "$d/herald" ]; then SRC="$d"; fi

TMP=""
# `return 0` is load-bearing: an EXIT trap's status becomes the SCRIPT's status, so a bare
# `[ -n "$TMP" ] && …` chain made a successful install exit 1 whenever $TMP was empty.
cleanup() { [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"; return 0; }
trap cleanup EXIT INT TERM

fetch_release() {
  command -v curl >/dev/null 2>&1 || die "need curl to download a release"
  TMP="$(mktemp -d)"
  local base="https://github.com/$REPO/releases/latest/download"
  info "fetching latest release of $REPO …"

  # Public repo: anonymous curl. Private repo: fall back to gh, which carries the user's auth.
  if curl -fsSL "$base/herald" -o "$TMP/herald" 2>/dev/null; then
    curl -fsSL "$base/herald.sha256" -o "$TMP/herald.sha256" 2>/dev/null || true
  elif command -v gh >/dev/null 2>&1; then
    info "anonymous download failed (private repo?) — retrying with gh"
    gh release download --repo "$REPO" --pattern 'herald*' --dir "$TMP" --clobber \
      || die "gh could not download a release from $REPO"
  else
    die "could not download a release.
   The repo may be private. Either install gh (https://cli.github.com) and run 'gh auth login',
   or clone the repo and run ./install.sh from inside it."
  fi

  if [ -f "$TMP/herald.sha256" ]; then
    ( cd "$TMP" && if command -v shasum >/dev/null 2>&1; then shasum -a 256 -c herald.sha256
      elif command -v sha256sum >/dev/null 2>&1; then sha256sum -c herald.sha256
      else warn "no shasum/sha256sum — skipping checksum verification"; fi ) \
      || die "checksum verification FAILED — refusing to install"
    ok "checksum verified"
  else
    warn "no published checksum found — installing unverified"
  fi

  SRC="$TMP"
}

# ── uninstall ─────────────────────────────────────────────────────────────────
if [ "$ACTION" = "uninstall" ]; then
  removed=0
  if [ -e "$PREFIX/herald" ]; then run rm -f "$PREFIX/herald"; ok "removed $PREFIX/herald"; removed=1; fi
  if [ -e "$SKILL_DIR/SKILL.md" ] || [ -L "$SKILL_DIR/SKILL.md" ]; then
    run rm -f "$SKILL_DIR/SKILL.md"
    run rmdir "$SKILL_DIR" 2>/dev/null || true
    ok "removed $SKILL_DIR/SKILL.md"; removed=1
  fi
  [ "$removed" -eq 1 ] || info "nothing to remove"
  info ""
  info "Your channel state in ~/.local/state/herald was left alone — remove it yourself if you want it gone."
  exit 0
fi

# ── install ───────────────────────────────────────────────────────────────────
[ -n "$SRC" ] || fetch_release

[ -f "$SRC/herald" ] || die "no 'herald' found in $SRC"
bash -n "$SRC/herald" || die "'herald' failed a syntax check — refusing to install"

run mkdir -p "$PREFIX"
run install -m 0755 "$SRC/herald" "$PREFIX/herald"
[ -n "$DRYRUN" ] || ok "installed $PREFIX/herald"

# The skill is EMBEDDED in herald, so herald installs it — one code path, and it stays repairable
# long after this script has exited (`herald skill status` / `herald skill install`).
if [ -n "$DRYRUN" ]; then
  printf '%sDRY:%s %s\n' "$DIM" "$OFF" "$PREFIX/herald skill install --dir $SKILL_DIR"
else
  if out="$("$PREFIX/herald" skill install --dir "$SKILL_DIR" 2>&1)"; then
    ok "${out#herald: }"
  else
    warn "${out#herald: }"
    info "  the CLI is installed; re-run 'herald skill install' once that is resolved"
  fi
fi

ver="$( [ -n "$DRYRUN" ] && echo '(dry-run)' || "$PREFIX/herald" --version 2>/dev/null || true)"
[ -n "$ver" ] && info "  version: $ver"

# ── post-install: report, never auto-fix ──────────────────────────────────────
info ""
missing=""
for t in herdr jq; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -n "$missing" ]; then
  warn "missing runtime dependencies:$missing"
  info "    herdr — the terminal multiplexer herald talks through:  https://github.com/herdrdev/herdr"
  info "    jq    — JSON parsing:  brew install jq  |  apt install jq"
  info "  herald cannot run until these are on PATH."
else
  ok "dependencies present (herdr, jq)"
fi

case ":$PATH:" in
  *":$PREFIX:"*) ok "$PREFIX is on PATH" ;;
  *) warn "$PREFIX is NOT on PATH — add this to your shell rc:"
     info "    export PATH=\"$PREFIX:\$PATH\"" ;;
esac

info ""
info "herald talks between two Claude sessions running in adjacent herdr panes."
info "Start inside a herdr pane with:  ${GRN}herald ls${OFF}"
