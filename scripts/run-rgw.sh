#!/bin/bash
# Run RADOS Gateway (RGW) daemon
#
# Waits for setup-rgw.sh to commit the realm/zone/period configuration,
# then starts the RADOS Gateway daemon in foreground mode for supervisor.
#
# The daemon must not start before the realm exists: an unconfigured RGW
# auto-creates an orphan default zonegroup/zone (realm_id "") that the
# setup script cannot commit a period against.
#
set -e

# Source common utilities
source /scripts/lib/common.sh

# Configuration
MARKER_FILE="/var/run/ceph/rgw-configured"

log "Starting RADOS Gateway (RGW) daemon"

# Wait for setup-rgw.sh to finish (it also creates the keyring)
wait_for_file "$MARKER_FILE" 300 || {
    error "RGW configuration marker not found after timeout"
    exit 1
}

# Start RGW daemon in foreground mode
log "RGW configuration complete, starting daemon"
exec /usr/bin/radosgw \
    -n client.rgw.gateway \
    --cluster ceph \
    --foreground \
    --setuser ceph \
    --setgroup ceph
