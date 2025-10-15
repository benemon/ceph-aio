#!/bin/bash
set -e

# Source common utilities
source /scripts/lib/common.sh

# Get OSD ID from argument
OSD_ID=$1
if [ -z "$OSD_ID" ]; then
    error "OSD ID not provided"
    exit 1
fi

# Configuration
OSD_DIR="/var/lib/ceph/osd/ceph-$OSD_ID"
KEYRING_PATH="$OSD_DIR/keyring"
FSID_FILE="$OSD_DIR/fsid"

log "Setting up OSD.$OSD_ID"

# Wait for cluster to be ready
sleep 30

# Wait for previous OSD to complete initialization (serialization to prevent race conditions)
if [ "$OSD_ID" -gt 0 ]; then
    PREV_OSD_ID=$((OSD_ID - 1))
    PREV_MARKER="/var/run/ceph/osd-${PREV_OSD_ID}-initialized"
    log "Waiting for OSD.$PREV_OSD_ID to complete initialization"
    wait_for_file "$PREV_MARKER" 120 || {
        error "Previous OSD.$PREV_OSD_ID did not complete initialization"
        exit 1
    }
    log "OSD.$PREV_OSD_ID is ready, proceeding with OSD.$OSD_ID"
fi

# Check if OSD already has keyring (already initialized)
if [ -f "$KEYRING_PATH" ]; then
    log "OSD.$OSD_ID already initialized, starting daemon"
else
    log "Initializing OSD.$OSD_ID for first time"

    # Read OSD UUID from bootstrap
    if [ ! -f "$FSID_FILE" ]; then
        error "OSD FSID file not found: $FSID_FILE"
        exit 1
    fi
    OSD_UUID=$(cat "$FSID_FILE")

    # Create OSD in cluster
    log "Creating OSD.$OSD_ID in cluster"
    ceph osd create "$OSD_UUID" || {
        error "Failed to create OSD in cluster"
        exit 1
    }

    # Create OSD authentication keyring
    log "Creating OSD.$OSD_ID keyring"
    ceph auth get-or-create "osd.$OSD_ID" \
        mon 'allow profile osd' \
        osd 'allow *' \
        mgr 'allow profile osd' \
        -o "$KEYRING_PATH" || {
        error "Failed to create OSD keyring"
        exit 1
    }

    # Set ownership
    chown -R ceph:ceph "$OSD_DIR" || {
        error "Failed to set OSD directory ownership"
        exit 1
    }

    # Initialize OSD with BlueStore
    log "Initializing OSD.$OSD_ID with BlueStore"
    ceph-osd --cluster ceph -i "$OSD_ID" --mkfs \
        --osd-uuid "$OSD_UUID" \
        --setuser ceph \
        --setgroup ceph || {
        error "Failed to initialize OSD"
        exit 1
    }

    success "OSD.$OSD_ID initialized"

    # Mark OSD as initialized for next OSD to proceed
    INIT_MARKER="/var/run/ceph/osd-${OSD_ID}-initialized"
    touch "$INIT_MARKER"
    log "Marked OSD.$OSD_ID as initialized"
fi

# Start OSD daemon (foreground mode for supervisor)
log "Starting OSD.$OSD_ID daemon"
exec /usr/bin/ceph-osd \
    --cluster ceph \
    -i "$OSD_ID" \
    --foreground \
    --setuser ceph \
    --setgroup ceph
