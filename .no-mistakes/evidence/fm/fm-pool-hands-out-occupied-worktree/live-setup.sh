#!/usr/bin/env bash
# Stand up a lab home, a real git project with a real treehouse pool (max_trees
# from $1), and a lab tmux server whose primary pane is a plain shell in FM_HOME=$LAB.
set -eu
WT=/home/fleet-max/.no-mistakes/worktrees/c7ade90a109c/01M3CX1XDA6B395FRY2V2D8BP2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-fix.XXXXXX")
P=$FIX/liveproj; POOL=$FIX/poolroot; OTHER=$FIX/other-home
mkdir -p "$POOL" "$OTHER/state"
git init -q -b main "$P"
printf 'base\n' > "$P/README.md"
printf 'max_trees = %s\nroot = "%s"\n' "$1" "$POOL" > "$P/treehouse.toml"
git -C "$P" add . && git -C "$P" -c user.name=t -c user.email=t@x.invalid commit -qm init
printf 'codex\n' > "$LAB/config/crew-harness"
printf '%s|%s|%s|%s|%s\n' "$LAB" "$FIX" "$P" "$POOL" "$OTHER"
