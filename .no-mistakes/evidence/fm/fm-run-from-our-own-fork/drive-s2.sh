#!/usr/bin/env bash
# Live driver: real firstmate code (this run's target commit) cloned as a primary
# checkout, real bare "origin" (upstream) and "fork" remotes, a marked lab FM_HOME,
# and a detached-worktree secondmate home. Runs the primary's OWN bin/fm-update.sh.
set -u
WT=$1
SB=$(mktemp -d "${TMPDIR:-/tmp}/fm-upd-live.XXXXXX")
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.com GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.com
say() { printf '\n=== %s ===\n' "$*"; }
git clone -q --bare --no-local "$WT" "$SB/upstream.git"
git -C "$SB/upstream.git" symbolic-ref HEAD refs/heads/main
git -C "$SB/upstream.git" update-ref refs/heads/main "$(git -C "$WT" rev-parse HEAD)"
git clone -q --bare "$SB/upstream.git" "$SB/fork.git"
git clone -q "$SB/upstream.git" "$SB/scratch"

world() {   # fresh primary + lab home + secondmate
  rm -rf "$SB/primary" "$SB/sm1" "$SB/lab"
  git clone -q "$SB/upstream.git" "$SB/primary"
  git -C "$SB/primary" remote add fork "$SB/fork.git"
  git -C "$SB/primary" fetch -q fork
  git -C "$SB/primary" remote set-head fork main >/dev/null
  LAB=$SB/lab; "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null; mkdir -p "$LAB/tmux"
  touch "$LAB/state/.last-watcher-beat"
  git -C "$SB/primary" worktree add -q --detach "$SB/sm1" main
  printf 'sm1\n' > "$SB/sm1/.fm-secondmate-home"
  printf 'window=main:fm-sm1\nkind=secondmate\nharness=claude\nhome=%s\nworktree=%s\nproject=%s\n' "$SB/sm1" "$SB/sm1" "$SB/sm1" > "$LAB/state/sm1.meta"
}
advance() {  # <remote-url> <tag>
  git -C "$SB/scratch" fetch -q "$1" main && git -C "$SB/scratch" checkout -q -B w FETCH_HEAD
  printf '%s\n' "$2" >> "$SB/scratch/README.md"
  git -C "$SB/scratch" commit -qam "$2" && git -C "$SB/scratch" push -q "$1" w:main
}
update() {
  ( cd "$SB/primary" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
     -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_UPDATE_REMOTE -u TMUX \
     TMUX_TMPDIR="$SB/lab/tmux" FM_HOME="$SB/lab" bin/fm-update.sh 2>&1 )
  echo "[exit $?]"
}
heads() {
  printf 'upstream(origin)/main=%s fork/main=%s\nprimary HEAD=%s (%s) sm1 HEAD=%s\n' \
    "$(git -C "$SB/upstream.git" rev-parse --short main)" "$(git -C "$SB/fork.git" rev-parse --short main)" \
    "$(git -C "$SB/primary" rev-parse --short HEAD)" "$(git -C "$SB/primary" symbolic-ref --short HEAD 2>/dev/null || echo detached)" \
    "$(git -C "$SB/sm1" rev-parse --short HEAD)"
}

say "S2 config/update-remote=fork: primary and secondmate land on fork tip, not origin"
advance "$SB/upstream.git" up-0; git -C "$SB/upstream.git" push -q --force "$SB/fork.git" main:main
world; advance "$SB/fork.git" fork-2; advance "$SB/upstream.git" up-2
P=$(git -C "$SB/primary" rev-parse HEAD)
echo "fixture: primary is ancestor of both tips and tips differ: $(git -C "$SB/fork.git" merge-base --is-ancestor $P main && git -C "$SB/upstream.git" merge-base --is-ancestor $P main && [ "$(git -C "$SB/fork.git" rev-parse main)" != "$(git -C "$SB/upstream.git" rev-parse main)" ] && echo yes || echo NO)"
printf 'fork\n' > "$SB/lab/config/update-remote"
REMOTES_BEFORE=$(git -C "$SB/primary" remote -v); heads; update; heads
echo "parents of primary HEAD: $(git -C "$SB/primary" rev-list --parents -n1 HEAD | wc -w) (2 = single-parent ff)"
echo "primary HEAD == fork/main? $([ "$(git -C "$SB/primary" rev-parse HEAD)" = "$(git -C "$SB/fork.git" rev-parse main)" ] && echo yes || echo NO)"
echo "sm1 HEAD == fork/main? $([ "$(git -C "$SB/sm1" rev-parse HEAD)" = "$(git -C "$SB/fork.git" rev-parse main)" ] && echo yes || echo NO)"
echo "primary HEAD != origin main? $([ "$(git -C "$SB/primary" rev-parse HEAD)" != "$(git -C "$SB/upstream.git" rev-parse main)" ] && echo yes || echo NO)"
echo "remotes unchanged by update (origin still upstream)? $([ "$REMOTES_BEFORE" = "$(git -C "$SB/primary" remote -v)" ] && echo yes || echo NO)"; git -C "$SB/primary" remote -v
echo "branch.main upstream still: $(git -C "$SB/primary" rev-parse --abbrev-ref main@{upstream})"
say "S2b second run is idempotent: already current on the fork"
update; heads
rm -rf "$SB"; echo "sandbox removed: $([ -e "$SB" ] && echo NO || echo yes)"
