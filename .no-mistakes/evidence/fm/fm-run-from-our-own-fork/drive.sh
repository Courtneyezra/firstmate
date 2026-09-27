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

say "S1 unconfigured home follows origin (fork also advanced, must be ignored)"
world; advance "$SB/upstream.git" up-1; advance "$SB/fork.git" fork-1
ls "$SB/lab/config"; heads; update; heads

say "S2 config/update-remote=fork: primary and secondmate land on fork tip, not origin"
world; advance "$SB/fork.git" fork-2; advance "$SB/upstream.git" up-2
printf 'fork\n' > "$SB/lab/config/update-remote"
REMOTES_BEFORE=$(git -C "$SB/primary" remote -v); heads; update; heads
echo "parents of primary HEAD: $(git -C "$SB/primary" rev-list --parents -n1 HEAD | wc -w) (2 = single-parent ff)"
echo "primary HEAD == fork/main? $([ "$(git -C "$SB/primary" rev-parse HEAD)" = "$(git -C "$SB/fork.git" rev-parse main)" ] && echo yes || echo NO)"
echo "remotes unchanged by update? $([ "$REMOTES_BEFORE" = "$(git -C "$SB/primary" remote -v)" ] && echo yes || echo NO)"; git -C "$SB/primary" remote -v

say "S3 configured remote missing from repo: skip naming it, no origin fallback"
world; advance "$SB/upstream.git" up-3; git -C "$SB/primary" remote remove fork
printf 'myfork\n' > "$SB/lab/config/update-remote"
B=$(git -C "$SB/primary" rev-parse HEAD); heads; update; heads
echo "primary unmoved? $([ "$B" = "$(git -C "$SB/primary" rev-parse HEAD)" ] && echo yes || echo NO)"

say "S4 whitespace-only config/update-remote resolves to origin"
world; advance "$SB/upstream.git" up-4; advance "$SB/fork.git" fork-4
printf '   \n\t\n' > "$SB/lab/config/update-remote"; heads; update; heads

say "S5 adversarial: home already on origin commit the fork lacks, fork configured -> refused, not moved"
world; advance "$SB/upstream.git" up-5; git -C "$SB/primary" pull -q --ff-only origin main
git -C "$SB/sm1" checkout -q --detach main
advance "$SB/fork.git" fork-5; printf 'fork\n' > "$SB/lab/config/update-remote"
B=$(git -C "$SB/primary" rev-parse HEAD); heads; update; heads
echo "primary unmoved? $([ "$B" = "$(git -C "$SB/primary" rev-parse HEAD)" ] && echo yes || echo NO)"

say "S6 receiver: target code root accepts config/update-remote as inherited material; base code root refuses it"
H=$SB/remotehome; mkdir -p "$H/config" "$H/state" "$H/data"
EMPTY=$(printf '' | sha256sum | awk '{print $1}')
printf 'fork\n' > "$SB/val"; SHA=$(sha256sum "$SB/val" | awk '{print $1}')
FM_HOME=$H "$SB/primary/bin/fm-remote-inherit.sh" put config/update-remote 5 "$SHA" 1 < "$SB/val"; echo "[target exit $?] home copy: $(cat "$H/config/update-remote" 2>&1)"
echo "resolved by fm_update_remote with that home: $(FM_HOME=$H bash -c ". '$SB/primary/bin/fm-ff-lib.sh' >/dev/null 2>&1; fm_update_remote")"
git -C "$SB/scratch" worktree add -q --detach "$SB/oldroot" 49a218bb1d354929911675c0d1fbdd441715e164 2>/dev/null || git clone -q "$WT" "$SB/oldroot" && git -C "$SB/oldroot" checkout -q 49a218bb1d354929911675c0d1fbdd441715e164
H2=$SB/oldhome; mkdir -p "$H2/config" "$H2/state" "$H2/data"
FM_HOME=$H2 "$SB/oldroot/bin/fm-remote-inherit.sh" put config/update-remote 5 "$SHA" 1 < "$SB/val"; echo "[base exit $?]"

rm -rf "$SB"; echo; echo "sandbox removed: $([ -e "$SB" ] && echo NO || echo yes)"
