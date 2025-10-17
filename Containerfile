# Use a specific Ceph version
ARG CEPH_VERSION=v19
FROM quay.io/ceph/ceph:${CEPH_VERSION}

# Install minimal dependencies
RUN dnf install -y \
    supervisor \
    uuid \
    hostname \
    procps-ng \
    iproute \
    && dnf clean all

# Create directory structure
RUN mkdir -p \
    /var/lib/ceph/mon \
    /var/lib/ceph/mgr \
    /var/lib/ceph/osd \
    /var/lib/ceph/mds \
    /var/lib/ceph/radosgw \
    /var/lib/ceph/bootstrap-osd \
    /var/lib/ceph/bootstrap-rgw \
    /var/lib/ceph/bootstrap-mds \
    /var/lib/ceph/tmp \
    /etc/ceph \
    /var/log/supervisor

# Copy configuration and scripts
COPY supervisord.conf /etc/supervisord.conf
COPY bootstrap.sh /bootstrap.sh
COPY entrypoint.sh /entrypoint.sh
COPY scripts/ /scripts/
RUN chmod +x /bootstrap.sh /entrypoint.sh /scripts/*.sh /scripts/lib/*.sh

# Expose Ceph ports
# 3300: Monitor (msgr2 protocol - preferred)
# 6789: Monitor (msgr1 protocol - legacy)
# 6800-7300: OSDs, MGRs, MDSs
# 8000: RadosGW (HTTP)
# 8443: Dashboard (HTTPS)
EXPOSE 3300 6789 6800-7300 8000 8443

# Set environment defaults
ENV MON_IP=0.0.0.0 \
    OSD_COUNT=1 \
    OSD_SIZE=10G \
    CEPH_PUBLIC_NETWORK=0.0.0.0/0 \
    CEPH_CLUSTER_NETWORK=0.0.0.0/0 \
    DASHBOARD_USER=admin \
    DASHBOARD_PASS=admin@ceph123

WORKDIR /

ENTRYPOINT ["/entrypoint.sh"]
