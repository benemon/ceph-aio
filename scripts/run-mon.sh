#!/bin/bash
# Run Ceph Monitor (MON) daemon
#
# Starts the monitor daemon in foreground mode for supervisor.
# Monitor is bootstrapped by bootstrap.sh before supervisor starts.
#
set -e

# Source common utilities
source /scripts/lib/common.sh

# Configuration
MON_NAME=$(hostname -s)

log "Starting Ceph Monitor daemon: $MON_NAME"

# Start monitor daemon in foreground mode
exec /usr/bin/ceph-mon \
    --cluster ceph \
    -i "$MON_NAME" \
    --foreground \
    --setuser ceph \
    --setgroup ceph
