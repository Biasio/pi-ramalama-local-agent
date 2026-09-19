#!/bin/bash
# pi-dev/confined.sh: confinement wrapper for agent-initiated pi runs.
# Baked into pi-sandbox-image at /usr/local/bin/pi-confined (pi-dev/Dockerfile).
#
# Runs its argv in a private user+mount namespace where system paths are
# remounted read-only. /workspace, /root (so /root/.pi) and /tmp stay
# writable. Fail-closed: if a remount fails the command does not run.
#
# NOT used by install_extensions (lib/env.sh), which must keep write access.
# PI_CONFINE=0 bypasses it for debugging.
set -euo pipefail

[ "${PI_CONFINE:-1}" = "0" ] && exec "$@"

# Order matters: parents before nested volume mounts.
export CONFINE_RO_DIRS="${CONFINE_RO_DIRS:-/usr /etc /opt /var /srv}"

exec unshare --user --map-root-user --mount --propagation private -- /bin/bash -c '
  set -eu
  for d in $CONFINE_RO_DIRS; do
    [ -d "$d" ] || continue
    mount --rbind "$d" "$d"
    mount -o remount,bind,ro "$d" "$d"
  done
  exec "$@"
' _ "$@"
