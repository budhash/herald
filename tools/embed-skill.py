#!/usr/bin/env python3
"""Re-embed skills/herald/SKILL.md into the herald script.

The skill is embedded so that a bare `herald` file is self-sufficient — no sibling files, no archive,
no network. skills/herald/SKILL.md stays the editable source of truth; this script copies it into the
quoted heredoc inside `_skill_doc()`. `make skill-sync` fails CI if the two ever drift.

Idempotent: it REPLACES the existing block rather than appending, so running it twice is a no-op.
"""
import sys
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "herald"
SKILL = ROOT / "skills" / "herald" / "SKILL.md"

OPEN = "_skill_doc() { cat <<'__HERALD_SKILL__'\n"
CLOSE = "\n__HERALD_SKILL__\n}"


def main() -> int:
    for p in (SCRIPT, SKILL):
        if not p.is_file():
            print(f"embed-skill: missing {p}", file=sys.stderr)
            return 1

    src = SCRIPT.read_text()
    skill = SKILL.read_text().rstrip("\n")

    # A quoted heredoc ends at a line that is exactly the delimiter. If the skill ever contained such
    # a line it would truncate the function silently, so refuse rather than emit a broken script.
    if any(line == "__HERALD_SKILL__" for line in skill.splitlines()):
        print("embed-skill: SKILL.md contains a line equal to the heredoc delimiter", file=sys.stderr)
        return 1

    start = src.find(OPEN)
    if start == -1:
        print("embed-skill: could not find the _skill_doc heredoc in herald", file=sys.stderr)
        return 1
    body_at = start + len(OPEN)
    end = src.find(CLOSE, body_at)
    if end == -1:
        print("embed-skill: unterminated _skill_doc heredoc in herald", file=sys.stderr)
        return 1

    updated = src[:body_at] + skill + src[end:]
    if updated == src:
        print("embed-skill: already in sync")
        return 0

    SCRIPT.write_text(updated)
    print(f"embed-skill: embedded {len(skill.splitlines())} lines from {SKILL.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
