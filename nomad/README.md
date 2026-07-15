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

## Docker Driver

The shipped spec uses the Podman task driver. If your Nomad clients run
the Docker driver instead, use
[ceph-aio-docker.nomad.hcl](ceph-aio-docker.nomad.hcl) — it is
identical apart from the driver:

```hcl
task "ceph-aio" {
  driver = "docker"

  config {
    image        = "quay.io/benjamin_holmes/ceph-aio:v20"
    network_mode = "host"
  }
  # env and resources as in the podman spec
}
```

```bash
nomad job run nomad/ceph-aio-docker.nomad.hcl
```

Everything else in this guide (configuration, readiness, persistence,
networking trade-offs) applies to both drivers.

## Configuration

The job spec uses environment variables to configure the cluster:

```hcl
env {
  MON_IP = "0.0.0.0"                    # Auto-detects the host's routable IP
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
- **Pinned MON IP**: `MON_IP = "0.0.0.0"` auto-detects via the default route's source address, which is correct even on NAT'd hosts (e.g. KubeVirt/OpenShift Virtualization masquerade VMs, where DNS resolves the unbindable pod IP). If your routing makes detection pick the wrong interface, set `MON_IP` to the host's actual interface IP (`ip route get 1.1.1.1`)
- **Slimmer clusters**: every subsystem is on by default; set `ENABLE_RGW`, `ENABLE_DASHBOARD`, `ENABLE_RBD` or `ENABLE_CEPHFS` to `"false"` to trim what you don't need (e.g. RBD-only for Ceph-CSI work — disabling RGW skips the slowest setup step)
- **CI/constrained hosts**: Set `DISABLE_MON_DISK_WARNINGS = "true"` if the host filesystem is tight on space
- **Secure credentials**: Use Nomad's [Vault integration](https://developer.hashicorp.com/nomad/docs/job-specification/template#vault-integration) for sensitive data

## Readiness

The image ships a readiness probe (`/scripts/healthcheck.sh`) that
succeeds once every enabled subsystem's setup has completed and the
monitor responds. How much of that contract a Nomad service check can
express depends on your service discovery:

- **Nomad-native services** (what the shipped specs use) support only
  `tcp`/`http` checks — script checks are not valid with
  `provider = "nomad"`. The specs therefore ship a tcp check on the
  monitor port: it gates on "monitor reachable", which is weaker than
  the full contract.
- **Consul service discovery** supports script checks, so Consul users
  can get the full readiness contract:

  ```hcl
  service {
    name     = "ceph-aio"
    provider = "consul"

    check {
      type     = "script"
      command  = "/scripts/healthcheck.sh"
      interval = "15s"
      timeout  = "10s"
    }
  }
  ```

- **Without Consul**, gate on the probe out-of-band — it exits 0 only
  when the cluster is fully configured:

  ```bash
  until nomad alloc exec <allocation-id> /scripts/healthcheck.sh; do sleep 5; done
  ```

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
- **CephFS with a `csi` subvolume group**: Pre-created, ready for RWX volumes
- **Host networking**: Ensures CSI driver can connect to the correct MON IP

Runnable, tested examples live in [examples/](examples/):

- [examples/csi-rbd/](examples/csi-rbd/) — plugin job, dynamic block
  volume, consumer, plus snapshots, clone-from-snapshot and static
  volume registration
- [examples/csi-cephfs/](examples/csi-cephfs/) — plugin job, RWX
  filesystem volume, consumer

The authentication credentials are available inside the container:
```bash
# Get FSID and client.admin key for the CSI cluster map
nomad alloc exec <allocation-id> ceph fsid
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

To persist cluster data across allocation restarts *and recreation*
(reschedules, redeploys, `job stop`/`run`), add volume mounts to the
job spec:

```hcl
task "ceph-aio" {
  driver = "podman"

  config {
    image = "quay.io/benjamin_holmes/ceph-aio:v20"
    network_mode = "host"

    volumes = [
      "/opt/ceph-data:/var/lib/ceph",
      "/opt/ceph-config:/etc/ceph"
    ]
  }

  # ... rest of config
}
```

The container is recreation-safe: its monitor identity is recorded on
the config volume and its runtime wiring (OSD supervisor programs,
ceph.conf, the monitor's advertised address) regenerates on every
boot, so a brand-new allocation over the same volumes comes back with
its data intact. Two caveats:

- Run the new allocation with the same `OSD_COUNT` the volumes were
  created with.
- Host-path volumes as shown do not follow the job across nodes - pin
  the job with a [constraint](https://developer.hashicorp.com/nomad/docs/job-specification/constraint)
  to the node holding the data, or use a Nomad host volume.

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

If you prefer bridge networking instead of host networking, define the
ports at the group level (Nomad 0.12+ syntax):

```hcl
group "ceph" {
  network {
    mode = "bridge"

    port "mon_v2"    { static = 3300, to = 3300 }
    port "mon_v1"    { static = 6789, to = 6789 }
    port "dashboard" { static = 8443, to = 8443 }
    port "rgw"       { static = 8000, to = 8000 }
  }

  task "ceph-aio" {
    driver = "podman"

    config {
      image = "quay.io/benjamin_holmes/ceph-aio:v20"
      ports = ["mon_v2", "mon_v1", "dashboard", "rgw"]
    }
    # ...
  }
}
```

**Note**: With bridge networking only the HTTP services (S3 on 8000,
dashboard on 8443) are usable from outside the host: RADOS clients
connect to the MON and are then redirected to the OSDs at their
advertised container-internal address, which port mapping cannot
carry. Host networking is therefore required for external RADOS/RBD
clients such as Ceph-CSI. When testing the S3 endpoint through a
mapped port, use an IP address rather than a hostname - RGW applies
virtual-host bucket parsing to unrecognised hostnames.
