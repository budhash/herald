#!/usr/bin/env bash
# private-scan.sh — fail if an internal name has crept into this public repo.
#
# herald was extracted from a larger private toolchain. Scrubbing it once was easy; keeping it
# scrubbed is the part that needs enforcing, which is why this runs in CI.
#
# The blocklist is stored as SHA-256 HASHES, not plaintext. That is the whole point: a public file
# listing the names you are trying to keep private would itself be the leak. For the same reason a
# match reports only file:line — never the matched word — because CI logs on a public repo are public.
#
#   ./tools/private-scan.sh              scan tracked files
#   ./tools/private-scan.sh --commits    also scan commit messages
#   ./tools/private-scan.sh --add <word> print the hash to paste into BLOCKED below
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# sha256(lowercased term), one per line.
BLOCKED='
da7f85eaf3d0452479031da124d28778aaf15cc756a6c909d7dc708fade343f0
2cee6d2ee8b53dea333daa53564648904193ee0c1c183b68e3b917a51e4f1762
0c70a21899e11f83edba1c39e818036cb2b0321280f84282b60b3ca3ba997407
34adbf69b5f5214e5b82b8b13056e06c7b883f8e77c55d1ed3423bbe86440788
5dae49cebfdd9e85831743f7ff285e21f726e34e70dfa4d0855999a5d4bc276a
6f152dfb91abda36db03588e7f01555751d8025d1290c257d25a54ba97488b4a
f2e40fc1edb72ee9ed58fd7076934ed03eefc0116b9d90b32c0bcf381b2e788f
'

_sha() { printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -d' ' -f1; }

if [ "${1:-}" = "--add" ]; then
  [ -n "${2:-}" ] || { echo "usage: $0 --add <word>" >&2; exit 2; }
  _sha "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  exit 0
fi

command -v shasum >/dev/null 2>&1 || { echo "private-scan: needs shasum" >&2; exit 2; }

# This file necessarily contains the hashes, so scanning it would be self-referential noise.
SELF="tools/private-scan.sh"

scan_stream() {   # $1 = label for reporting; reads text on stdin
  local label="$1" line n=0 word h
  while IFS= read -r line; do
    n=$((n + 1))
    # tokenise into identifier-ish words; a private name is always one token
    for word in $(printf '%s' "$line" | tr -c 'A-Za-z0-9_-' ' '); do
      case "$word" in ''|[0-9]*) continue ;; esac
      h="$(_sha "$(printf '%s' "$word" | tr '[:upper:]' '[:lower:]')")"
      case "$BLOCKED" in
        *"$h"*) printf 'LEAK  %s:%s  (matches a blocked term — see the line)\n' "$label" "$n"; fail=1 ;;
      esac
    done
  done
}

fail=0
for f in $(git ls-files); do
  [ "$f" = "$SELF" ] && continue
  case "$f" in *.png|*.jpg|*.gif|*.ico|*.zip) continue ;; esac
  scan_stream "$f" < "$f"
done

if [ "${1:-}" = "--commits" ]; then
  git log --format='%h %s%n%b' | scan_stream "commit-log"
fi

if [ "$fail" -eq 0 ]; then
  echo "private-scan: clean"
else
  echo "private-scan: FAILED — remove the internal names on the lines above" >&2
fi
exit "$fail"
