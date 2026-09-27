#!/usr/bin/env bash
# Drive the primary's real bin/fm-update.sh against a registered REMOTE secondmate
# route whose "host" is a real Firstmate code root + home on this machine. Only the
# SSH transport + remote job worker are replaced: the shim decodes fm-on.sh's argv
# exactly as fm-remote-entrypoint.sh does and executes <host root>/bin/<cmd> with
# FM_HOME=<host home>. Every Firstmate script on both sides is the real one.
set -u
WT=$PWD
OLD=050a44643af4f7c9b7a20b1bf165d4834d064c1b   # base commit: predates config/update-remote
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.com GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.com
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
bin/fm-lab-home.sh create "$LAB" >/dev/null; mkdir -p "$LAB/tmux"
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-repos.XXXXXX")
trap 'rm -rf "$LAB" "$W"' EXIT
touch "$LAB/state/.last-watcher-beat"
BASE=$(git -C "$WT" rev-parse HEAD)
git clone -q --bare "$WT" "$W/origin.git"; git -C "$W/origin.git" update-ref refs/heads/main "$BASE"; git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q --bare "$W/origin.git" "$W/fork.git"
bump(){ rm -rf "$W/seed"; git clone -q "$1" "$W/seed"; echo "$2" >> "$W/seed/README.md"; git -C "$W/seed" commit -qam "$2"; git -C "$W/seed" push -q origin main; git -C "$W/seed" rev-parse --short HEAD; }
F=$(bump "$W/fork.git" fork-only); O=$(bump "$W/origin.git" upstream-only)
mkdir -p "$W/bin"
cat > "$W/bin/lab-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac; done
host=$1; shift; [ "$1" = fm-remote-entrypoint.sh ] || exit 91
d(){ printf '%s' "$1" | base64 --decode; }
root=$(d "$3"); home=$(d "$4"); args=()
while IFS= read -r -d '' a; do args+=("$a"); done < <(d "$5")
printf '[host %s] %s\n' "$host" "${args[*]}" >> "$LAB_WIRE"
cd "$home" && exec env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_UPDATE_REMOTE -u TMUX -u FM_CONFIG_INHERIT_LIVE \
  FM_HOME="$home" "$root/bin/${args[0]}" "${args[@]:1}"
SH
chmod +x "$W/bin/lab-ssh"
setup(){ # <host code-root commit> <primary config/update-remote or empty>
  rm -rf "$W/primary" "$W/hostroot" "$W/hosthome"; : > "$W/wire"
  git clone -q "$W/origin.git" "$W/primary"; git -C "$W/primary" reset -q --hard "$BASE"; git -C "$W/primary" remote add fork "$W/fork.git"
  git clone -q "$W/origin.git" "$W/hostroot"; git -C "$W/hostroot" reset -q --hard "$1"; git -C "$W/hostroot" remote add fork "$W/fork.git"
  mkdir -p "$W/hostroot/state"; touch "$W/hostroot/state/.last-watcher-beat"; printf 'state/\n' >> "$W/hostroot/.git/info/exclude"
  git clone -q "$W/hostroot" "$W/hosthome"; git -C "$W/hosthome" checkout -q --detach "$1"
  printf 'sm1\n' > "$W/hosthome/.fm-secondmate-home"; mkdir -p "$W/hosthome/config" "$W/hosthome/state"; touch "$W/hosthome/state/.last-watcher-beat"
  printf 'state/\nconfig/\n.fm-secondmate-home\n' >> "$W/hosthome/.git/info/exclude"
  rm -f "$LAB/config/update-remote" "$LAB/state/"*.meta; [ -z "$2" ] || printf '%s\n' "$2" > "$LAB/config/update-remote"
  printf -- '- sm1 - remote domain (host: labhost; root: %s; home: %s; scope: things; projects: p; added 2026-09-27)\n' "$W/hostroot" "$W/hosthome" > "$LAB/data/secondmates.md"
}
heads(){ echo "  primary=$(git -C "$W/primary" rev-parse --short HEAD) hostroot=$(git -C "$W/hostroot" rev-parse --short HEAD) hosthome=$(git -C "$W/hosthome" rev-parse --short HEAD) | origin/main=$O fork/main=$F | host home config/update-remote=$(cat "$W/hosthome/config/update-remote" 2>/dev/null || echo '<absent>')"; }
run(){ env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_UPDATE_REMOTE -u TMUX \
   TMUX_TMPDIR="$LAB/tmux" LAB_WIRE="$W/wire" FM_SSH_BIN="$W/bin/lab-ssh" FM_HOME="$LAB" "$W/primary/bin/fm-update.sh" 2>&1 | sed 's/^/  | /'
   echo "  wire order:"; sed 's/^/    /' "$W/wire"; }
echo "base=$(git -C "$WT" rev-parse --short HEAD) fork tip=$F origin tip=$O old(predating) root=${OLD:0:7}"
echo; echo "===== RR1 fleet set to fork just now; up-to-date host has NO inherited copy yet -> copy pushed first, host root+home land on fork tip ====="
setup "$BASE" fork; heads; run; heads
echo; echo "===== RR2 adversarial: fleet on fork, host code root PREDATES the setting -> NOT converged, host not moved onto origin ====="
setup "$OLD" fork; heads; run; heads
echo; echo "===== RR3 fleet on origin (no file), host code root predates -> updates exactly as before (no wedge) ====="
setup "$OLD" ""; heads; run; heads
