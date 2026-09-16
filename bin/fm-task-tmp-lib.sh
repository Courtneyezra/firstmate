#!/usr/bin/env bash
# Per-task temp root owner for fm-spawn.sh.
#
# A task's temp root is <base>/fm-<uid>-<task-id>, keyed by the login's numeric
# uid as well as the task id, so two firstmate logins on one host that use the
# same task id never meet at one path in a shared sticky /tmp. The uid is
# dash-free, so the first dash after "fm-" splits the two fields unambiguously.
# fm-spawn.sh records the prepared root as tasktmp= in the task's meta, and
# fm-teardown.sh removes exactly that recorded path.
#
# fm_task_tmp_prepare refuses rather than adopts a path it cannot prove is this
# login's own private directory: a symlink, a non-directory, a directory owned
# by another uid, or one any other user can write to fails, so a pre-planted or
# foreign path is never used as a task's temp root or later removed as one. A
# root only this login can write to is reused and tightened to 0700.

fm_task_tmp_owner_uid() { # <path>
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %u "$1" 2>/dev/null
  else
    stat -c %u "$1" 2>/dev/null
  fi
}

# fm_task_tmp_root <base> <task-id>: print this login's temp root path for the task.
fm_task_tmp_root() {
  local base=$1 id=$2 uid
  uid=$(id -u 2>/dev/null) || return 1
  case "$uid" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ -n "$base" ] && [ -n "$id" ] || return 1
  printf '%s/fm-%s-%s\n' "${base%/}" "$uid" "$id"
}

# fm_task_tmp_owned <root>: 0 when root is a real directory owned by this login.
fm_task_tmp_owned() {
  local root=$1 uid owner
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  uid=$(id -u 2>/dev/null) || return 1
  owner=$(fm_task_tmp_owner_uid "$root") || return 1
  [ -n "$owner" ] && [ "$owner" = "$uid" ]
}

# fm_task_tmp_other_writable <root>: 0 when anyone but the owner may write root.
# Tightening such a directory after the fact cannot undo what was planted in it
# while it stood open, so an existing root in that state is refused rather than
# reused, even though this login owns it.
fm_task_tmp_other_writable() {
  [ -n "$(find "$1" -prune \( -perm -g=w -o -perm -o=w \) -print 2>/dev/null)" ]
}

# fm_task_tmp_prepare <root>: create root (mode 0700) and its gotmp/ child, or
# reuse root when it is already this login's own directory. Fails with a
# diagnostic on stderr when the path exists and is not provably ours.
fm_task_tmp_prepare() {
  local root=$1
  if [ ! -e "$root" ] && [ ! -L "$root" ]; then
    # A lost creation race falls through to the ownership proof below.
    mkdir -m 0700 "$root" 2>/dev/null || true
  fi
  if ! fm_task_tmp_owned "$root" || fm_task_tmp_other_writable "$root"; then
    echo "error: task temp root $root already exists and is not a private directory owned by this user; refusing to stage the launch command there; inspect and remove it, then retry" >&2
    return 1
  fi
  chmod 0700 "$root" 2>/dev/null || {
    echo "error: could not make task temp root $root private" >&2
    return 1
  }
  mkdir -p "$root/gotmp" || {
    echo "error: could not create $root/gotmp" >&2
    return 1
  }
}
