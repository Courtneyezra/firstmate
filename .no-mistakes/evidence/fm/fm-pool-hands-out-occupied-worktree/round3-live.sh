#!/usr/bin/env bash
# Round 3 live drive: real treehouse v2.3.0, real fm-spawn.sh, two disposable lab
# homes on one private tmux socket, one shared content-addressed pool.
set -u
WT=/home/fleet-max/.no-mistakes/worktrees/c7ade90a109c/01M3CX1XDA6B395FRY2V2D8BP2
MAXT=${1:-1}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
LAB2=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$WT/bin/fm-lab-home.sh" create "$LAB2" >/dev/null
mkdir -p "$LAB/tmux"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-fix.XXXXXX")
P=$FIX/liveproj; POOL=$FIX/poolroot; OUTSIDE=$FIX/lab2-state-outside
mkdir -p "$POOL" "$OUTSIDE"
git init -q -b main "$P"; printf 'base\n' > "$P/README.md"
printf 'max_trees = %s\nroot = "%s"\n' "$MAXT" "$POOL" > "$P/treehouse.toml"
git -C "$P" add . && git -C "$P" -c user.name=t -c user.email=t@x.invalid commit -qm init
for h in "$LAB" "$LAB2"; do printf 'codex\n' > "$h/config/crew-harness"; done
cp -a "$LAB2/state/." "$OUTSIDE/" 2>/dev/null || true
export TMUX_TMPDIR="$LAB/tmux"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  tmux -L fm-lab new-session -d -s primary -c "$WT" -e FM_HOME="$LAB" bash --norc
sleep 1
printf '%s|%s|%s|%s|%s|%s\n' "$LAB" "$LAB2" "$FIX" "$P" "$POOL" "$OUTSIDE"
