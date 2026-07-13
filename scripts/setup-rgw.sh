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

# Wait for OSDs to be up before creating the realm. radosgw-admin writes
# to the .rgw.root pool, and those operations race OSD startup (the OSD
# program has startsecs=35) if gated on the monitor alone.
OSD_COUNT=${OSD_COUNT:-1}
log "Waiting for $OSD_COUNT OSD(s) to be up (max 180s)"
elapsed=0
osds_up=0
while [ $elapsed -lt 180 ]; do
    osds_up=$(ceph osd stat -f json 2>/dev/null | grep -o '"num_up_osds":[0-9]*' | cut -d: -f2 || echo 0)
    if [ "${osds_up:-0}" -ge "$OSD_COUNT" ]; then
        break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done
if [ "${osds_up:-0}" -lt "$OSD_COUNT" ]; then
    error "Only ${osds_up:-0} of $OSD_COUNT OSD(s) up after 180s"
    exit 1
fi
success "$osds_up OSD(s) up, proceeding with RGW configuration"

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
    log "RGW zonegroup '$ZONEGROUP' already exists, ensuring it's attached to the realm and master"
    radosgw-admin zonegroup modify \
        --rgw-realm="$REALM" \
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
    log "RGW zone '$ZONE' already exists, ensuring it's attached to the realm and master"
    radosgw-admin zone modify \
        --rgw-realm="$REALM" \
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

# Tag RGW pools with the rgw application to avoid POOL_APP_NOT_ENABLED
# health warnings. Pools created via radosgw-admin (realm/zone setup) are
# not tagged automatically; non-fatal as the RGW daemon tags its own pools.
log "Enabling rgw application on RGW pools"
for pool in $(ceph osd pool ls | grep -E '^(\.rgw\.|default\.rgw\.)'); do
    ceph osd pool application enable "$pool" rgw 2>/dev/null || \
        log "Could not enable rgw application on pool '$pool' (may already be set)"
done

# Mark as configured. run-rgw.sh waits for this marker, so the daemon
# only ever starts against the committed realm/zone configuration.
mark_done "$MARKER_FILE" "RGW"

success "RGW realm/zonegroup/zone configured - S3/Swift endpoint will serve at $ENDPOINT"
