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

# Configuration. Fixed id: Ceph rejects MDS ids beginning with a digit,
# which container hostnames frequently do (must match setup-mds.sh)
MDS_NAME="aio"
MARKER_FILE="/var/run/ceph/mds-provisioned"

log "Starting Ceph MDS daemon"

# Wait for setup-mds.sh to provision the filesystem and keyring (its
# final mds-configured marker comes later: it needs this daemon active
# to create the CSI subvolume group)
wait_for_file "$MARKER_FILE" 300 || {
    error "CephFS provisioning marker not found after timeout"
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
