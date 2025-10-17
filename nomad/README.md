# Nomad Deployment Guide

This guide covers deploying the Ceph All-in-One container using HashiCorp Nomad.

## Quick Start with Nomad

```bash
# Submit the job to Nomad
nomad job run nomad/ceph-aio.nomad.hcl

# Check job status
nomad job status ceph-aio

# View logs
nomad alloc logs -f <allocation-id>

# Stop the job
nomad job stop ceph-aio
```

## Nomad Job Features

The provided [ceph-aio.nomad.hcl](ceph-aio.nomad.hcl) includes:

- **Host networking**: Uses the host's network stack for proper MON IP advertisement
- **Podman driver**: Runs via Nomad's native Podman task driver
- **Resource allocation**: 4 CPU cores, 8GB RAM (adjust as needed)
- **Pre-configured environment**: Sensible defaults for development/testing
- **Multi-version support**: Easily switch between Ceph versions by changing the image tag

## Configuration

The job spec uses environment variables to configure the cluster:

```hcl
env {
  MON_IP = "0.0.0.0"                    # Uses host's IP automatically
  OSD_COUNT = "1"                       # Single OSD for dev/test
  OSD_SIZE = "10G"                      # 10GB per OSD
  CEPH_PUBLIC_NETWORK = "0.0.0.0/0"     # Allow all client traffic
  CEPH_CLUSTER_NETWORK = "0.0.0.0/0"    # Allow all OSD traffic
  DASHBOARD_USER = "admin"
  DASHBOARD_PASS = "admin@ceph123"
}
```

**Customization tips:**
- **Multiple OSDs**: Set `OSD_COUNT = "3"` for replication testing
- **Larger storage**: Set `OSD_SIZE = "50G"` for more capacity
- **Network restrictions**: Set `CEPH_PUBLIC_NETWORK` to your specific CIDR (e.g., `"10.0.0.0/8"`)
- **Secure credentials**: Use Nomad's [Vault integration](https://developer.hashicorp.com/nomad/docs/job-specification/template#vault-integration) for sensitive data

## Accessing Services in Nomad

When deployed with host networking, services are accessible on the Nomad client's IP:

```bash
# Access Ceph dashboard
echo "Dashboard: https://<nomad-client-ip>:8443"

# Connect with Ceph CLI
nomad alloc exec <allocation-id> ceph -s

# Test S3 endpoint
aws --endpoint-url http://<nomad-client-ip>:8000 s3 ls
```

## Integration with Ceph-CSI

This container is designed to work with the [Ceph CSI driver](https://github.com/ceph/ceph-csi) for Kubernetes/Nomad:

**Key features for CSI integration:**
- **Dual protocol support**: MON listens on both v2 (port 3300) and v1 (port 6789)
- **Cephx authentication**: Fully configured and enabled by default
- **RBD pool**: Pre-configured and ready for block storage
- **Host networking**: Ensures CSI driver can connect to the correct MON IP

**Example CSI configuration** (for Kubernetes/Nomad):
```yaml
monitors:
  - "<host-ip>:6789"    # v1 protocol (CSI driver default)
  - "<host-ip>:3300"    # v2 protocol (optional)
```

The authentication credentials are available inside the container:
```bash
# Get client.admin keyring for CSI driver
nomad alloc exec <allocation-id> ceph auth get-key client.admin
```

## Production Considerations

While this deployment is suitable for development and CI/CD pipelines, consider these points for production use:

- **Persistence**: Add Nomad volume mounts for `/var/lib/ceph` and `/etc/ceph`
- **Resource limits**: Increase CPU/memory based on workload requirements
- **Network isolation**: Configure specific CIDR ranges for public/cluster networks
- **Monitoring**: Integrate with your monitoring stack (Prometheus, Grafana, etc.)
- **Backup strategy**: Regular snapshots of OSD data volumes
- **High availability**: This is a single-node cluster - not suitable for production HA requirements

For production Ceph deployments, consider using [Rook](https://rook.io/) or official Ceph deployment tools like [cephadm](https://docs.ceph.com/en/latest/cephadm/).

## Adding Persistence

To persist cluster data between container restarts, add volume mounts to the job spec:

```hcl
task "ceph-aio" {
  driver = "podman"

  config {
    image = "quay.io/benjamin_holmes/ceph-aio:v19"
    network_mode = "host"

    volumes = [
      "/opt/ceph-data:/var/lib/ceph",
      "/opt/ceph-config:/etc/ceph"
    ]
  }

  # ... rest of config
}
```

The bootstrap script is idempotent - it will skip setup if the cluster is already initialized.

## Troubleshooting

### Check Container Status

```bash
# Check supervisor status
nomad alloc exec <allocation-id> supervisorctl status

# View specific daemon logs
nomad alloc exec <allocation-id> tail -100 /var/log/supervisor/ceph-mon.log
nomad alloc exec <allocation-id> tail -100 /var/log/supervisor/ceph-osd-0.log
```

### Check Cluster Health

```bash
# Get Ceph cluster status
nomad alloc exec <allocation-id> ceph -s

# Get detailed health info
nomad alloc exec <allocation-id> ceph health detail

# Check OSD status
nomad alloc exec <allocation-id> ceph osd tree
```

### Access Dashboard

```bash
# Access dashboard at the Nomad client IP where the job is running
echo "Dashboard: https://<nomad-client-ip>:8443"
echo "Username: admin"
echo "Password: admin@ceph123"
```

### Restart the Job

```bash
# Stop the job
nomad job stop ceph-aio

# Wait for it to fully stop
nomad job status ceph-aio

# Start again
nomad job run nomad/ceph-aio.nomad.hcl
```

## Alternative: Bridge Networking

If you prefer bridge networking instead of host networking, you can modify the job spec:

```hcl
config {
  image = "quay.io/benjamin_holmes/ceph-aio:v19"
  network_mode = "bridge"

  ports = [
    "mon_v2",
    "mon_v1",
    "dashboard",
    "rgw"
  ]
}

# Port mappings
resources {
  network {
    port "mon_v2" {
      static = 3300
      to = 3300
    }
    port "mon_v1" {
      static = 6789
      to = 6789
    }
    port "dashboard" {
      static = 8443
      to = 8443
    }
    port "rgw" {
      static = 8000
      to = 8000
    }
  }
}
```

**Note**: Host networking is recommended for simplicity and to ensure the MON advertises the correct IP address for external clients like Ceph-CSI.
