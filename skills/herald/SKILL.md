---
name: herald
description: Exchange messages directly with a peer agent session in another herdr pane, tab, or workspace, instead of the human relaying between them. Bounded and human-gated. Use when you're collaborating with another running session and want to hand work back and forth.
---

# herald — talking to your peer session

You are one of **two peer agent sessions** collaborating in different herdr panes — which may be in the
same tab, different tabs, or different workspaces. Normally the human relays messages between you; the
`herald` CLI (on `$PATH`) lets you exchange them directly. It is **bounded and human-supervised** — you
cannot run an unbounded back-and-forth, by design.

## How to use it

1. **Find your peer's pane id:** `herald ls` — lists the running agent sessions with their pane id and
   working directory. Your peer is whichever session the human has paired you with.
2. **Send a message:** `herald send <peer-pane> "your message"` — this records it to a shared transcript
   and submits it into the peer's prompt. Example: `herald send w4:p4 "Plan looks good;
   implement step 2 and report the diff."`
   - **For anything technical, use `--body-file` or `--stdin`.** A message passed as an argument is
     expanded by YOUR shell first: backticks and `$(…)` in code identifiers, type signatures or column
     names get command-substituted, and the peer silently receives a corrupted spec. Write the message
     to a file and send `herald send w4:p4 --body-file /tmp/spec.md`, exactly as you would use
     `gh pr create --body-file`.
   - **Check the exit status — branch on it, don't assume success.**
     | code | meaning | what to do |
     |---|---|---|
     | `0` | delivered **and** submitted (verified) | nothing — no confirming `peek` needed |
     | `3` | **typed into the prompt but never submitted** — the peer has NOT seen it | `herald nudge <peer-pane>` (free, no budget) |
     | `4` | **paused** at budget 0 — nothing was delivered | stop; only the human can release it |
     | `1` | failed outright, nothing landed | check `herald roster`; the pane may be gone |
     Exit `3` is common when the peer was **mid-turn**: herald waits ~15s for it to settle, then delivers
     anyway, but will not claim a submission it cannot verify. The text is sitting in their prompt —
     nudge once they settle. Sending to a peer that has been working for minutes is the main way
     messages end up unread.
3. **Receiving:** when a prompt arrives beginning with `[herald ← <pane> · N delivery(ies) left …]`, that
   message is **from your peer session, not the human**. Read it, do the work it asks, and reply with
   `herald send <that-pane> "…"`.

## The rules (respect these)

- **Honor the budget.** The exchange has a shared delivery budget. When `herald` tells you
  **"budget exhausted — paused for human review,"** STOP heralding immediately. Summarize the current
  state for the human and wait. Do **not** try to force more rounds, raise the budget, or find another
  channel — the pause is intentional so the human can steer. They will `herald resume` if they want more.
  If the human has already pre-authorized a work phase with a large ceiling (`herald resume <peer>
  --rounds 20`), the same rule still applies when that ceiling runs out: stop and summarize.
- **One clear ask per message.** Your peer sees only what you send, not your full context or scrollback.
  Make each message self-contained: state what you're delivering or exactly what you need back.
- **A queue is per-author, and you may hold only one.** While your own message is queued, `herald send`
  refuses — a new send would reach the peer *before* the one still waiting. Release it (`herald resume
  <peer>`) or abandon it (`herald resume <peer> --drop`) first.
- **Read `pending` carefully: it names a DIRECTION.** `pending: w4:p4 → w4:p1 undelivered` is the *peer's*
  reply waiting for **you**, not your message waiting for them. A channel queues both ways, and `resume`
  drains every queue to its own recipient. Never conclude "my message never went" from a pending count
  alone — check whose it is.
- **Stay in the role the human gave you**, and don't impersonate the human or speak for them.
- **The human is watching both panes** and may interrupt or redirect at any moment — that's expected.

## What herald CANNOT do (know these before you rely on it)

- **Point-to-point only — it is not a group chat.** A channel is exactly two panes. There is no
  broadcast, no third participant, no "reply all". To involve another session, the human wires it.
- **Both sides must be on the SAME herdr server** (it talks over the local socket). You cannot herald a
  session on another machine, or one running outside herdr.
- **Delivery is a prompt submission, not an API call.** herald submits into the peer's prompt and
  verifies the peer actually started working. It waits for the peer to be idle first, but that wait is
  best-effort — a *wedged* peer just times out. Some agents (notably Codex) can leave a message sitting
  unsubmitted; that is exit 3, not a delivery. Very long messages are slow; keep them tight.
- **Sending is not the same as being understood.** A verified send means the peer *received and started
  processing* the text — not that it agreed, understood, or did the right thing. There is no read
  receipt for comprehension: if it matters, ask for an explicit acknowledgement, or `herald peek`.
- **You cannot raise your own budget.** `herald resume` is the human's lever. If you find yourself
  wanting more rounds, that IS the signal to stop and summarize for them.
- **`peek` shows RAW terminal output**, including UI chrome, spinners and partial lines — it is a
  window, not a clean transcript. `herald read` is the clean record of what was actually heralded.
  **Scrollback carries no timestamp of its own**, so an old report looks exactly like current work.
  peek prints a header with the read time and the peer's live status — trust that, not the content's
  apparent recency, and confirm against real state (git, files) before concluding a peer finished.
- **State is machine-local and unsynced** (`~/.local/state/herald/`), and a `herald close` archives the
  channel — the peer is not notified that you closed it.
- **herald is coupled to herdr's CLI.** A herdr upgrade can break it (0.7.5 changed the output format of
  `agent read`, which silently broke `peek` until it was fixed). If a herald command behaves strangely
  right after a herdr upgrade, say so rather than working around it.
- **The human sees everything and may interrupt at any time.** Nothing here is private or autonomous.

## Handy

- `herald roster` — **the coordinator view.** Every channel you hold in one table: peer, live agent
  status, budget left, how long since the last message, and whether your last send was actually
  submitted. Use this instead of `ls` + a `status` + a `peek` per peer. If you hold channels to more than
  one peer, this is the command to reach for first.
- `herald read <peer-pane>` — the full transcript of what was *heralded* (the messages, both directions).
  `herald read <peer-pane> --new` shows only what arrived since you last caught up.
- `herald peek <peer-pane> [--lines N]` — read the peer's **raw recent output** (its actual work/response,
  not just what it chose to herald). Use this when the roster says something surprising.
- `herald nudge <peer-pane>` — submit a message left sitting in the peer's prompt. Costs no budget.
- `herald status <peer-pane>` — budget left, plus any queued message **and its direction**.
- `herald resume <peer-pane> [--rounds N]` — the human's lever: grants budget and flushes every queued
  message. `--drop` discards them instead. `HERALD_DRYRUN=1 herald resume <peer>` previews exactly what
  would be delivered and changes nothing.

Delivery waits for the peer to be idle before submitting, so you won't clobber a peer that's mid-task.

## Coordinating more than one peer

herald is point-to-point, so if you hold channels to several peers **you are the only shared context** —
no peer can see another's channel. Two consequences worth planning around: never tell a peer to "wait for
the other one" (it has no way to observe that), and when work depends on another peer, carry the fact
across yourself. `herald roster` is what makes that tractable: one glance shows who is working, who is
idle, and where budget is about to run out.
