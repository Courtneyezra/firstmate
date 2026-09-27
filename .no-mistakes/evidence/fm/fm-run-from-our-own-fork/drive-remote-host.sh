#!/usr/bin/env bash
# Live drive of the remote-host side: the host code root's OWN
# bin/fm-remote-secondmate-control.sh update <id>, with FM_HOME = that host's
# secondmate home carrying the inherited config/update-remote.
set -u
WT=$PWD
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.com GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.com
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-host.XXXXXX"); trap 'rm -rf "$W"' EXIT
BASE=$(git -C "$WT" rev-parse HEAD)
git clone -q --bare "$WT" "$W/origin.git"; git -C "$W/origin.git" update-ref refs/heads/main "$BASE"; git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q --bare "$W/origin.git" "$W/fork.git"
bump(){ rm -rf "$W/seed"; git clone -q "$1" "$W/seed"; echo "$2" >> "$W/seed/README.md"; git -C "$W/seed" commit -qam "$2"; git -C "$W/seed" push -q origin main; git -C "$W/seed" rev-parse --short HEAD; }
F=$(bump "$W/fork.git" fork-only); O=$(bump "$W/origin.git" upstream-only)
setup(){ # <home-config-value or empty>
  rm -rf "$W/coderoot" "$W/home"
  git clone -q "$W/origin.git" "$W/coderoot"; git -C "$W/coderoot" reset -q --hard "$BASE"; git -C "$W/coderoot" remote add fork "$W/fork.git"
  mkdir -p "$W/coderoot/state"; touch "$W/coderoot/state/.last-watcher-beat"
  git clone -q "$W/coderoot" "$W/home"; git -C "$W/home" checkout -q --detach "$BASE"
  printf 'sm1\n' > "$W/home/.fm-secondmate-home"; mkdir -p "$W/home/config" "$W/home/state"; touch "$W/home/state/.last-watcher-beat"
  [ -z "$1" ] || printf '%s\n' "$1" > "$W/home/config/update-remote"
}
drive(){ env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u FM_UPDATE_REMOTE \
  FM_HOME="$W/home" "$W/coderoot/bin/fm-remote-secondmate-control.sh" update sm1 2>&1 | sed 's/^/  | /'
  echo "  code root HEAD=$(git -C "$W/coderoot" rev-parse --short HEAD)  home HEAD=$(git -C "$W/home" rev-parse --short HEAD)"; }
echo "base=$(git -C "$WT" rev-parse --short HEAD) fork tip=$F origin tip=$O"
echo; echo "===== R1 host home inherited config/update-remote=fork -> host code root AND home land on fork tip ====="; setup fork; drive
echo; echo "===== R2 host home has no config/update-remote -> host follows origin as before ====="; setup ""; drive
