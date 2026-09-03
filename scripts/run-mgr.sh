#!/bin/bash
# Run Ceph Manager (MGR) daemon
#
# Waits for setup-mgr.sh to finish, then starts the manager daemon
# in foreground mode for supervisor.
#
set -e

# Source common utilities
source /scripts/lib/common.sh

# Configuration (stable identity survives container recreation)
MGR_NAME=$(ceph_node_name)
MARKER_FILE="/ceph-run/mgr-configured"

log "Starting Ceph Manager daemon"

# Wait for setup-mgr.sh to finish (it also creates the keyring). Waiting
# on the keyring file itself races the non-atomic 'ceph auth get-or-create
# -o' write: the daemon can read the file empty and fail its first mon
# handshake with EPERM.
wait_for_file "$MARKER_FILE" 300 || {
    error "Manager bootstrap did not complete after timeout"
    exit 1
}

# Start manager daemon in foreground mode
log "Manager bootstrap complete, starting daemon"
MGR_USER_ARGS=()
if is_root; then
    MGR_USER_ARGS=(--setuser ceph --setgroup ceph)
fi
exec /usr/bin/ceph-mgr \
    --cluster ceph \
    -i "$MGR_NAME" \
    --foreground \
    "${MGR_USER_ARGS[@]}"
