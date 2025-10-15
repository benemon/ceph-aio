#!/bin/bash
set -e

# Source common utilities
source /scripts/lib/common.sh

# Configuration (with environment variable overrides)
DASHBOARD_USER="${DASHBOARD_USER:-admin}"
DASHBOARD_PASS="${DASHBOARD_PASS:-admin@ceph123}"
MARKER_FILE="/var/run/ceph/dashboard-configured"

log "Starting dashboard setup"

# Check if already configured
if check_done "$MARKER_FILE" "Dashboard"; then
    exit 0
fi

# Wait for manager to be available
sleep 15  # Give MGR time to fully start

# Enable dashboard module
log "Enabling dashboard module"
ceph mgr module enable dashboard || {
    error "Failed to enable dashboard module"
    exit 1
}

# Enable RGW module for dashboard integration
log "Enabling RGW module for dashboard"
ceph mgr module enable rgw || {
    error "Failed to enable RGW module"
    exit 1
}

# Create self-signed certificate
log "Creating self-signed certificate"
ceph dashboard create-self-signed-cert || {
    error "Failed to create certificate"
    exit 1
}

# Create admin user (check if exists first)
if ceph dashboard ac-user-show "$DASHBOARD_USER" &>/dev/null; then
    log "Dashboard user '$DASHBOARD_USER' already exists, skipping creation"
else
    log "Creating dashboard admin user"
    echo "$DASHBOARD_PASS" > /tmp/dashboard-pass
    ceph dashboard ac-user-create "$DASHBOARD_USER" -i /tmp/dashboard-pass administrator || {
        error "Failed to create dashboard user"
        rm -f /tmp/dashboard-pass
        exit 1
    }
    rm -f /tmp/dashboard-pass
fi

# Configure dashboard settings
log "Configuring dashboard settings"
ceph config set mgr mgr/dashboard/server_addr 0.0.0.0 || {
    error "Failed to set dashboard server address"
    exit 1
}

ceph config set mgr mgr/dashboard/server_port 8443 || {
    error "Failed to set dashboard server port"
    exit 1
}

ceph config set mgr mgr/dashboard/ssl true || {
    error "Failed to enable dashboard SSL"
    exit 1
}

# Mark as configured
mark_done "$MARKER_FILE" "Dashboard"

success "Dashboard setup complete - accessible at https://0.0.0.0:8443"
success "Username: $DASHBOARD_USER, Password: $DASHBOARD_PASS"
