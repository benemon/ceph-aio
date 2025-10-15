#!/bin/bash
# Run Ceph Manager (MGR) daemon
#
# Waits for manager keyring to be created by setup-mgr.sh,
# then starts the manager daemon in foreground mode for supervisor.
#
set -e

# Source common utilities
source /scripts/lib/common.sh

# Configuration
MGR_NAME=$(hostname -s)
KEYRING_PATH="/var/lib/ceph/mgr/ceph-$MGR_NAME/keyring"

log "Starting Ceph Manager daemon"

# Wait for keyring to be created by setup-mgr.sh
wait_for_file "$KEYRING_PATH" 60 || {
    error "Manager keyring not found after timeout"
    exit 1
}

# Start manager daemon in foreground mode
log "Manager keyring found, starting daemon"
exec /usr/bin/ceph-mgr \
    --cluster ceph \
    -i "$MGR_NAME" \
    --foreground \
    --setuser ceph \
    --setgroup ceph
