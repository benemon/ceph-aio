#!/bin/bash
# Run Ceph Metadata Server (MDS) daemon
#
# Waits for setup-mds.sh to create the filesystem and keyring, then
# starts the MDS daemon in foreground mode for supervisor. Only
# generated into supervisord when ENABLE_CEPHFS=true.
#
set -e

# Source common utilities
source /scripts/lib/common.sh

# Configuration (stable identity survives container recreation)
MDS_NAME=$(ceph_node_name)
MARKER_FILE="/var/run/ceph/mds-configured"

log "Starting Ceph MDS daemon"

# Wait for setup-mds.sh to finish (it also creates the keyring)
wait_for_file "$MARKER_FILE" 300 || {
    error "CephFS configuration marker not found after timeout"
    exit 1
}

# Start MDS daemon in foreground mode
log "CephFS configuration complete, starting MDS daemon"
exec /usr/bin/ceph-mds \
    --cluster ceph \
    -i "$MDS_NAME" \
    --foreground \
    --setuser ceph \
    --setgroup ceph
