#!/bin/bash
# Run RADOS Gateway (RGW) daemon
#
# Waits for RGW keyring to be created by setup-rgw.sh,
# then starts the RADOS Gateway daemon in foreground mode for supervisor.
#
set -e

# Source common utilities
source /scripts/lib/common.sh

# Configuration
KEYRING_PATH="/var/lib/ceph/radosgw/ceph-rgw.gateway/keyring"

log "Starting RADOS Gateway (RGW) daemon"

# Wait for keyring to be created by setup-rgw.sh
wait_for_file "$KEYRING_PATH" 60 || {
    error "RGW keyring not found after timeout"
    exit 1
}

# Start RGW daemon in foreground mode
log "RGW keyring found, starting daemon"
exec /usr/bin/radosgw \
    -n client.rgw.gateway \
    --cluster ceph \
    --foreground \
    --setuser ceph \
    --setgroup ceph
