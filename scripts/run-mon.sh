#!/bin/bash
# Run Ceph Monitor (MON) daemon
#
# Starts the monitor daemon in foreground mode for supervisor.
# Monitor is bootstrapped by bootstrap.sh before supervisor starts.
#
set -e

# Source common utilities
source /scripts/lib/common.sh

# Configuration (stable identity survives container recreation)
MON_NAME=$(ceph_node_name)

log "Starting Ceph Monitor daemon: $MON_NAME"

# Start monitor daemon in foreground mode
MON_USER_ARGS=()
if is_root; then
    MON_USER_ARGS=(--setuser ceph --setgroup ceph)
fi
exec /usr/bin/ceph-mon \
    --cluster ceph \
    -i "$MON_NAME" \
    --foreground \
    "${MON_USER_ARGS[@]}"
