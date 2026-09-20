# herald — CLAUDE.md

> **herald** is a single bash 3.2 script that lets **two agent sessions in different
> [herdr](https://github.com/herdrdev/herdr) panes, tabs or workspaces exchange messages directly**,
> instead of a human relaying between them. A per-channel delivery budget runs out and pauses, so an
> exchange cannot run on unattended. Read this cold and you're oriented;
> `README.md` is the user-facing doc.
> **Status: stable, v1.0.0.**

## Prime directive

herald is useful because it is bounded. The budget, the pause, and verified submission are what it
sells; an unbounded message bus would be less code and less use.

- **Never weaken the gate.** The budget is enforced in the CLI, not by agent goodwill. Any change that
  makes exhausting or releasing it cheaper needs a very good reason.
- **Stay one file.** herald is distributed as a single script with the skill embedded. No runtime
  dependencies beyond `herdr` and `jq`; no sibling files; no network at run time.
- **bash 3.2.** macOS ships 3.2. No `declare -g`, no `${x^^}`, no associative arrays.
- **Report what happened.** "Delivered" means submitted and verified, not typed and assumed. Callers
  branch on the exit codes below, so do not renumber or repurpose them.

## Layout

```
herald                      THE script. bash 3.2. Contains the EMBEDDED skill (see below).
install.sh                  Fetch/verify/place herald; delegates skill install to herald itself.
skills/herald/SKILL.md      Editable SOURCE of the skill; embedded into `herald` by make sync-skill.
tools/embed-skill.py        Does that embedding. Idempotent — replaces the block, never appends.
test/run-tests.sh           146 tests. `.common/test-common` is the shared assertion harness.
version.txt                 Single source of version truth; CI fails if the script disagrees.
Makefile                    syntax · lint · skill-sync · version · test · ci
```

## The embedded skill — how it works, and why

`herald skill install` writes `~/.claude/skills/herald/SKILL.md`. The content lives **inside the script**
in a quoted heredoc (`<<'__HERALD_SKILL__'` — quoted because the skill is full of backticks and `$(…)`
that must not expand).

Why embed rather than ship a second file: a bare `herald` downloaded on its own is then fully
functional, which means **releases are a single script** — no archive to build, verify or unpack — and
the skill stays repairable long after any installer has exited.

**Editing the skill:** edit `skills/herald/SKILL.md`, then `make sync-skill`. Never hand-edit the
heredoc. `make skill-sync` fails CI if the two drift, so they cannot silently diverge.

**`herald skill install` refuses to clobber a symlink.** That is deliberate, not defensive padding:
another tool may own that path and link it into its own tree, and silently replacing it would break
that ownership. `--force` overrides; `--dir` installs elsewhere.

## Exit codes (a public contract — do not renumber)

| code | meaning |
|---|---|
| `0` | delivered **and** submitted, verified |
| `1` | failed / error |
| `3` | typed into the peer's prompt but **never submitted** — recover with `herald nudge` (free) |
| `4` | **paused** at budget 0 — nothing delivered; only a human can release it |

## Testing

```sh
make test     # 146 tests, no herdr required
make ci       # syntax + lint + skill-sync + version + test
```

The suite stubs the transport with **`HERALD_STUB_HERDR=1`**, which advances real state (budget,
transcript, queue) while typing into no real pane. `HERALD_STUB_HERDR=stalled` and `=fail` simulate the
two failure modes that matter. These are separate from `HERALD_DRYRUN=1`, which is a user-facing
rehearsal that must mutate *nothing* — asserted independently.

Cases labelled **(live-found)** encode bugs hit in real use. Keep them, and add to them: every one of
them is a thing that looked fine in review and was wrong in practice.

## Boundaries

herald does one thing: carry a bounded, human-gated message between two panes. It is **not** a session
manager, a scheduler, or a group chat. Anything that orchestrates sessions belongs in a separate tool
that *calls* herald — and such a tool must go through this CLI rather than reading the state files
directly, or the state layout becomes a contract herald can never change.

## Working here

- **Commits go direct to `main`.** No `Generated with` / `Co-Authored-By` trailers.
- **Run `make ci` before every commit.**
- **Releasing:** bump `version.txt` *and* `HERALD_VERSION` in the script (CI enforces they match), tag
  `vX.Y.Z`, push the tag. The release workflow verifies on linux+macos, smoke-tests the installer the
  way the README documents it, then publishes `herald`, `install.sh` and their `.sha256` files.
- **Verify against reality, not docs.** herdr's CLI has changed shape before; its `--help` outranks any
  memory of its API.
