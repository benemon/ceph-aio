#!/bin/bash
# Container HEALTHCHECK: the cluster is ready once every setup one-shot
# has written its completion marker and the monitor answers queries.
# Consumers can gate on `docker inspect .State.Health.Status == healthy`
# instead of polling ceph commands themselves.

# mgr and auth always run; the rest are gated on their ENABLE_ flags
markers="mgr auth"
if [ "${ENABLE_DASHBOARD:-true}" = "true" ]; then markers="$markers dashboard"; fi
if [ "${ENABLE_RBD:-true}" = "true" ]; then markers="$markers rbd"; fi
if [ "${ENABLE_RGW:-true}" = "true" ]; then markers="$markers rgw"; fi
if [ "${ENABLE_CEPHFS:-true}" = "true" ]; then markers="$markers mds"; fi

for marker in $markers; do
    if [ ! -f "/var/run/ceph/${marker}-configured" ]; then
        echo "waiting: ${marker} setup not complete"
        exit 1
    fi
done

if ! ceph health >/dev/null 2>&1; then
    echo "unhealthy: monitor not responding"
    exit 1
fi

# Markers persist across container restart, but the MDS needs to
# rejoin before the filesystem is usable again — without this a
# restarted container reports healthy while CephFS is still degraded
if [ "${ENABLE_CEPHFS:-true}" = "true" ]; then
    if ! ceph mds stat 2>/dev/null | grep -q up:active; then
        echo "waiting: MDS not active"
        exit 1
    fi
fi

exit 0
