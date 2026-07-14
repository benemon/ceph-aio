#!/bin/bash
# Container HEALTHCHECK: the cluster is ready once every setup one-shot
# has written its completion marker and the monitor answers queries.
# Consumers can gate on `docker inspect .State.Health.Status == healthy`
# instead of polling ceph commands themselves.

markers="mgr auth dashboard rbd rgw"
if [ "${ENABLE_CEPHFS:-false}" = "true" ]; then
    markers="$markers mds"
fi

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

exit 0
