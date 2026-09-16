# shellcheck shell=bash
# Shared Lavish server port for everything this home drives.
# Usage: . bin/fm-lavish-lib.sh; fm_lavish_export_port
#
# ONE OWNER for which port this home's Lavish traffic uses. Every Firstmate
# path that reaches lavish-axi - the bearings board build, the armed Lavish
# process-event listener, and the workers this home launches - resolves it here
# so they all land on the same server.
#
# WHY A HOME MAY NOT TAKE THE VENDOR DEFAULT. lavish-axi binds one fixed
# default port for the whole MACHINE while keeping its session state directory
# per LOGIN (~/.lavish-axi, or LAVISH_AXI_STATE_DIR). Two logins on one host
# therefore race for one port: whichever starts a server first owns it, the
# other login's requests reach a server that cannot read its mode-0600 files
# and answer 500, and `lavish-axi server` on that port reports EADDRINUSE. That
# is not hypothetical: a scout under a second login held the default port and
# the captain's interactive fleet board could not be raised at all.
#
# SO THE PORT IS RESOLVED PER LOGIN, which is the granularity the server
# already has. The derived port is a function of the login's uid, so it is
# stable across restarts - the board's session URL and its canonical
# process-event source identity both depend on the port staying put - and two
# logins on one machine never resolve the same port unless their uids are
# congruent modulo FM_LAVISH_PORT_SPAN.
#
# TWO HOMES UNDER ONE LOGIN SHARE THE PORT DELIBERATELY. They are one user, so
# they can read each other's artifacts and cannot 500 one another, and they
# already share one state directory whose whole contents the server rewrites on
# every session change. Giving them separate ports would put two servers behind
# one read-modify-write state file and let one drop the other's sessions.
#
# The uid derivation keeps the vendor default for the ordinary single-login
# Linux host, whose first human login is uid 1000: an unconfigured home there
# resolves exactly the port it used before this resolution existed.
#
# An operator who needs a specific port pins it; docs/configuration.md "Lavish
# port" owns that operator-facing procedure.
#
# Resolution is fail-closed: a malformed pin refuses rather than falling back to
# the default, because silently reverting to the colliding port is the failure
# this exists to prevent.

FM_LAVISH_PORT_BASE=4387
FM_LAVISH_PORT_SPAN=1000
FM_LAVISH_PORT_MIN=1024
FM_LAVISH_PORT_MAX=65535

# Whether <value> is a plain decimal port inside the unprivileged range.
fm_lavish_port_valid() {  # <value>
  local value=${1-}
  [ -n "$value" ] || return 1
  case "$value" in *[!0-9]*) return 1 ;; esac
  # Leading zeros would make a later numeric comparison read a different value
  # than the text an operator pinned, so they are refused rather than accepted.
  case "$value" in 0*) return 1 ;; esac
  [ "$value" -ge "$FM_LAVISH_PORT_MIN" ] && [ "$value" -le "$FM_LAVISH_PORT_MAX" ]
}

# The port this login derives with no configuration at all.
fm_lavish_port_derived() {
  local uid
  uid=$(id -u 2>/dev/null) || return 1
  case "$uid" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$((FM_LAVISH_PORT_BASE + uid % FM_LAVISH_PORT_SPAN))"
}

# Print this home's Lavish port, or refuse naming the offending source.
# Precedence: an explicit ambient LAVISH_AXI_PORT (the operator is already
# steering lavish-axi itself), then this home's config/lavish-port pin, then
# the derived per-login port.
fm_lavish_port() {
  local config pin=''
  if [ -n "${LAVISH_AXI_PORT-}" ]; then
    fm_lavish_port_valid "$LAVISH_AXI_PORT" || {
      printf 'error: LAVISH_AXI_PORT must be a port from %s to %s: %s\n' \
        "$FM_LAVISH_PORT_MIN" "$FM_LAVISH_PORT_MAX" "$LAVISH_AXI_PORT" >&2
      return 1
    }
    printf '%s\n' "$LAVISH_AXI_PORT"
    return 0
  fi
  # Only a home this process actually knows can carry a pin. With no home, the
  # derived port is the answer: resolving a relative "config/lavish-port" would
  # read whatever directory the process happens to be standing in.
  config=${FM_CONFIG_OVERRIDE-}
  [ -n "$config" ] || { [ -z "${FM_HOME-}" ] || config="$FM_HOME/config"; }
  if [ -n "$config" ] && [ -f "$config/lavish-port" ] && [ ! -L "$config/lavish-port" ]; then
    IFS= read -r pin < "$config/lavish-port" 2>/dev/null || [ -n "$pin" ] || pin=''
    pin=${pin#"${pin%%[![:space:]]*}"}
    pin=${pin%"${pin##*[![:space:]]}"}
    fm_lavish_port_valid "$pin" || {
      printf 'error: %s/lavish-port must hold one port from %s to %s: %s\n' \
        "$config" "$FM_LAVISH_PORT_MIN" "$FM_LAVISH_PORT_MAX" "$pin" >&2
      return 1
    }
    printf '%s\n' "$pin"
    return 0
  fi
  fm_lavish_port_derived || {
    printf 'error: cannot read this login to derive the Lavish port\n' >&2
    return 1
  }
}

# Export the resolved port so lavish-axi and every child of this process reach
# this home's server. Idempotent: re-exporting an already valid value resolves
# to the same port.
fm_lavish_export_port() {
  local port
  port=$(fm_lavish_port) || return 1
  export LAVISH_AXI_PORT="$port"
}
