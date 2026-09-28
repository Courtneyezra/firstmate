# Source after round3-live.sh; drives commands through the lab primary pane.
WT=/home/fleet-max/.no-mistakes/worktrees/c7ade90a109c/01M3CX1XDA6B395FRY2V2D8BP2
IFS='|' read -r LAB LAB2 FIX P POOL OUTSIDE < "$REC"
export TMUX_TMPDIR="$LAB/tmux"
lt() { tmux -L fm-lab "$@"; }
# drive <label> <shell command run in the primary pane>
drive() {
  local label=$1 cmd=$2 done="$FIX/$1.done"
  rm -f "$done"
  lt send-keys -t primary:0 "( $cmd ) > '$FIX/$label.out' 2>&1; echo \$? > '$done'" Enter
  for _ in $(seq 1 240); do [ -e "$done" ] && break; sleep 0.5; done
  echo "===== $label"
  echo "\$ $cmd" | sed "s#$LAB2#<LAB2>#g; s#$LAB#<LAB>#g; s#$FIX#<FIX>#g"
  sed "s#$LAB2#<LAB2>#g; s#$LAB#<LAB>#g; s#$FIX#<FIX>#g" "$FIX/$label.out"
  echo "EXIT=$(cat "$done" 2>/dev/null || echo TIMEOUT)"
}
brief() { mkdir -p "$1/data/$2"; printf '# Task\n## Captain'"'"'s intent\nlive %s\n\n## Firstmate spec\nsleep\n' "$2" > "$1/data/$2/brief.md"; }
claimf() { find "$POOL" -maxdepth 4 -name .fm-slot-owner; }
show_claims() { for f in $(claimf); do echo "--- $f" | sed "s#$FIX#<FIX>#g"; sed "s#$LAB2#<LAB2>#g; s#$LAB#<LAB>#g; s#$FIX#<FIX>#g" "$f"; done; }
