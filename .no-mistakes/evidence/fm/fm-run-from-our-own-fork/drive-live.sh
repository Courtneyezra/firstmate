#!/usr/bin/env bash
# Live drive of the real /updatefirstmate mechanics (bin/fm-update.sh from a real
# clone of this branch) against a disposable lab home with real bare "origin"
# and "fork" remotes. Run from the gate worktree.
set -u
WT=$PWD
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.com GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.com
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
bin/fm-lab-home.sh create "$LAB" >/dev/null; mkdir -p "$LAB/tmux"
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-repos.XXXXXX")
trap 'rm -rf "$LAB" "$W"' EXIT
touch "$LAB/state/.last-watcher-beat"
hr(){ printf '\n===== %s =====\n' "$*"; }
# Upstream "origin" and the fleet's "fork", both seeded from this branch's HEAD.
git clone -q --bare "$WT" "$W/origin.git"; git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git -C "$W/origin.git" update-ref refs/heads/main "$(git -C "$WT" rev-parse HEAD)"
git clone -q --bare "$W/origin.git" "$W/fork.git"
bump(){ # <bare> <msg>
  rm -rf "$W/seed"; git clone -q "$1" "$W/seed"; echo "$2" >> "$W/seed/README.md"
  git -C "$W/seed" commit -qam "$2"; git -C "$W/seed" push -q origin main; git -C "$W/seed" rev-parse --short HEAD; }
fresh_primary(){
  rm -rf "$W/primary" "$W/sm1"; git clone -q "$W/origin.git" "$W/primary"; git -C "$W/primary" reset -q --hard "$BASE"; git -C "$W/primary" remote add fork "$W/fork.git"
  git -C "$W/primary" fetch -q fork; git -C "$W/primary" remote set-head fork main >/dev/null
  rm -f "$LAB/state/"*.meta
  git -C "$W/primary" worktree add -q --detach "$W/sm1" main
  printf 'sm1\n' > "$W/sm1/.fm-secondmate-home"
  printf 'window=main:fm-sm1\nendpoint_task_id=sm1\nworktree=%s\nproject=%s\nkind=secondmate\nharness=claude\nhome=%s\n' "$W/sm1" "$W/sm1" "$W/sm1" > "$LAB/state/sm1.meta"
}
run(){ # run the primary checkout's OWN fm-update.sh against the lab home, inside the lab tmux socket
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
    TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" "$W/primary/bin/fm-update.sh" 2>&1 | sed 's/^/  | /'; }
heads(){ echo "  primary HEAD=$(git -C "$W/primary" rev-parse --short HEAD)  sm1 HEAD=$(git -C "$W/sm1" rev-parse --short HEAD)  origin/main=$(git -C "$W/origin.git" rev-parse --short main)  fork/main=$(git -C "$W/fork.git" rev-parse --short main)"; }

BASE=$(git -C "$WT" rev-parse --short HEAD)
F=$(bump "$W/fork.git" fork-only-fix); O=$(bump "$W/origin.git" upstream-only-change)
echo "base=$BASE fork tip=$F origin tip=$O (diverged: fork and origin at different commits)"

hr "S1 config/update-remote=fork -> primary + local secondmate land on fork tip, not origin"
fresh_primary; echo fork > "$LAB/config/update-remote"; heads; run; heads
echo "  primary HEAD parents: $(git -C "$W/primary" log -1 --format=%p | wc -w) (1 = single-parent ff)"

hr "S2 no config/update-remote -> unchanged behaviour, follows origin"
fresh_primary; rm -f "$LAB/config/update-remote"; heads; run; heads

hr "S3 whitespace-only config/update-remote -> origin"
fresh_primary; printf '  \n\t\n' > "$LAB/config/update-remote"; heads; run; heads

hr "S4 adversarial: configured remote 'myfork' not defined in repo -> skip by name, no origin fallback"
fresh_primary; echo myfork > "$LAB/config/update-remote"
before_ref=$(git -C "$W/primary" rev-parse origin/main); heads; run; heads
echo "  origin/main tracking ref moved (fetched)? $( [ "$(git -C "$W/primary" rev-parse origin/main)" = "$before_ref" ] && echo no || echo YES)"

hr "S5 adversarial: fork configured but primary/secondmate already AHEAD of the fork (fork/main is an ancestor of their HEAD) -> refused, never moved back or elsewhere"
git clone -q --bare "$W/origin.git" "$W/forkbehind.git"; git -C "$W/forkbehind.git" update-ref refs/heads/main "$BASE"
fresh_primary; git -C "$W/primary" remote set-url fork "$W/forkbehind.git"; git -C "$W/primary" fetch -q --prune fork
git -C "$W/primary" merge -q --ff-only origin/main; git -C "$W/sm1" checkout -q --detach origin/main
echo "  fork(behind)/main=$(git -C "$W/forkbehind.git" rev-parse --short main)"
echo fork > "$LAB/config/update-remote"; heads; run; heads

hr "S6 origin unaffected for other commands: primary's origin URL and push config untouched after fork update"
fresh_primary; echo fork > "$LAB/config/update-remote"; run >/dev/null; git -C "$W/primary" remote -v | sed 's/^/  /'; echo "  branch.main.remote=$(git -C "$W/primary" config branch.main.remote)"
