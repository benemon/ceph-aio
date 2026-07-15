#!/bin/bash
set -e

echo "=========================================="
echo "Bootstrapping Ceph All-in-One Cluster"
echo "=========================================="

source /scripts/lib/config.sh
source /scripts/lib/common.sh

# Cluster configuration
CLUSTER=ceph
OSD_COUNT=${OSD_COUNT:-1}

# Stable node identity: recorded on first bootstrap (see below) so a
# recreated container with persistent volumes keeps addressing the same
# mon/mgr data despite a fresh random hostname
MON_NAME=$(ceph_node_name)
MGR_NAME=$MON_NAME

# Determine replication settings based on OSD count
# Scale intelligently: size = min(OSD_COUNT, 3), min_size = max(1, size - 1)
POOL_SIZE=$(calc_pool_size "$OSD_COUNT")
POOL_MIN_SIZE=$(calc_pool_min_size "$POOL_SIZE")

# Determine the actual IP to use for monmap
# If MON_IP is 0.0.0.0, find the container's actual IP. Prefer the
# default route's source address: it is by definition bound to a local
# interface. hostname -i can resolve to an address that no interface
# holds (KubeVirt/masquerade VMs resolve the pod-network IP, NAT'd on
# the far side) and the mon then crash-loops on bind.
if [ "$MON_IP" = "0.0.0.0" ]; then
    ACTUAL_MON_IP=$(route_src_ip "$(ip route get 1.0.0.1 2>/dev/null)")
    if [ -z "$ACTUAL_MON_IP" ]; then
        ACTUAL_MON_IP=$(hostname -i | awk '{print $1}')
    fi
else
    ACTUAL_MON_IP=$MON_IP
fi

echo "MON: $MON_NAME"
echo "MGR: $MGR_NAME"
echo "OSDs: $OSD_COUNT"
echo "OSD Size: ${OSD_SIZE:-10G}"
echo "Pool Size: $POOL_SIZE (min: $POOL_MIN_SIZE)"
echo "MON_IP (bind): $MON_IP"
echo "MON_IP (advertise): $ACTUAL_MON_IP"
echo ""

# Export for supervisor to use
export MON_NAME
export MGR_NAME

# Runtime directory for admin sockets and setup markers; container-local,
# so it must exist on every boot, not just first bootstrap
mkdir -p /var/run/ceph
chown ceph:ceph /var/run/ceph

# Supervisor programs for the OSDs are regenerated on every boot: this
# config lives in the container filesystem, not on a data volume, so a
# recreated container must rebuild it to start the OSDs whose data
# already exists on disk
echo "Generating supervisor config for $OSD_COUNT OSD(s)..."
mkdir -p /etc/supervisord.d
OSD_SUPERVISOR_CONF=/etc/supervisord.d/ceph-osds.conf
: > "$OSD_SUPERVISOR_CONF"
for i in $(seq 0 $((OSD_COUNT - 1))); do
    cat >> "$OSD_SUPERVISOR_CONF" <<EOF
[program:ceph-osd-$i]
command=/scripts/setup-osd.sh $i
autostart=true
autorestart=true
startsecs=35
priority=$((30 + i))
stdout_logfile=/var/log/supervisor/ceph-osd-$i.log
stderr_logfile=/var/log/supervisor/ceph-osd-$i-error.log

EOF
done

# CephFS is opt-in: its supervisor programs are also regenerated per
# boot so toggling ENABLE_CEPHFS on a recreated container takes effect
MDS_SUPERVISOR_CONF=/etc/supervisord.d/ceph-mds.conf
if [ "${ENABLE_CEPHFS:-false}" = "true" ]; then
    echo "CephFS enabled, generating MDS supervisor config..."
    cat > "$MDS_SUPERVISOR_CONF" <<EOF
[program:mds-setup]
command=/scripts/setup-mds.sh
autostart=true
autorestart=unexpected
exitcodes=0
startsecs=0
priority=115
stdout_logfile=/var/log/supervisor/mds-setup.log
stderr_logfile=/var/log/supervisor/mds-setup-error.log

[program:ceph-mds]
command=/scripts/run-mds.sh
autostart=true
autorestart=true
startsecs=15
priority=118
stdout_logfile=/var/log/supervisor/ceph-mds.log
stderr_logfile=/var/log/supervisor/ceph-mds-error.log
EOF
else
    rm -f "$MDS_SUPERVISOR_CONF"
fi

# ceph.conf is regenerated on every boot from the recorded cluster
# identity plus the current environment, so the advertised monitor
# address always matches the container's actual IP
write_ceph_conf() {
    cat > /etc/ceph/ceph.conf <<EOF
[global]
fsid = $FSID
mon initial members = $MON_NAME
mon host = $ACTUAL_MON_IP
public network = $CEPH_PUBLIC_NETWORK
cluster network = $CEPH_CLUSTER_NETWORK
auth cluster required = cephx
auth service required = cephx
auth client required = cephx
osd pool default size = $POOL_SIZE
osd pool default min size = $POOL_MIN_SIZE
osd pool default pg num = 8
osd pool default pgp num = 8
osd crush chooseleaf type = 0
osd max object name len = 256
bluestore_block_size = 1073741824
ms bind msgr2 = true
ms bind ipv4 = true
ms bind ipv6 = false

[mon]
mon_allow_pool_delete = true
mon_max_pg_per_osd = 500

[mon.$MON_NAME]
host = $MON_NAME
mon addr = [v2:$ACTUAL_MON_IP:3300,v1:$ACTUAL_MON_IP:6789]
public addr = $ACTUAL_MON_IP

[osd]
osd objectstore = bluestore

[client.rgw.gateway]
host = $MON_NAME
rgw frontends = beast endpoint=0.0.0.0:8000
rgw dns name = $MON_NAME
keyring = /var/lib/ceph/radosgw/ceph-rgw.gateway/keyring
EOF
}

# Reconfigure-only path: the cluster already exists (same container
# restarted, or a new container over persistent volumes)
if [ -f /etc/ceph/ceph.conf ] && [ -f /var/lib/ceph/mon/ceph-$MON_NAME/done ]; then
    echo "Cluster already bootstrapped, refreshing runtime configuration..."

    FSID=$(awk '/^fsid = /{print $3}' /etc/ceph/ceph.conf)
    OLD_MON_IP=$(awk '/^mon host = /{print $4}' /etc/ceph/ceph.conf)
    echo "FSID: $FSID"

    write_ceph_conf

    if [ -n "$OLD_MON_IP" ] && [ "$OLD_MON_IP" != "$ACTUAL_MON_IP" ]; then
        echo "Monitor address changed ($OLD_MON_IP -> $ACTUAL_MON_IP), rewriting monmap..."
        MONMAP_TMP=/var/lib/ceph/tmp/monmap.refresh
        mkdir -p /var/lib/ceph/tmp
        ceph-mon --cluster $CLUSTER -i "$MON_NAME" --extract-monmap "$MONMAP_TMP"
        monmaptool --rm "$MON_NAME" "$MONMAP_TMP"
        monmaptool --addv "$MON_NAME" "[v2:$ACTUAL_MON_IP:3300,v1:$ACTUAL_MON_IP:6789]" "$MONMAP_TMP"
        ceph-mon --cluster $CLUSTER -i "$MON_NAME" --inject-monmap "$MONMAP_TMP"
        rm -f "$MONMAP_TMP"
        chown -R ceph:ceph "/var/lib/ceph/mon/ceph-$MON_NAME"
        echo "Monmap updated."
    fi

    chown -R ceph:ceph /etc/ceph
    echo ""
    echo "Runtime configuration refreshed!"
    echo "Starting supervisord to manage daemons..."
    echo ""
    exit 0
fi

# First bootstrap
FSID=${CEPH_FSID:-$(uuidgen)}
echo "FSID: $FSID"

# Record the node identity for future boots (lives on the /etc/ceph
# volume when one is mounted)
echo "$MON_NAME" > /etc/ceph/node_name

# Create ceph.conf
echo "Creating /etc/ceph/ceph.conf..."
write_ceph_conf

# Create client.admin keyring
echo "Creating admin keyring..."
ceph-authtool --create-keyring /etc/ceph/ceph.client.admin.keyring \
    --gen-key -n client.admin --cap mon 'allow *' --cap osd 'allow *' \
    --cap mds 'allow *' --cap mgr 'allow *'

# Create monitor keyring
echo "Creating monitor keyring..."
ceph-authtool --create-keyring /var/lib/ceph/tmp/ceph.mon.keyring \
    --gen-key -n mon. --cap mon 'allow *'

# Add client.admin keyring to monitor keyring
ceph-authtool /var/lib/ceph/tmp/ceph.mon.keyring \
    --import-keyring /etc/ceph/ceph.client.admin.keyring

# Create monitor map
echo "Creating monitor map..."
monmaptool --create --addv $MON_NAME [v2:$ACTUAL_MON_IP:3300,v1:$ACTUAL_MON_IP:6789] --fsid $FSID \
    /var/lib/ceph/tmp/monmap

# Bootstrap monitor daemon
echo "Bootstrapping monitor..."
mkdir -p /var/lib/ceph/mon/ceph-$MON_NAME
ceph-mon --cluster ${CLUSTER} --mkfs -i $MON_NAME \
    --monmap /var/lib/ceph/tmp/monmap \
    --keyring /var/lib/ceph/tmp/ceph.mon.keyring

# Mark monitor as bootstrapped
touch /var/lib/ceph/mon/ceph-$MON_NAME/done

# Set ownership
chown -R ceph:ceph /var/lib/ceph/mon/ceph-$MON_NAME /etc/ceph

# Bootstrap manager
echo "Bootstrapping manager..."
mkdir -p /var/lib/ceph/mgr/ceph-$MGR_NAME

# Manager keyring will be created by supervisor after mon starts

# Create RGW directory
echo "Creating RGW directory..."
mkdir -p /var/lib/ceph/radosgw/ceph-rgw.gateway

# Create OSDs
echo "Bootstrapping $OSD_COUNT OSDs..."
for i in $(seq 0 $((OSD_COUNT - 1))); do
    OSD_DIR="/var/lib/ceph/osd/ceph-$i"

    # Skip if already exists
    if [ -f $OSD_DIR/ready ]; then
        echo "OSD.$i already exists, skipping..."
        continue
    fi

    echo "Creating OSD.$i..."

    # Create OSD directory
    mkdir -p $OSD_DIR

    # Create a file-backed block device with configurable size
    truncate -s ${OSD_SIZE:-10G} $OSD_DIR/block

    # Create a simple file-backed OSD
    OSD_UUID=$(uuidgen)

    # Write OSD info for supervisor to use
    echo $i > $OSD_DIR/whoami
    echo $OSD_UUID > $OSD_DIR/fsid

    # Mark as ready for mkfs (will be done after cluster is up)
    touch $OSD_DIR/ready

    echo "OSD.$i prepared with UUID $OSD_UUID"
done

echo ""
echo "Bootstrap complete!"
echo "Starting supervisord to manage daemons..."
echo ""
