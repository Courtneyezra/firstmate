#!/usr/bin/env bash
# drive-sweep.sh <repo-root> <label> <grace> <nchecks> <check-secs> <sample-secs> [hang]
# Mints a marked lab home, arms <nchecks> trusted custom checks that each take
# <check-secs>, runs the real bin/fm-watch.sh against it, and samples the beacon
# age plus the guard predicate (fm_watcher_healthy) once a second.
set -u
ROOT=$1 LABEL=$2 GRACE=$3 N=$4 SECS=$5 SAMPLE=$6 HANG=${7:-}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
for i in $(seq 1 "$N"); do
  printf '#!/usr/bin/env bash\nsleep %s\n' "$SECS" > "$LAB/state/slow$i.check.sh"
  chmod 0700 "$LAB/state/slow$i.check.sh"
  FM_HOME="$LAB" "$ROOT/bin/fm-check-register.sh" "slow$i" >/dev/null || { echo "register failed"; exit 1; }
done
if [ -n "$HANG" ]; then
  printf '#!/usr/bin/env bash\nsleep 100000\n' > "$LAB/state/hang.check.sh"
  chmod 0700 "$LAB/state/hang.check.sh"
  FM_HOME="$LAB" "$ROOT/bin/fm-check-register.sh" hang >/dev/null
fi
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" FM_GUARD_GRACE="$GRACE" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=${CT:-30} \
  "$ROOT/bin/fm-watch.sh" > "$LAB/watch.out" 2> "$LAB/watch.err" &
PID=$!
for _ in $(seq 1 100); do [ -e "$LAB/state/.last-watcher-beat" ] && break; sleep 0.1; done
echo "== $LABEL: root=$ROOT grace=${GRACE}s checks=${N}x${SECS}s hang=${HANG:-no} watcher_pid=$PID"
maxage=0 down=0
for t in $(seq 1 "$SAMPLE"); do
  kill -0 "$PID" 2>/dev/null || { echo "t=${t}s watcher exited"; break; }
  age=$(bash -c '. "$1"; fm_path_age "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$LAB/state/.last-watcher-beat")
  if FM_HOME="$LAB" bash -c '. "$1"; fm_watcher_healthy "$2" "$3" "$4" "$5"' _ \
       "$ROOT/bin/fm-wake-lib.sh" "$LAB/state" "$ROOT/bin/fm-watch.sh" "$GRACE" "$LAB"; then v=HEALTHY; else v=DOWN; down=$((down+1)); fi
  running=$(pgrep -af "$LAB/state/.*check.sh" | grep -o 'slow[0-9]*\|hang' | head -1)
  [ "$age" -gt "$maxage" ] && maxage=$age
  printf 't=%3ss beacon_age=%3ss guard=%s running_check=%s\n' "$t" "$age" "$v" "${running:--}"
  sleep 1
done
echo "== $LABEL SUMMARY: max_beacon_age=${maxage}s grace=${GRACE}s down_samples=$down/$SAMPLE"
kill "$PID" 2>/dev/null; sleep 1; kill -9 "$PID" 2>/dev/null
pkill -f "$LAB/state/" 2>/dev/null
rm -rf "$LAB"
