# Fork divergences

This fork runs its own Firstmate rather than tracking `kunchenguid/firstmate` exactly.
Most of what it carries is work that upstream simply does not have yet, and that needs no register: an ordinary merge brings it along.

This file is for the narrower and more dangerous set: the points where this fork's behavior deliberately CONTRADICTS upstream's, so a later merge from upstream will re-create the conflict.
Each entry exists so the next person merging can tell a deliberate choice from an accident.
Without it, both entries below read as bugs, and restoring upstream's version looks like a cleanup.

The authoritative statement of each divergence is the `FORK DIVERGENCE` comment at the code site itself, because that is what a merge actually puts in front of someone.
This file is the index, and the reasoning that did not belong in a function comment.

## How to treat an entry when merging from upstream

Keep this fork's side unless the divergence is being revisited on purpose.
If upstream's version starts looking preferable, the decision record named in the entry is where that conversation starts: it quotes both sides as they stood when the choice was made.
Add an entry here whenever a merge resolution deliberately keeps this fork's behavior over upstream's, and remove one only when the divergence genuinely ends.

## 1. The Lavish poll falls back to the registered port

Site: `bin/fm-procevent-lavish.sh`, `apply_session_host` and its call in `cmd_poll`.
Decided 2026-09-26.
Record: `data/fm-reconcile-main-with-upstream/decision-lavish-poll-session-vs-registered-port.md` (private).

Upstream resolves the board's host and port from Lavish's own session store before every poll attempt, and STOPS when that session is missing or unreadable, so that an ambient or configured address can never retarget a reply.

This fork treats that lookup as advisory.
A readable session still wins and still cannot be retargeted, but an absent one leaves in place the port the registration carries.

The reason is that a registered listener has to keep working with no home and no saved session, because that is exactly the state the watcher relaunches one into.
That guarantee is what `--port` in the registered argv exists for, and `tests/fm-lavish-port.test.sh` asserts it directly.
Upstream's stop makes that case impossible, so the two cannot both hold.

The cost, accepted: a reply can be posted to the port the registration carries rather than to one read from a live session, in the case where no session is readable.

## 2. The Herdr composer proof refuses only a non-empty composer

Site: `bin/backends/herdr.sh`, `fm_backend_herdr_send_text_submit`.
Decided 2026-09-26.
Record: `data/fm-reconcile-main-with-upstream/decision-herdr-exit-composer-proof-vs-pane-closing.md` (private).

Upstream withholds Enter unless the composer, empty before the send, reads back showing the payload, and clears and reports `send-failed` otherwise.
The proof applies only where the pane's agent identity is `claude`.

This fork refuses only when the composer reads back showing SOMETHING other than the payload, which is the truncation and foreign-text hazard the proof was built for.
A composer that reads back empty after the literal send has nothing to concatenate onto and nothing to truncate, so the submit proceeds.

The reason is that a pane can report agent identity `claude` while exposing no readable composer.
Under upstream's blanket refusal, `bin/fm-control.sh exit` cannot stop such an agent at all: the refusal clears the composer and never delivers the command, so the path that reads a vanished endpoint as a completed stop is never reached.
`tests/fm-control-herdr-relaunch-e2e.test.sh` covers that case against real Herdr.

The cost, accepted: for a pane whose composer cannot be read, Enter is sent without positive proof that the payload landed.
A narrower fix may exist, and the entry below records why it was not taken here.

### What is still open on this one

The case that exposed this uses a stand-in agent binary named `claude`, so Herdr reports identity `claude` for a pane that is not a real Claude composer.
A real Claude pane satisfies upstream's proof, delivers the command, and reaches the same vanished-endpoint path unharmed.
So it is possible that this divergence is only needed for panes that report `claude` without being one, and that a real-agent-only proof would let upstream's blanket refusal stand.
That was not resolved when the divergence was taken, and narrowing it later would be a genuine improvement rather than a regression.
