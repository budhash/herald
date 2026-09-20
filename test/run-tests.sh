#!/bin/bash
# --------------------------------------------------------------------
#
#  run-tests.sh — test suite for herald
#
#  Cases marked "(live-found)" encode bugs that were hit in real use —
#  keep them.
#
#  Transport is stubbed via HERALD_STUB_HERDR so the suite needs no
#  running herdr: state (budget, transcript, queue) advances normally
#  while nothing is typed into a real pane.
#
#  USAGE:  ./test/run-tests.sh
# --------------------------------------------------------------------
set -uo pipefail

cd "$(dirname "$0")" || exit 1
# shellcheck source=.common/test-common
source .common/test-common

NAME="herald"
TOOL="../herald"
HERALD="../herald"

test_herald() {
  _section_header "herald — bounded peer messaging: every verb + the budget cap"
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/herald-XXXXXX")"
  # STUB_HERDR stubs the TRANSPORT only, so budget/transcript state advances without typing into a real
  # pane. (DRYRUN is a rehearsal that must mutate nothing — asserted separately in test_herald_dryrun.)
  local E="HERALD_STATE=$d HERALD_ME=session-a HERALD_STUB_HERDR=1"
  assert_contains "$("$HERALD" --help 2>&1)" "bounded" "help text"
  assert_ok test -x "$HERALD" "herald is executable"

  # open — establishes the channel + budget
  # shellcheck disable=SC2086  # $E is intentional word-split of KEY=VAL pairs for env
  assert_ok env $E "$HERALD" open session-b --rounds 2 "open channel (budget 2)"
  assert_contains "$(env $E "$HERALD" status session-b 2>&1)" "2 delivery" "status reports the opening budget"

  # send — delivers, decrements, and warns on the LAST hop
  assert_contains "$(env $E "$HERALD" send session-b hello 2>&1)" "delivered + submitted to session-b" "send #1 delivers"
  assert_contains "$(env $E "$HERALD" send session-b second 2>&1)" "LAST hop" "send #2 warns it was the last hop"

  # the cap: an over-budget send is RECORDED but NOT delivered
  assert_contains "$(env $E "$HERALD" send session-b third 2>&1)" "budget exhausted" "over-budget send PAUSES (cap enforced)"
  assert_contains "$(env $E "$HERALD" status session-b 2>&1)" "session-a → session-b undelivered" "status shows the paused message + its direction"
  assert_contains "$(env $E "$HERALD" read session-b 2>&1)" "PAUSED" "read marks the undelivered message"
  assert_contains "$(env $E "$HERALD" read session-b 2>&1)" "hello" "read shows the delivered transcript too"

  # resume — grants budget AND flushes the held message
  assert_contains "$(env $E "$HERALD" resume session-b --rounds 2 2>&1)" "flushed the paused session-a → session-b message" "resume flushes pending + grants budget"
  assert_eq 0 "$(env $E "$HERALD" status session-b 2>&1 | grep -c 'pending:' || true)" "no pending message after resume"

  # peek — reads the peer's RAW output; must never inject
  assert_contains "$(env $E "$HERALD" peek session-b --lines 30 2>&1)" "STUB peek" "peek is read-only (no inject)"

  # ls — enumerates candidate peers (stubbed: must not die without herdr)
  assert_ok env $E "$HERALD" ls "ls runs"

  # close — archives the channel; a closed channel is gone
  assert_ok env $E "$HERALD" close session-b "close archives the channel"
  assert_contains "$(env $E "$HERALD" status session-b 2>&1)" "no channel" "closed channel reports no channel"

  # guards
  assert_fail env $E "$HERALD" send "" "send with no peer fails"
  assert_fail env $E "$HERALD" send session-b "send with an empty message fails"
  assert_fail env $E "$HERALD" bogus-verb "unknown verb fails"
  rm -rf "$d"
}

test_herald_failed_delivery() {
  _section_header "herald — a FAILED delivery spends no budget and is not recorded delivered (live-found)"
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/herald-fail-XXXXXX")"
  local OK="HERALD_STATE=$d HERALD_ME=session-a HERALD_STUB_HERDR=1"
  local FAIL="HERALD_STATE=$d HERALD_ME=session-a HERALD_STUB_HERDR=fail"
  # shellcheck disable=SC2086
  env $OK "$HERALD" open session-b --rounds 3 >/dev/null 2>&1
  # a send whose transport fails (dead pane / herdr down) must NOT look like a delivery
  assert_fail env $FAIL "$HERALD" send session-b "into the void" "failed delivery exits nonzero"
  assert_contains "$(env $FAIL "$HERALD" send session-b 'into the void' 2>&1)" "budget untouched" "failure says the budget was not spent"
  assert_contains "$(env $OK "$HERALD" status session-b 2>&1)" "3 delivery" "budget still 3 after failed sends"
  # a failure is NOT a budget pause: nothing is queued for resume, and read must say so distinctly
  assert_eq 0 "$(env $OK "$HERALD" read session-b 2>&1 | grep -c 'PAUSED' || true)" "a failed send is not labelled PAUSED (nothing to resume)"
  assert_contains "$(env $OK "$HERALD" read session-b 2>&1)" "FAILED/not sent" "read labels the failed send distinctly"
  assert_eq 0 "$(env $OK "$HERALD" status session-b 2>&1 | grep -c 'pending:' || true)" "a failed send queues nothing for resume"
  # ...and a subsequent GOOD send still works normally
  assert_contains "$(env $OK "$HERALD" send session-b 'real one' 2>&1)" "delivered + submitted to session-b" "channel still usable after a failure"
  rm -rf "$d"
}

test_herald_peek_formats() {
  _section_header "herald — peek handles BOTH herdr output formats (0.7.5 plain text + JSON envelope)"
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/herald-peek-XXXXXX")"
  local fake; fake="$(mktemp -d "${TMPDIR:-/tmp}/fakeherdr-XXXXXX")"
  # herdr 0.7.5 returns PLAIN TEXT from `agent read --format text`; older builds wrapped it in JSON.
  # Piping plain text through jq silently produced nothing and made peek look broken (found live).
  cat > "$fake/herdr" <<'EOF'
#!/usr/bin/env bash
case "$HERALD_FAKE_MODE" in
  json) printf '{"result":{"read":{"text":"JSON-WRAPPED-OUTPUT"}}}\n' ;;
  *)    printf 'PLAIN-TEXT-OUTPUT\n' ;;
esac
exit 0
EOF
  chmod +x "$fake/herdr"
  local E="HERALD_STATE=$d HERALD_ME=session-a"
  assert_contains "$(PATH="$fake:$PATH" env $E HERALD_FAKE_MODE=text "$HERALD" peek session-b 2>&1)" "PLAIN-TEXT-OUTPUT" "0.7.5 plain-text output is shown"
  assert_contains "$(PATH="$fake:$PATH" env $E HERALD_FAKE_MODE=json "$HERALD" peek session-b 2>&1)" "JSON-WRAPPED-OUTPUT" "JSON-enveloped output is unwrapped"
  rm -rf "$d" "$fake"
}

test_herald_dryrun_is_free() {
  _section_header "herald — DRYRUN is a rehearsal: previews delivery, spends NO budget (regression)"
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/herald-dry-XXXXXX")"
  local E="HERALD_STATE=$d HERALD_ME=session-a HERALD_DRYRUN=1"
  # shellcheck disable=SC2086
  env $E "$HERALD" open session-b --rounds 3 >/dev/null 2>&1
  local out; out=$(env $E "$HERALD" send session-b "rehearse" 2>&1)
  assert_contains "$out" "DRYRUN deliver" "dryrun previews the exact delivery"
  assert_contains "$out" "budget untouched" "dryrun says it spent nothing"
  env $E "$HERALD" send session-b "rehearse again" >/dev/null 2>&1
  # THE regression: a live shakedown found dryrun silently burning real deliveries
  assert_contains "$(env $E "$HERALD" status session-b 2>&1)" "3 delivery" "budget still 3 after two dryruns"
  assert_eq 0 "$(env $E "$HERALD" read session-b 2>&1 | grep -c 'rehearse' || true)" "dryrun writes no transcript row"
  rm -rf "$d"
}

test_herald_shell_safe_body() {
  _section_header "herald — --body-file/--stdin carry text the shell would otherwise mangle (live-found)"
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/herald-body-XXXXXX")"
  local E="HERALD_STATE=$d HERALD_ME=session-a HERALD_STUB_HERDR=1"
  # shellcheck disable=SC2086
  env $E "$HERALD" open session-b --rounds 5 >/dev/null 2>&1
  # THE regression: backticks in a technical directive were command-substituted by the CALLER's zsh,
  # so the peer silently received a corrupted spec. A file/stdin body never touches a shell.
  local tricky='constraint: str | tuple[`x`] and $(whoami) and `id`'
  printf '%s\n' "$tricky" > "$d/body.txt"
  env $E "$HERALD" send session-b --body-file "$d/body.txt" >/dev/null 2>&1
  assert_contains "$(env $E "$HERALD" read session-b 2>&1)" 'tuple[`x`]' "backticks survive --body-file verbatim"
  assert_contains "$(env $E "$HERALD" read session-b 2>&1)" '$(whoami)' "command substitution is NOT expanded"
  printf '%s\n' "$tricky" | env $E "$HERALD" send session-b --stdin >/dev/null 2>&1
  assert_eq 2 "$(env $E "$HERALD" read session-b 2>&1 | grep -c 'tuple' || true)" "--stdin carries the same bytes"
  # a missing body file must fail loudly rather than send an empty message
  assert_fail env $E "$HERALD" send session-b --body-file "$d/nope.txt" "--body-file on a missing path fails"
  rm -rf "$d"
}

test_herald_submit_verify() {
  _section_header "herald — 'delivered' means SUBMITTED; a typed-but-unsubmitted send says so (live-found)"
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/herald-submit-XXXXXX")"
  local OK="HERALD_STATE=$d HERALD_ME=session-a HERALD_STUB_HERDR=1"
  local STALL="HERALD_STATE=$d HERALD_ME=session-a HERALD_STUB_HERDR=stalled"
  # shellcheck disable=SC2086
  env $OK "$HERALD" open session-b --rounds 4 >/dev/null 2>&1
  assert_contains "$(env $OK "$HERALD" send session-b 'clean' 2>&1)" "delivered + submitted" "a verified send says submitted"
  # THE regression: herald reported a green "delivered" when the text merely sat in the peer's prompt,
  # so every send needed a manual peek to trust. A stall is now a DISTINCT outcome (exit 3).
  local out; out=$(env $STALL "$HERALD" send session-b 'stuck' 2>&1 || true)
  assert_contains "$out" "TYPED but NOT SUBMITTED" "a stalled submission is not reported as delivered"
  assert_fail env $STALL "$HERALD" send session-b 'stuck again' "a stalled send exits nonzero"
  assert_contains "$(env $OK "$HERALD" read session-b 2>&1)" "TYPED/not submitted" "read labels the unsubmitted message"
  # the text DID land, so the budget is spent — a re-send would append to an already-populated prompt
  assert_contains "$(env $OK "$HERALD" status session-b 2>&1)" "1 delivery" "a typed-only send still spends budget (text landed)"
  rm -rf "$d"
}

test_herald_nudge() {
  _section_header "herald — nudge re-submits a stuck prompt and costs no budget"
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/herald-nudge-XXXXXX")"
  local OK="HERALD_STATE=$d HERALD_ME=session-a HERALD_STUB_HERDR=1"
  local STALL="HERALD_STATE=$d HERALD_ME=session-a HERALD_STUB_HERDR=stalled"
  # shellcheck disable=SC2086
  env $OK "$HERALD" open session-b --rounds 3 >/dev/null 2>&1
  env $STALL "$HERALD" send session-b 'stuck' >/dev/null 2>&1 || true
  assert_contains "$(env $OK "$HERALD" roster 2>&1)" "TYPED-ONLY" "roster flags the unsubmitted message"
  assert_contains "$(env $OK "$HERALD" nudge session-b 2>&1)" "now working" "a successful nudge reports submission"
  assert_contains "$(env $OK "$HERALD" roster 2>&1)" "ok" "roster clears once the nudge lands"
  assert_contains "$(env $OK "$HERALD" status session-b 2>&1)" "2 delivery" "nudge spends NO budget"
  # some agents ignore a bare Enter — that must be reported, not silently claimed as success
  assert_fail env $STALL "$HERALD" nudge session-b "a nudge that does not take exits nonzero"
  rm -rf "$d"
}

test_herald_resume_flush() {
  _section_header "herald — resume flushes or EXPLAINS; it must never die silently mid-flush (live-found)"
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/herald-res-XXXXXX")"
  local OK="HERALD_STATE=$d HERALD_ME=session-a HERALD_STUB_HERDR=1"
  local FAIL="HERALD_STATE=$d HERALD_ME=session-a HERALD_STUB_HERDR=fail"
  local STALL="HERALD_STATE=$d HERALD_ME=session-a HERALD_STUB_HERDR=stalled"
  # shellcheck disable=SC2086
  env $OK "$HERALD" open session-b --rounds 1 >/dev/null 2>&1
  env $OK "$HERALD" send session-b 'burn it' >/dev/null 2>&1
  env $OK "$HERALD" send session-b 'queued' >/dev/null 2>&1 || true   # budget 0 -> queued as pending
  assert_contains "$(env $OK "$HERALD" status session-b 2>&1)" "session-a → session-b undelivered" "a message is queued at budget 0"
  # THE regression: `_deliver` was called BARE, so set -e killed resume before it wrote the budget or
  # cleared the queue — the channel stayed stuck on "run herald resume to flush" and resume said nothing.
  local out; out=$(env $FAIL "$HERALD" resume session-b 2>&1 || true)
  assert_contains "$out" "FAILED — kept queued for a retry" "a failed flush EXPLAINS itself"
  assert_contains "$out" "0 of 1 flushed" "a failed flush reports it drained nothing"
  assert_contains "$(env $OK "$HERALD" status session-b 2>&1)" "undelivered" "the message stays queued after a failed flush"
  assert_contains "$(env $OK "$HERALD" status session-b 2>&1)" "undelivered" "the queued message survives a failed flush (retryable)"
  # a stall means the text DID reach the prompt: the queue must clear or resume would re-deliver it
  assert_fail env $STALL "$HERALD" resume session-b "a stalled flush exits nonzero"
  assert_eq 0 "$(env $OK "$HERALD" status session-b 2>&1 | grep -c 'pending:' || true)" "a stalled flush still clears the queue (no double-send)"
  # and the happy path still works — drive the channel back to budget 0 so the next send is queued
  env $OK "$HERALD" resume session-b --rounds 1 >/dev/null 2>&1
  env $OK "$HERALD" send session-b 'burn again' >/dev/null 2>&1
  env $OK "$HERALD" send session-b 'again' >/dev/null 2>&1 || true
  assert_contains "$(env $OK "$HERALD" status session-b 2>&1)" "undelivered" "channel is queued again"
  assert_contains "$(env $OK "$HERALD" resume session-b --rounds 3 2>&1)" "flushed the paused session-a → session-b message" "a healthy flush still flushes"
  rm -rf "$d"
}

test_herald_bidirectional_queue() {
  _section_header "herald — a channel queues BOTH directions; resume drains each to its own recipient (live-found)"
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/herald-bi-XXXXXX")"
  export HERALD_STATE="$d" HERALD_STUB_HERDR=1
  HERALD_ME=side-a "$HERALD" open side-b --rounds 1 >/dev/null 2>&1
  HERALD_ME=side-a "$HERALD" send side-b 'burn' >/dev/null 2>&1
  HERALD_ME=side-a "$HERALD" send side-b 'A-QUEUED' >/dev/null 2>&1 || true
  HERALD_ME=side-b  "$HERALD" send side-a 'B-QUEUED'  >/dev/null 2>&1 || true
  # THE regression: ONE `pending` slot served both directions, so the second author silently overwrote
  # the first — and resume then fired whichever survived, in whichever direction, stamped with the
  # RESUMER's name. One side releasing its own message could shoot the peer's reply into its own pane.
  assert_ok test -f "$d"/*/pending.side-a "side A's queued message survives"
  assert_ok test -f "$d"/*/pending.side-b  "side B's queued message survives (not clobbered)"
  # direction must be visible: "pending: 1" read as "MY message is waiting" when it was the peer's reply
  local st; st=$(HERALD_ME=side-a "$HERALD" status side-b 2>&1)
  assert_contains "$st" "side-a → side-b undelivered" "status names the outbound queued message"
  assert_contains "$st" "side-b → side-a undelivered" "status names the inbound queued message"
  assert_contains "$(HERALD_ME=side-a "$HERALD" roster 2>&1)" "PAUSED:2" "roster counts every queued message"
  local out; out=$(HERALD_ME=side-a "$HERALD" resume side-b --rounds 4 2>&1)
  assert_contains "$out" "flushed the paused side-a → side-b message" "the outbound message goes to side B"
  assert_contains "$out" "flushed the paused side-b → side-a message" "the inbound message goes to side A"
  assert_contains "$out" "2 of 2 flushed" "resume reports what it drained"
  assert_eq 0 "$(ls "$d"/*/ | grep -c pending || true)" "every queue is cleared"
  # budget accounting: 4 granted minus 2 flushed
  assert_contains "$(HERALD_ME=side-a "$HERALD" status side-b 2>&1)" "2 delivery" "each flush spends one delivery"
  unset HERALD_STATE HERALD_STUB_HERDR
  rm -rf "$d"
}

test_herald_flush_order() {
  _section_header "herald — queues flush OLDEST FIRST, not in glob order (live-found)"
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/herald-ord-XXXXXX")"
  export HERALD_STATE="$d" HERALD_STUB_HERDR=1
  HERALD_ME=agent "$HERALD" open codex --rounds 1 >/dev/null 2>&1
  HERALD_ME=agent "$HERALD" send codex 'burn' >/dev/null 2>&1
  # THE regression: order was the alphabetical accident of the glob, so with `agent` < `codex` the
  # later dispatch was delivered BEFORE the peer's earlier reply — meaning you acted on a
  # message you had not read yet. Whether that happened depended on your pane id, which is absurd.
  HERALD_ME=codex "$HERALD" send agent 'written FIRST' >/dev/null 2>&1 || true
  touch -t 202608030120 "$d"/*/pending.codex
  HERALD_ME=agent "$HERALD" send codex 'written SECOND' >/dev/null 2>&1 || true
  touch -t 202608030150 "$d"/*/pending.agent
  local out; out=$(HERALD_ME=agent "$HERALD" resume codex --rounds 4 2>&1)
  local first; first=$(printf '%s\n' "$out" | grep -o 'paused [a-z]* →' | head -1)
  assert_contains "$first" "codex" "the message written FIRST is flushed first, despite sorting later"
  # Reverse the write order: if mtime really drives it, the other side must now go first. Without this
  # the assertion above would also pass for a rule of "always inbound first", which is not the rule.
  HERALD_ME=agent  "$HERALD" resume codex --rounds 1 >/dev/null 2>&1
  HERALD_ME=agent  "$HERALD" send codex 'agent wrote first' >/dev/null 2>&1
  HERALD_ME=agent  "$HERALD" send codex 'agent queued' >/dev/null 2>&1 || true
  touch -t 202608030120 "$d"/*/pending.agent
  HERALD_ME=codex "$HERALD" send agent 'codex queued later' >/dev/null 2>&1 || true
  touch -t 202608030150 "$d"/*/pending.codex
  out=$(HERALD_ME=agent "$HERALD" resume codex --rounds 4 2>&1)
  first=$(printf '%s\n' "$out" | grep -o 'paused [a-z]* →' | head -1)
  assert_contains "$first" "agent" "reversing the write order reverses the flush order (mtime drives it)"
  unset HERALD_STATE HERALD_STUB_HERDR
  rm -rf "$d"
}

test_herald_flush_attribution() {
  _section_header "herald — a flushed message is attributed to its AUTHOR, not to whoever resumed it"
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/herald-attr-XXXXXX")"
  export HERALD_STATE="$d"
  HERALD_STUB_HERDR=1 HERALD_ME=side-a "$HERALD" open side-b --rounds 1 >/dev/null 2>&1
  HERALD_STUB_HERDR=1 HERALD_ME=side-a "$HERALD" send side-b 'burn' >/dev/null 2>&1
  HERALD_STUB_HERDR=1 HERALD_ME=side-b  "$HERALD" send side-a 'reply from side B' >/dev/null 2>&1 || true
  # DRYRUN prints the exact delivery, so it shows the header the peer would actually see.
  local out; out=$(HERALD_DRYRUN=1 HERALD_ME=side-a "$HERALD" resume side-b 2>&1)
  assert_contains "$out" "herald ← side-b" "the header credits side B, who wrote it"
  assert_eq 0 "$(printf '%s' "$out" | grep -c 'herald ← side-a' || true)" "it is NOT stamped with the resumer's name"
  assert_contains "$out" "side-b → side-a" "the preview names the direction"
  # and the rehearsal still consumed nothing
  assert_ok test -f "$d"/*/pending.side-b "DRYRUN leaves the queue intact"
  unset HERALD_STATE
  rm -rf "$d"
}

test_herald_resume_guards() {
  _section_header "herald — resume: DRYRUN must not consume the queue; --drop discards; identity errors are honest"
  local d fake; d="$(mktemp -d "${TMPDIR:-/tmp}/herald-rg-XXXXXX")"; fake="$(mktemp -d "${TMPDIR:-/tmp}/fakeh2-XXXXXX")"
  local OK="HERALD_STATE=$d HERALD_ME=session-a HERALD_STUB_HERDR=1"
  # shellcheck disable=SC2086
  env $OK "$HERALD" open session-b --rounds 1 >/dev/null 2>&1
  env $OK "$HERALD" send session-b 'burn' >/dev/null 2>&1
  env $OK "$HERALD" send session-b 'precious' >/dev/null 2>&1 || true
  # THE regression: DRYRUN fell through to the flush path, whose _deliver returns 0 under DRYRUN — so
  # rehearsing a resume cleared `pending` and spent budget, DESTROYING the message it was previewing.
  env $OK HERALD_DRYRUN=1 "$HERALD" resume session-b >/dev/null 2>&1
  assert_contains "$(env $OK "$HERALD" status session-b 2>&1)" "undelivered" "DRYRUN resume does NOT consume the queued message"
  assert_contains "$(env $OK "$HERALD" status session-b 2>&1)" "0 delivery" "DRYRUN resume does NOT grant budget"
  # --drop is the escape hatch for a message that can never be delivered
  assert_contains "$(env $OK "$HERALD" resume session-b --drop 2>&1)" "DROPPED" "--drop discards the queued message"
  assert_eq 0 "$(env $OK "$HERALD" status session-b 2>&1 | grep -c 'pending:' || true)" "--drop clears the queue"
  # identity: a channel is keyed by BOTH panes, so an undetectable pane id must say THAT, not "open one first"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fake/herdr"; chmod +x "$fake/herdr"
  assert_contains "$(PATH="$fake:$PATH" HERALD_STATE=$d "$HERALD" resume session-b 2>&1 || true)" \
    "cannot detect my herdr pane id" "an undetectable pane id names the real cause"
  rm -rf "$d" "$fake"
}

test_herald_no_duplicate_queue() {
  _section_header "herald — at budget 0 a SECOND send is refused, not queued as a duplicate (live-found)"
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/herald-dup-XXXXXX")"
  local E="HERALD_STATE=$d HERALD_ME=session-a HERALD_STUB_HERDR=1"
  # shellcheck disable=SC2086
  env $E "$HERALD" open session-b --rounds 1 >/dev/null 2>&1
  env $E "$HERALD" send session-b 'burn' >/dev/null 2>&1
  # the FIRST at-zero send is the pause itself: recorded, queued, and NONZERO so it cannot read as sent
  assert_fail env $E "$HERALD" send session-b 'first' "an at-zero send exits nonzero (it was not delivered)"
  local n; n=$(grep -c . "$d"/*/messages.jsonl 2>/dev/null || echo 0)
  # THE regression: retries appended another transcript row and overwrote the queue each time, so
  # undelivered near-duplicates piled up to be flushed together later, out of order.
  env $E "$HERALD" send session-b 'retry' >/dev/null 2>&1 || true
  env $E "$HERALD" send session-b 'retry again' >/dev/null 2>&1 || true
  assert_eq "$n" "$(grep -c . "$d"/*/messages.jsonl 2>/dev/null || echo 0)" "retries at budget 0 append NO duplicate rows"
  assert_contains "$(env $E "$HERALD" send session-b 'retry3' 2>&1 || true)" "refusing to queue or send another" "a retry is refused with a reason"
  rm -rf "$d"
}

test_herald_submit_fallback() {
  _section_header "herald — a stalled submit auto-presses Enter; send stays BOUNDED (live-found)"
  local d fake; d="$(mktemp -d "${TMPDIR:-/tmp}/herald-fb-XXXXXX")"; fake="$(mktemp -d "${TMPDIR:-/tmp}/fakeh-XXXXXX")"
  # `agent prompt` types the text but does NOT reliably submit — the user still had to press Enter by
  # hand. This fake reproduces that exact herdr behaviour so the auto-recovery stays covered.
  cat > "$fake/herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "agent wait")
    case "$*" in
      *"--until working"*) [ "$FAKE_ENTER" = "takes" ] && exit 0
                           echo '{"error":{"code":"timeout"}}'; exit 1 ;;
      *) exit 0 ;;                       # the SETTLED wait must return at once (idle|done|blocked)
    esac ;;
  "agent prompt")   echo '{"error":{"code":"agent_prompt_stalled","message":"stalled"}}'; exit 1 ;;
  "agent send-keys") exit 0 ;;
  "agent list")
    # FAKE_ENTER=seq: the agent finished so fast that --until working missed it, but the state
    # counter still moved — the secondary check that stops us crying wolf on a quick peer.
    n=1; if [ "$FAKE_ENTER" = "seq" ]; then n=$(( $(cat "$FAKE_SEQF" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_SEQF"; fi
    printf '{"result":{"agents":[{"pane_id":"session-b","agent_status":"done","state_change_seq":%s}]}}\n' "$n" ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$fake/herdr"
  local E="HERALD_STATE=$d HERALD_ME=session-a FAKE_SEQF=$fake/seq"
  # shellcheck disable=SC2086
  PATH="$fake:$PATH" env $E FAKE_ENTER=takes "$HERALD" open session-b --rounds 6 >/dev/null 2>&1
  # THE regression: herald must submit it itself rather than telling the human to send-keys Enter
  local out; out=$(PATH="$fake:$PATH" env $E FAKE_ENTER=takes "$HERALD" send session-b 'auto' 2>&1)
  assert_contains "$out" "delivered + submitted" "a stalled prompt is rescued by the Enter fallback"
  # a fast peer that settles again before the check: the state counter still proves it ran
  assert_contains "$(PATH="$fake:$PATH" env $E FAKE_ENTER=seq "$HERALD" send session-b 'fast' 2>&1)" \
    "delivered + submitted" "a state-counter change also confirms submission"
  # and when Enter genuinely does not take, say so — do not claim delivery
  assert_fail env PATH="$fake:$PATH" $E FAKE_ENTER=no "$HERALD" send session-b 'stuck' "an unrecoverable stall still exits nonzero"
  assert_contains "$(PATH="$fake:$PATH" env $E FAKE_ENTER=no "$HERALD" send session-b 'stuck2' 2>&1)" \
    "TYPED but NOT SUBMITTED" "an unrecoverable stall is reported honestly"
  rm -rf "$d" "$fake"
}

test_herald_bounded_wait() {
  _section_header "herald — the settle-wait uses idle|done|blocked, never --until idle (hang regression)"
  # THE regression: `--until idle` blocked for the FULL timeout because a Claude session that finished a
  # turn sits in `done`, not `idle` — a 120s hang that tripped the caller's command timeout. The broken
  # 0.7.5 flag name (`--status`) had been hiding the wrong predicate underneath it.
  # match CODE only — the comment above the call deliberately names the wrong predicate to explain it
  assert_eq 0 "$(grep -v '^[[:space:]]*#' "$HERALD" | grep -c -- '--until idle' || true)" \
    "no --until idle in executable code (only in the comment that explains it)"
  assert_contains "$(grep -A1 'agent wait' "$HERALD" | head -40)" 'HERALD_WAIT_MS' "the settle-wait is bounded by HERALD_WAIT_MS"
  # a foreground command must not default to a two-minute block
  local def; def=$(grep -oE 'HERALD_WAIT_MS:-[0-9]+' "$HERALD" | head -1 | sed 's/.*-//')
  assert_ok test "$def" -le 30000 "default settle-wait is <=30s (was 120s: read as a hang)"
}

test_herald_roster_and_new() {
  _section_header "herald — roster is the coordinator view; read --new shows only what arrived since"
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/herald-roster-XXXXXX")"
  local E="HERALD_STATE=$d HERALD_ME=session-a HERALD_STUB_HERDR=1"
  # shellcheck disable=SC2086
  assert_contains "$(env $E "$HERALD" roster 2>&1)" "no open channels" "roster is honest when there is nothing to show"
  env $E "$HERALD" open session-b --rounds 5 >/dev/null 2>&1
  env $E "$HERALD" open codexpane --rounds 5 >/dev/null 2>&1
  local r; r=$(env $E "$HERALD" roster 2>&1)
  assert_contains "$r" "session-b" "roster lists the first channel"
  assert_contains "$r" "codexpane" "roster lists the second channel (3-agent topology)"
  assert_contains "$r" "BUDGET" "roster shows a budget column"
  # --new was advertised in the usage text but parsed and never used; it is now real
  env $E "$HERALD" send session-b 'one' >/dev/null 2>&1
  assert_contains "$(env $E "$HERALD" read session-b --new 2>&1)" "one" "read --new shows the unread message"
  assert_eq 0 "$(env $E "$HERALD" read session-b --new 2>&1 | grep -c 'one' || true)" "read --new is empty once caught up"
  env $E "$HERALD" send session-b 'two' >/dev/null 2>&1
  assert_contains "$(env $E "$HERALD" read session-b --new 2>&1)" "two" "read --new picks up the next message"
  assert_contains "$(env $E "$HERALD" read session-b 2>&1)" "one" "a plain read still shows the whole transcript"
  # a closed channel must leave the roster
  env $E "$HERALD" close codexpane >/dev/null 2>&1
  assert_eq 0 "$(env $E "$HERALD" roster 2>&1 | grep -c 'codexpane' || true)" "closed channels drop off the roster"
  rm -rf "$d"
}

test_version() {
  _section_header "herald — --version, and it agrees with version.txt"
  assert_contains "$("$HERALD" --version 2>&1)" "herald " "--version prints a version"
  assert_eq "$("$HERALD" --version)" "$("$HERALD" -v)" "-v is the same as --version"
  assert_eq "$("$HERALD" --version)" "$("$HERALD" version)" "bare 'version' verb works too"
  assert_eq "herald $(cat ../version.txt)" "$("$HERALD" --version)" "script version matches version.txt"
  assert_ok "$HERALD" --version "--version exits 0"
}

test_skill_embedded() {
  _section_header "herald — the skill is EMBEDDED, so a bare script is self-sufficient"
  assert_contains "$("$HERALD" skill show 2>&1)" "name: herald" "skill show emits the frontmatter"
  assert_eq 0 "$("$HERALD" skill show | diff -q - ../skills/herald/SKILL.md >/dev/null; echo $?)" \
    "embedded copy is byte-identical to skills/herald/SKILL.md"
  # the whole point: no sibling files needed
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/heraldskill-XXXXXX")"
  cp ../herald "$d/herald"
  assert_contains "$("$d/herald" skill show 2>&1)" "name: herald" "a herald copied ALONE still has its skill"
  rm -rf "$d"
}

test_skill_lifecycle() {
  _section_header "herald skill — install/status/uninstall are idempotent and detect drift"
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/heraldsk-XXXXXX")"
  assert_fail "$HERALD" skill status --dir "$d/s" "status on a missing skill exits nonzero"
  assert_contains "$("$HERALD" skill status --dir "$d/s" 2>&1)" "missing" "…and says missing"
  assert_ok "$HERALD" skill install --dir "$d/s" "install writes the skill"
  assert_file_exists "$d/s/SKILL.md" "SKILL.md landed"
  assert_ok "$HERALD" skill status --dir "$d/s" "status is clean after install"
  assert_contains "$("$HERALD" skill install --dir "$d/s" 2>&1)" "already current" "re-install is idempotent"

  printf 'drift\n' >> "$d/s/SKILL.md"
  assert_fail "$HERALD" skill status --dir "$d/s" "a drifted skill exits nonzero"
  assert_contains "$("$HERALD" skill status --dir "$d/s" 2>&1)" "STALE" "…and is reported STALE"
  assert_ok "$HERALD" skill install --dir "$d/s" "install repairs a drifted skill"
  assert_ok "$HERALD" skill status --dir "$d/s" "…and it is current again"

  assert_ok "$HERALD" skill uninstall --dir "$d/s" "uninstall removes it"
  assert_fail test -f "$d/s/SKILL.md" "SKILL.md is gone"
  assert_fail "$HERALD" skill bogus --dir "$d/s" "an unknown subcommand fails"
  rm -rf "$d"
}

test_skill_symlink_guard() {
  _section_header "herald skill — never clobbers a SYMLINK that another tool manages"
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/heraldsym-XXXXXX")"
  mkdir -p "$d/l"
  printf 'someone elses content\n' > "$d/target.md"
  ln -s "$d/target.md" "$d/l/SKILL.md"

  assert_fail "$HERALD" skill install --dir "$d/l" "refuses to overwrite a differing symlink"
  assert_contains "$("$HERALD" skill install --dir "$d/l" 2>&1)" "SYMLINK" "…and says why"
  assert_contains "$(cat "$d/target.md")" "someone elses content" "the symlink TARGET is untouched"
  assert_contains "$("$HERALD" skill status --dir "$d/l" 2>&1)" "symlink" "status reports it as a symlink"
  assert_ok "$HERALD" skill install --dir "$d/l" --force "--force overrides the guard"
  rm -rf "$d"
}

test_installer() {
  _section_header "install.sh — valid, honest in --dry-run, and a full install/uninstall round-trip"
  assert_ok bash -n ../install.sh "install.sh is syntactically valid"
  assert_contains "$(bash ../install.sh --help 2>&1)" "install herald" "--help explains itself"
  assert_fail bash ../install.sh --bogus-flag "an unknown flag fails loudly"

  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/heraldinst-XXXXXX")"
  # dry-run must not create anything
  HERALD_SKILL_DIR="$d/sk" bash ../install.sh --dry-run --prefix "$d/bin" >/dev/null 2>&1
  assert_fail test -e "$d/bin/herald" "--dry-run installed NOTHING"

  HERALD_SKILL_DIR="$d/sk" bash ../install.sh --prefix "$d/bin" >/dev/null 2>&1
  assert_file_exists "$d/bin/herald" "install placed the CLI"
  assert_file_exists "$d/sk/SKILL.md" "install placed the skill (via herald skill install)"
  assert_ok test -x "$d/bin/herald" "installed CLI is executable"
  assert_eq "$("$HERALD" --version)" "$("$d/bin/herald" --version)" "installed copy reports the same version"

  HERALD_SKILL_DIR="$d/sk" bash ../install.sh --uninstall --prefix "$d/bin" >/dev/null 2>&1
  assert_fail test -e "$d/bin/herald" "uninstall removed the CLI"
  assert_fail test -e "$d/sk/SKILL.md" "uninstall removed the skill"
  rm -rf "$d"
}

test_works_without_herdr() {
  _section_header "herald — offline verbs work with NO herdr installed (CI-found)"
  # herdr may legitimately not be installed yet: brew can install herald first, and
  # `herald skill install` is exactly what you want to run before herdr exists. Only the verbs that
  # actually use the transport may demand it. This is what broke the first public CI run.
  local bin; bin="$(mktemp -d "${TMPDIR:-/tmp}/heraldnodep-XXXXXX")"
  local t
  for t in bash sh env cat diff grep sed awk tr cut mktemp rm rmdir mkdir mv ln chmod cmp readlink dirname head printf; do
    local src; src="$(command -v "$t" 2>/dev/null)" && ln -sf "$src" "$bin/$t"
  done
  # sanity: the stub PATH really has no herdr
  assert_fail env -i PATH="$bin" command -v herdr "the sandbox PATH has no herdr"

  assert_contains "$(env -i PATH="$bin" HOME="$bin" "$PWD/$HERALD" --version 2>&1)" "herald " \
    "--version works without herdr"
  assert_contains "$(env -i PATH="$bin" HOME="$bin" "$PWD/$HERALD" --help 2>&1)" "herald" \
    "--help works without herdr"
  assert_contains "$(env -i PATH="$bin" HOME="$bin" "$PWD/$HERALD" skill show 2>&1)" "name: herald" \
    "skill show works without herdr"
  assert_ok env -i PATH="$bin" HOME="$bin" "$PWD/$HERALD" skill install --dir "$bin/sk" \
    "skill install works without herdr"

  # …but a transport verb must still refuse, loudly
  assert_contains "$(env -i PATH="$bin" HOME="$bin" "$PWD/$HERALD" ls 2>&1)" "needs 'herdr'" \
    "a transport verb still demands herdr"
  rm -rf "$bin"
}

test_no_stale_framing() {
  _section_header "herald — user-facing text carries no stale or tool-specific framing"
  local help; help="$("$HERALD" --help 2>&1)"
  assert_eq 0 "$(printf '%s' "$help" | grep -ci 'claude session' || true)" \
    "--help does not describe peers as a specific vendor's sessions"
  assert_contains "$help" "agent sessions" "--help uses the generic framing"
}

_test_runner
