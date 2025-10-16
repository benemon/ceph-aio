#!/bin/bash
set -e

# Source common utilities
source /scripts/lib/common.sh

MARKER_FILE="/var/run/ceph/auth-configured"

log "Starting authentication configuration"

# Check if already configured
if check_done "$MARKER_FILE" "Auth"; then
    exit 0
fi

# Wait for cluster to be ready
log "Waiting for Ceph cluster to be ready..."
wait_for_cluster || {
    error "Cluster not ready, cannot configure authentication"
    exit 1
}

# Configure cephx authentication settings
log "Configuring cephx authentication"
ceph config set mon auth_supported cephx || {
    error "Failed to set auth_supported"
    exit 1
}

ceph config set mon auth_cluster_required cephx || {
    error "Failed to set auth_cluster_required"
    exit 1
}

ceph config set mon auth_service_required cephx || {
    error "Failed to set auth_service_required"
    exit 1
}

ceph config set mon auth_client_required cephx || {
    error "Failed to set auth_client_required"
    exit 1
}

# Disable insecure global ID reclaim (security best practice)
ceph config set mon auth_allow_insecure_global_id_reclaim false || {
    error "Failed to disable insecure global ID reclaim"
    exit 1
}

# Mark as configured
mark_done "$MARKER_FILE" "Auth"

success "Cephx authentication configured"
