#!/bin/bash
set -e

# Source common utilities
source /scripts/lib/common.sh

# Configuration
KEYRING_PATH="/var/lib/ceph/radosgw/ceph-rgw.gateway/keyring"
REALM="default"
ZONEGROUP="default"
ZONE="default"
ENDPOINT="http://0.0.0.0:8000"
MARKER_FILE="/var/run/ceph/rgw-configured"

log "Starting RGW (RADOS Gateway) setup"

# Check if already configured
if check_done "$MARKER_FILE" "RGW"; then
    exit 0
fi

# Wait for cluster to be ready
log "Waiting for Ceph cluster to be ready..."
wait_for_cluster || {
    error "Cluster not ready, cannot configure RGW"
    exit 1
}

# Additional wait for OSDs to stabilize (they have 35s startsecs)
# This is more reliable than checking osd stat which may not reflect actual readiness
sleep 10

# Create RGW keyring
log "Creating RGW keyring"
ceph auth get-or-create client.rgw.gateway \
    mon 'allow rw' \
    osd 'allow rwx' \
    -o "$KEYRING_PATH" || {
    error "Failed to create RGW keyring"
    exit 1
}

# Set ownership
chown -R ceph:ceph /var/lib/ceph/radosgw || {
    error "Failed to set RGW directory ownership"
    exit 1
}

# Check if realm already exists
if radosgw-admin realm list 2>/dev/null | grep -q "\"$REALM\""; then
    log "RGW realm '$REALM' already exists, skipping creation"
else
    log "Creating RGW realm: $REALM"
    radosgw-admin realm create --rgw-realm="$REALM" --default || {
        error "Failed to create RGW realm"
        exit 1
    }
fi

# Check if zonegroup already exists
if radosgw-admin zonegroup list 2>/dev/null | grep -q "\"$ZONEGROUP\""; then
    log "RGW zonegroup '$ZONEGROUP' already exists, ensuring it's configured as master"
    radosgw-admin zonegroup modify \
        --rgw-zonegroup="$ZONEGROUP" \
        --endpoints="$ENDPOINT" \
        --master \
        --default || {
        error "Failed to configure RGW zonegroup as master"
        exit 1
    }
else
    log "Creating RGW zonegroup: $ZONEGROUP"
    radosgw-admin zonegroup create \
        --rgw-zonegroup="$ZONEGROUP" \
        --endpoints="$ENDPOINT" \
        --rgw-realm="$REALM" \
        --master \
        --default || {
        error "Failed to create RGW zonegroup"
        exit 1
    }
fi

# Check if zone already exists
if radosgw-admin zone list 2>/dev/null | grep -q "\"$ZONE\""; then
    log "RGW zone '$ZONE' already exists, ensuring it's configured as master"
    radosgw-admin zone modify \
        --rgw-zonegroup="$ZONEGROUP" \
        --rgw-zone="$ZONE" \
        --endpoints="$ENDPOINT" \
        --master \
        --default || {
        error "Failed to configure RGW zone as master"
        exit 1
    }
else
    log "Creating RGW zone: $ZONE"
    radosgw-admin zone create \
        --rgw-zonegroup="$ZONEGROUP" \
        --rgw-zone="$ZONE" \
        --endpoints="$ENDPOINT" \
        --master \
        --default || {
        error "Failed to create RGW zone"
        exit 1
    }
fi

# Commit period configuration
log "Committing RGW period configuration"
radosgw-admin period update --commit || {
    error "Failed to commit RGW period"
    exit 1
}

# Mark as configured
mark_done "$MARKER_FILE" "RGW"

success "RGW realm/zonegroup/zone configured"

# Restart RGW daemon to pick up new configuration
# This ensures RGW connects with the proper realm/zone settings
log "Restarting RGW daemon to apply configuration"

if command -v supervisorctl &>/dev/null; then
    supervisorctl restart ceph-rgw || {
        error "Failed to restart RGW daemon"
        exit 1
    }
    success "RGW daemon restarted - S3/Swift endpoint ready at $ENDPOINT"
else
    log "supervisorctl not available, RGW will need manual restart"
fi
