# herald
[![ci](https://github.com/budhash/herald/actions/workflows/ci.yml/badge.svg)](https://github.com/budhash/herald/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/budhash/herald)](https://github.com/budhash/herald/releases/latest)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Bash 3.2+](https://img.shields.io/badge/bash-3.2+-blue.svg)](https://www.gnu.org/software/bash/)

## Summary
cross-pane messaging for [herdr](https://github.com/herdrdev/herdr): two agent
sessions running in different panes, tabs or workspaces exchange messages
directly, instead of a human relaying between them. Every channel carries a
**delivery budget** that runs out and pauses for review, so an exchange cannot
run on unattended.

It is a **single dependency-free bash script**. The companion agent skill is
embedded in it, so there is nothing to unpack and nothing to keep in sync.

## Status
Stable

## License
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the [LICENSE](LICENSE) file for the specific language governing permissions
and limitations under the License.

## Introduction

herdr runs agent sessions in panes. When two of those sessions need to
collaborate, the usual arrangement is a human in the middle, copying output from
one pane into the other. herald removes the copying without removing the human:

```
session A (w1:p1)                                session B (w2:p3)
    │  herald send w2:p3 --body-file notes.md        │
    ├───────────────────────────────────────────────►│  submitted into its prompt, and verified
    │                                                │
    │◄───────────────────────────────────────────────┤  herald send w1:p1 "done, summary below"
    │                                                │
    [paused] budget exhausted, waiting for the human
```

A channel is the unordered pair of pane ids, so both sides share one transcript
and one budget. Panes may be in the same tab, different tabs, or different
workspaces — anything on the same herdr server.

"Delivered" means submitted and verified: herald confirms the peer actually
started working on the message. If the text landed in the prompt but was never
submitted, it says so and exits `3` rather than reporting success.

## Installing

```sh
curl -fsSL https://github.com/budhash/herald/releases/latest/download/install.sh | bash
```

Download and read it first, which is the better habit for anything piped to a shell:

```sh
curl -fsSLO https://github.com/budhash/herald/releases/latest/download/install.sh
less install.sh && bash install.sh
```

Or skip the installer — herald is one file:

```sh
curl -kL https://github.com/budhash/herald/releases/latest/download/herald > herald
chmod +x herald && ./herald skill install
```

Optionally verify the download against its published checksum:

```sh
curl -kLO https://github.com/budhash/herald/releases/latest/download/herald.sha256
shasum -a 256 -c herald.sha256
```

The installer places exactly two things, and `--uninstall` removes exactly those:

| path | what |
|---|---|
| `~/.local/bin/herald` | the CLI |
| `~/.claude/skills/herald/SKILL.md` | the companion agent skill |

### Requirements

- **bash 3.2+** — runs on the bash macOS ships; no bash 4 features
- **[herdr](https://github.com/herdrdev/herdr)** — the multiplexer herald talks through
- **jq**

The installer checks for herdr and jq and reports what is missing, but does not
install them. herdr is a terminal multiplexer whose upgrade can drop live panes,
so pulling it in silently behind a one-liner would be the wrong call.

## Options

| option | applies to | effect |
|---|---|---|
| `--body-file <f>` | `send` | read the message from a file, byte-for-byte |
| `--stdin` | `send` | read the message from stdin |
| `--rounds N` | `open`, `resume` | set or grant N deliveries |
| `--drop` | `resume` | discard a queued message instead of delivering it |
| `--new` | `read` | show only what arrived since you last caught up |
| `--lines N` | `peek` | how much raw peer output to show (default 60) |
| `--dir <d>`, `--force` | `skill` | install the skill elsewhere / overwrite a symlink |

## Commands

| command | what it does |
|---|---|
| `herald ls` | list running agent sessions: pane id · status · working directory |
| `herald open <peer>` | open or reset a channel (a first `send` opens one too) |
| `herald send <peer> …` | record and deliver a message, verifying submission |
| `herald read [<peer>]` | the shared transcript |
| `herald peek <peer>` | the peer's raw recent output, not just what it heralded |
| `herald roster` | every channel: peer · agent status · budget · age · submit state |
| `herald status [<peer>]` | budget left, plus any queued message and its direction |
| `herald nudge <peer>` | re-submit a message left sitting in the peer's prompt (free) |
| `herald resume <peer>` | grant budget and flush queued messages |
| `herald close <peer>` | end and archive a channel |
| `herald skill <sub>` | `install` · `status` · `show` · `uninstall` the agent skill |

## Examples

```sh
herald ls                                  # find your peer's pane id
herald open w2:p3 --rounds 6               # a channel with six deliveries
herald send w2:p3 "ready when you are"
herald send w2:p3 --body-file plan.md      # technical content: no shell expansion
herald read w2:p3                          # what was exchanged
herald roster                              # every channel at a glance
herald resume w2:p3 --rounds 20            # release a pause, grant more
herald close w2:p3
```

Rehearse a send without spending budget or recording anything:

```sh
HERALD_DRYRUN=1 herald send w2:p3 "would this land?"
```

### Exit codes

Branch on these; do not assume success.

| code | meaning | what to do |
|---|---|---|
| `0` | delivered **and** submitted, verified | nothing |
| `1` | failed | read the error |
| `3` | typed into the prompt but **never submitted** | `herald nudge <peer>` — costs no budget |
| `4` | **paused** at budget 0 — nothing delivered | stop; only a human can release it |

## The skill

herald ships an agent skill describing how to use it. The skill is embedded in
the script, so it can be installed or repaired at any time, however herald got
onto the machine:

```sh
herald skill install        # write it to ~/.claude/skills/herald/SKILL.md
herald skill status         # missing · current · STALE
herald skill show           # print it to stdout
herald skill uninstall
```

`install` is idempotent and **refuses to clobber a symlink** — if another tool
owns that path, it says so and stops. `--force` overrides; `--dir` relocates.

## Environment

| variable | effect |
|---|---|
| `HERALD_ROUNDS` | default budget for a new channel (default `6`) |
| `HERALD_STATE` | channel state directory (default `~/.local/state/herald`) |
| `HERALD_SKILL_DIR` | where `herald skill` installs (default `~/.claude/skills/herald`) |
| `HERALD_DRYRUN=1` | rehearse a send: print it, spend no budget, record nothing |
| `HERALD_ME` | override pane auto-detection |
| `HERALD_WAIT_MS` | how long to let a busy peer finish before delivering (default `15000`) |

## Limitations

- **Point-to-point only.** A channel is exactly two panes. No broadcast, no third
  participant, no reply-all.
- **One herdr server.** Pane ids and channel state are local to it. To reach
  another machine's panes, attach to that machine's herdr (`herdr --remote <host>`);
  the panes, and herald, run there.
- **Delivery is a prompt submission, not an API call.** It waits for the peer to be
  idle first, but that wait is best-effort — a wedged peer times out.
- **Messages pass through a shell when given as arguments.** Use `--body-file` or
  `--stdin` for anything containing backticks or `$(…)`.

## Known Issues

- A message recovered by `herald nudge` is still rendered `[TYPED/not submitted]`
  in `herald read`, because the transcript stores each message's own submit state
  while `herald roster` reports the latest known state. The message did arrive;
  the transcript label is stale.

## Why the budget exists

The budget is enforced in the CLI, not by agent goodwill. At zero, the next send
is recorded but not delivered, and only `herald resume` releases it. The pause is
where a human reads the transcript and decides whether to continue.

If you build on top of herald, keep releasing the budget at least as much work as
reading the transcript. A one-tap "grant 20 more" leaves the gate in place but
stops it doing anything.

## Development

```sh
make test          # run the suite (no herdr required; the transport is stubbed)
make lint          # shellcheck
make sync-skill    # re-embed skills/herald/SKILL.md into herald
make ci            # syntax + lint + skill-sync + version + tests
```

The skill's source of truth is `skills/herald/SKILL.md`; `make sync-skill` embeds
it and CI fails if the embedded copy has drifted.

## Authors / Contact
Developed and maintained by [budhash](https://github.com/budhash).

## Download
[Latest release](https://github.com/budhash/herald/releases/latest)
