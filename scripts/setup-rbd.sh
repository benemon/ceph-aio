#!/bin/bash
set -e

# Source common utilities
source /scripts/lib/common.sh

# Configuration
POOL_NAME="rbd"
PG_NUM=32
MARKER_FILE="/var/run/ceph/rbd-configured"

log "Starting RBD pool setup"

# Check if already configured
if check_done "$MARKER_FILE" "RBD pool"; then
    exit 0
fi

# Wait for cluster to be ready
sleep 25  # Give OSDs time to come up

# Check if pool already exists
if ceph osd pool ls | grep -q "^${POOL_NAME}$"; then
    log "RBD pool '$POOL_NAME' already exists, skipping creation"
else
    log "Creating RBD pool with $PG_NUM PGs"
    ceph osd pool create "$POOL_NAME" "$PG_NUM" || {
        error "Failed to create RBD pool"
        exit 1
    }
fi

# Enable RBD application on pool
log "Enabling RBD application on pool"
ceph osd pool application enable "$POOL_NAME" rbd || {
    # May already be enabled, check if that's why it failed
    if ceph osd pool application get "$POOL_NAME" rbd &>/dev/null; then
        log "RBD application already enabled on pool"
    else
        error "Failed to enable RBD application"
        exit 1
    fi
}

# Initialize RBD pool
log "Initializing RBD pool"
rbd pool init "$POOL_NAME" || {
    error "Failed to initialize RBD pool"
    exit 1
}

# Mark as configured
mark_done "$MARKER_FILE" "RBD pool"

success "RBD pool '$POOL_NAME' ready for use"
