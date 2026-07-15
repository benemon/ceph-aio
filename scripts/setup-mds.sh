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
# Two markers: run-mds.sh starts the daemon on the first; the second is
# the healthcheck marker, written only once the MDS is active and the
# CSI subvolume group exists (creating the group needs an active MDS,
# so it cannot happen before the daemon starts)
PROVISIONED_MARKER="/var/run/ceph/mds-provisioned"
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

# A single-MDS cluster has no standby, and the filesystem wants one by
# default: without this the cluster sits in HEALTH_WARN
# (MDS_INSUFFICIENT_STANDBY) forever
log "Disabling standby MDS expectation for single-MDS cluster"
ceph fs set "$FS_NAME" standby_count_wanted 0 || {
    error "Failed to set standby_count_wanted"
    exit 1
}

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

# Release the daemon: run-mds.sh waits for this marker, so the MDS
# only starts against the created filesystem
mark_done "$PROVISIONED_MARKER" "CephFS provisioning"

# ceph-csi expects its subvolume group to pre-exist (it does not create
# one), and creating it needs an active MDS: the mgr volumes module
# mounts the filesystem to make the group directory
wait_for_command 180 bash -c "ceph mds stat | grep -q up:active" || {
    error "No active MDS, cannot create CSI subvolume group"
    exit 1
}
log "Creating 'csi' subvolume group for ceph-csi"
ceph fs subvolumegroup create "$FS_NAME" csi || {
    error "Failed to create CSI subvolume group"
    exit 1
}

mark_done "$MARKER_FILE" "CephFS"

success "CephFS filesystem '$FS_NAME' configured"
