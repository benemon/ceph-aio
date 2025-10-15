#!/bin/bash
set -e

# Source common utilities
source /scripts/lib/common.sh

# Configuration
MGR_NAME=$(hostname -s)
KEYRING_PATH="/var/lib/ceph/mgr/ceph-$MGR_NAME/keyring"
MARKER_FILE="/var/run/ceph/mgr-configured"

log "Starting manager bootstrap"

# Check if already configured
if check_done "$MARKER_FILE" "Manager"; then
    exit 0
fi

# Wait for monitor to be available
wait_for_cluster || {
    error "Monitor not available"
    exit 1
}

# Configure PG limits for single-OSD development setup
log "Configuring PG limits for single-OSD setup"
ceph config set mon mon_max_pg_per_osd 500 || {
    error "Failed to set mon_max_pg_per_osd"
    exit 1
}

log "Disabling PG autoscaler (required for single-OSD RGW realm creation)"
ceph config set global osd_pool_default_pg_autoscale_mode off || {
    error "Failed to disable PG autoscaler"
    exit 1
}

# Disable insecure global_id reclaim (security best practice)
log "Disabling insecure global_id reclaim (CVE-2021-20288)"
ceph config set mon auth_allow_insecure_global_id_reclaim false || {
    error "Failed to disable insecure global_id reclaim"
    exit 1
}

# Conditionally silence pool redundancy warnings (only for single-OSD setups)
OSD_COUNT=${OSD_COUNT:-1}
if [ "$OSD_COUNT" -eq 1 ]; then
    log "Disabling pool redundancy warnings for single-OSD setup"
    ceph config set mon mon_warn_on_pool_no_redundancy false || {
        error "Failed to disable pool redundancy warnings"
        exit 1
    }
else
    log "Multiple OSDs detected ($OSD_COUNT), keeping redundancy warnings enabled"
fi

# Create manager keyring
log "Creating manager keyring"
ceph auth get-or-create "mgr.$MGR_NAME" \
    mon 'allow profile mgr' \
    osd 'allow *' \
    mds 'allow *' \
    -o "$KEYRING_PATH" || {
    error "Failed to create manager keyring"
    exit 1
}

# Set ownership
chown -R ceph:ceph "/var/lib/ceph/mgr/ceph-$MGR_NAME" || {
    error "Failed to set ownership"
    exit 1
}

# Mark as configured
mark_done "$MARKER_FILE" "Manager"

success "Manager bootstrap complete"
