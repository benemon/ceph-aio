#!/bin/bash
set -e

# Source common utilities
source /scripts/lib/common.sh

# Configuration. The MDS id is fixed rather than derived from the node
# name: Ceph rejects MDS ids that begin with a digit, and container
# hostnames frequently do. A fixed id is also inherently stable across
# container recreation.
MDS_NAME="aio"
MDS_DIR="/var/lib/ceph/mds/ceph-$MDS_NAME"
KEYRING_PATH="$MDS_DIR/keyring"
FS_NAME="cephfs"
METADATA_POOL="cephfs_metadata"
DATA_POOL="cephfs_data"
PG_NUM=8
MARKER_FILE="/var/run/ceph/mds-configured"

log "Starting CephFS (MDS) setup"

# Check if already configured
if check_done "$MARKER_FILE" "CephFS"; then
    exit 0
fi

# Wait for cluster and OSDs: filesystem pools need servable PGs
wait_for_cluster || {
    error "Cluster not ready, cannot configure CephFS"
    exit 1
}
wait_for_osds "${OSD_COUNT:-1}" 180 || {
    error "OSDs not up, cannot configure CephFS"
    exit 1
}

# Create filesystem pools
for pool in "$METADATA_POOL" "$DATA_POOL"; do
    if ceph osd pool ls | grep -q "^${pool}$"; then
        log "Pool '$pool' already exists, skipping creation"
    else
        log "Creating pool '$pool' with $PG_NUM PGs"
        ceph osd pool create "$pool" "$PG_NUM" || {
            error "Failed to create pool '$pool'"
            exit 1
        }
    fi
done

# Create the filesystem (tags the pools with the cephfs application)
if ceph fs ls | grep -q "name: $FS_NAME,"; then
    log "Filesystem '$FS_NAME' already exists, skipping creation"
else
    log "Creating filesystem '$FS_NAME'"
    ceph fs new "$FS_NAME" "$METADATA_POOL" "$DATA_POOL" || {
        error "Failed to create filesystem"
        exit 1
    }
fi

# Create MDS keyring
log "Creating MDS keyring"
mkdir -p "$MDS_DIR"
ceph auth get-or-create "mds.$MDS_NAME" \
    mon 'profile mds' \
    mgr 'profile mds' \
    osd 'allow rwx' \
    mds 'allow *' \
    -o "$KEYRING_PATH" || {
    error "Failed to create MDS keyring"
    exit 1
}

# Set ownership
chown -R ceph:ceph "$MDS_DIR" || {
    error "Failed to set MDS directory ownership"
    exit 1
}

# Mark as configured. run-mds.sh waits for this marker, so the daemon
# only starts against the created filesystem.
mark_done "$MARKER_FILE" "CephFS"

success "CephFS filesystem '$FS_NAME' configured"
