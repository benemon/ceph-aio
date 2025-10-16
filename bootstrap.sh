#!/bin/bash
set -e

echo "=========================================="
echo "Bootstrapping Ceph All-in-One Cluster"
echo "=========================================="

# Cluster configuration
CLUSTER=ceph
FSID=${CEPH_FSID:-$(uuidgen)}
MON_NAME=$(hostname -s)
MGR_NAME=$(hostname -s)
OSD_COUNT=${OSD_COUNT:-1}

# Determine replication settings based on OSD count
# Scale intelligently: size = min(OSD_COUNT, 3), min_size = max(1, size - 1)
if [ "$OSD_COUNT" -le 3 ]; then
    POOL_SIZE=$OSD_COUNT
else
    POOL_SIZE=3  # Cap at 3 replicas (Ceph best practice)
fi
POOL_MIN_SIZE=$((POOL_SIZE > 1 ? POOL_SIZE - 1 : 1))

# Determine the actual IP to use for monmap
# If MON_IP is 0.0.0.0, find the container's actual IP
if [ "$MON_IP" = "0.0.0.0" ]; then
    # Get the container's IP address
    ACTUAL_MON_IP=$(hostname -i | awk '{print $1}')
else
    ACTUAL_MON_IP=$MON_IP
fi

echo "FSID: $FSID"
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

# Check if already bootstrapped
if [ -f /etc/ceph/ceph.conf ] && [ -f /var/lib/ceph/mon/ceph-$MON_NAME/done ]; then
    echo "Cluster already bootstrapped, skipping..."
    exit 0
fi

# Create ceph.conf
echo "Creating /etc/ceph/ceph.conf..."
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

# Create runtime directory for admin sockets
mkdir -p /var/run/ceph
chown ceph:ceph /var/run/ceph

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

# Generate supervisor config for OSDs
echo "Generating supervisor config for OSDs..."
for i in $(seq 0 $((OSD_COUNT - 1))); do
    cat >> /etc/supervisord.conf <<EOF

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

echo ""
echo "Bootstrap complete!"
echo "Starting supervisord to manage daemons..."
echo ""
