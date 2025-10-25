[![Build and Publish Ceph AIO](https://github.com/benemon/ceph-aio/actions/workflows/build-and-publish.yml/badge.svg)](https://github.com/benemon/ceph-aio/actions/workflows/build-and-publish.yml)

# Ceph All-in-One Development Container

A single-container Ceph cluster for development and testing purposes, built using `quay.io/ceph/ceph` with supervisord managing all daemons.

This is designed to supercede the functionality previously found in the `ceph/daemon` container running in `demo` mode.

## Images 

Container images for `ceph-aio` are built weekly and can be pulled from `quay.io/benjamin_holmes/ceph-aio`. The images are tagged in line with the currently supported [Ceph stable releases](https://docs.ceph.com/en/latest/releases/#active-releases) e.g:

* `quay.io/benjamin_holmes/ceph-aio:v18`
* `quay.io/benjamin_holmes/ceph-aio:v19`

Container images for this repository support `linux/amd64` and `linux/arm64`, in accordance with the Ceph projects' own container build process.

In addition, each weekly image build also produces a datestamped tag to allow a more predictable pull target. Be aware that in order to keep housekeeping of these simple, these will expire and be pruned from Quay after 4 weeks.

## Features

- **Single Container**: Entire Ceph cluster runs in one container
- **Supervisor Managed**: Process supervision with automatic restarts
- **Full Stack**: MON, MGR, OSD, Dashboard, and RGW (S3/Swift)
- **Development-Ready**: Fast startup with pre-installed Ceph binaries, optimised for dev work
- **Flexible OSDs**: Configurable OSD count with intelligent replication scaling (defaults to 1)
- **Production-like**: Uses real Ceph daemons and standard configuration
- **Modular Scripts**: All setup logic extracted to maintainable, debuggable scripts

## Quick Start

### TL;DR

```bash
# Build
cd ceph-aio
podman build -t ceph-aio:latest -f Containerfile .

# Run
podman run -d --name ceph-dev \
  -p 3300:3300 -p 6789:6789 -p 8000:8000 -p 8443:8443 \
  ceph-aio:latest

# Check status (wait approximately 60 seconds after start)
podman exec ceph-dev ceph -s

# With multiple OSDs for replication testing
podman run -d --name ceph-dev -e OSD_COUNT=3 \
  -p 3300:3300 -p 6789:6789 -p 8000:8000 -p 8443:8443 \
  ceph-aio:latest

# Access dashboard at https://localhost:8443
# Username: admin, Password: admin@ceph123
```

### Build the Image

```bash
cd ceph-aio
podman build -t ceph-aio:latest -f Containerfile .
```

Or with Docker:

```bash
docker build -t ceph-aio:latest -f Containerfile .
```

### Run the Container

Basic usage:

```bash
podman run -d \
  --name ceph-dev \
  -p 3300:3300 \
  -p 6789:6789 \
  -p 8000:8000 \
  -p 8443:8443 \
  ceph-aio:latest
```

With custom OSD size:

```bash
podman run -d \
  --name ceph-dev \
  -e OSD_SIZE=50G \
  -p 3300:3300 \
  -p 6789:6789 \
  -p 8000:8000 \
  -p 8443:8443 \
  ceph-aio:latest
```

With multiple OSDs (enables replication):

```bash
podman run -d \
  --name ceph-dev \
  -e OSD_COUNT=3 \
  -p 3300:3300 \
  -p 6789:6789 \
  -p 8000:8000 \
  -p 8443:8443 \
  ceph-aio:latest
```

With custom dashboard credentials:

```bash
podman run -d \
  --name ceph-dev \
  -e DASHBOARD_USER=myadmin \
  -e DASHBOARD_PASS=MySecurePassword123! \
  -p 3300:3300 \
  -p 6789:6789 \
  -p 8000:8000 \
  -p 8443:8443 \
  ceph-aio:latest
```

**Note**: The default configuration uses a single 10GB OSD, which is optimal for development and uses minimal resources. Multiple OSDs can be configured to test replication behaviour.

### Check Startup Progress

```bash
podman logs -f ceph-dev
```

Wait for "Bootstrap complete!" message, then check cluster status:

```bash
podman exec ceph-dev ceph -s
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MON_IP` | 0.0.0.0 | IP address for the monitor to bind to (0.0.0.0 = all interfaces) |
| `OSD_COUNT` | 1 | Number of OSD daemons to create (1-N supported, intelligently scales replication) |
| `OSD_SIZE` | 10G | Size of each OSD (supports K, M, G, T suffixes) |
| `CEPH_PUBLIC_NETWORK` | 0.0.0.0/0 | Public network CIDR for client-facing traffic |
| `CEPH_CLUSTER_NETWORK` | 0.0.0.0/0 | Cluster network CIDR for internal OSD traffic |
| `CEPH_FSID` | auto-generated | Cluster FSID (UUID) |
| `DASHBOARD_USER` | admin | Dashboard login username |
| `DASHBOARD_PASS` | admin@ceph123 | Dashboard login password |
| `DISABLE_MON_DISK_WARNINGS` | false | Set to `true` to disable monitor disk space warnings (useful for CI/testing) |

### Intelligent Replication Scaling

The container automatically configures replication based on `OSD_COUNT`:

| OSD Count | Pool Size | Min Size | Behaviour |
|-----------|-----------|----------|-----------|
| 1 | 1 | 1 | No replication, redundancy warnings silenced |
| 2 | 2 | 1 | 2x replication, can survive 1 OSD down |
| 3+ | 3 | 2 | 3x replication (Ceph best practice), requires 2 OSDs minimum |

This scaling happens automatically - no manual configuration required.

## Services

This container runs the following services via supervisord:

- **ceph-mon**: Monitor daemon (cluster coordination)
- **ceph-mgr**: Manager daemon (metrics, orchestration)
- **ceph-osd-0**: OSD daemon (10GB data storage by default)
- **ceph-rgw**: RADOS Gateway (S3/Swift API)
- **auth-setup**: One-shot configuration of cephx authentication (ensures proper client authentication)
- **dashboard-setup**: One-shot setup for Ceph dashboard
- **rbd-pool-setup**: One-shot creation of RBD block pool for testing
- **rgw-setup**: One-shot creation of RGW realm/zonegroup/zone configuration

## Accessing Services

### Ceph Dashboard

- **URL**: https://localhost:8443
- **Default Username**: `admin` (configurable via `DASHBOARD_USER`)
- **Default Password**: `admin@ceph123` (configurable via `DASHBOARD_PASS`)
- **Note**: Self-signed certificate - you will need to accept the security warning in your browser

### RBD (RADOS Block Device)

The cluster includes a pre-configured `rbd` pool for block device testing:

```bash
# Create a 1GB block device image
podman exec ceph-dev rbd create testimage --size 1024 --pool rbd

# List images
podman exec ceph-dev rbd ls rbd

# Get image info
podman exec ceph-dev rbd info rbd/testimage

# Remove image
podman exec ceph-dev rbd rm rbd/testimage
```

### RADOS Gateway (S3/Swift)

- **Endpoint**: http://localhost:8000
- **Realm**: default
- **Zone**: default
- **Zonegroup**: default

**Create a user**:
```bash
podman exec ceph-dev radosgw-admin user create \
  --uid=testuser \
  --display-name="Test User" \
  --access-key=test \
  --secret-key=test
```

### S3 API Example

Using AWS CLI:
```bash
aws --endpoint-url http://localhost:8000 \
    s3 mb s3://testbucket

aws --endpoint-url http://localhost:8000 \
    s3 cp /etc/hosts s3://testbucket/test.txt

aws --endpoint-url http://localhost:8000 \
    s3 ls s3://testbucket/
```

Or using environment variables:
```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_ENDPOINT_URL=http://localhost:8000

aws s3 mb s3://mybucket
aws s3 ls
```

### Ceph CLI

From inside the container:
```bash
podman exec -it ceph-dev bash
ceph -s                    # Cluster status
ceph osd tree              # OSD topology
ceph health detail         # Detailed health info
rados df                   # Pool usage
```

From the host (if you mount the config):
```bash
podman run -d \
  --name ceph-dev \
  -v ./ceph-conf:/etc/ceph:z \
  -p 3300:3300 \
  -p 6789:6789 \
  -p 8000:8000 \
  -p 8443:8443 \
  ceph-aio:latest

# Then from host:
ceph -c ./ceph-conf/ceph.conf -s
```

## Process Management with Supervisord

All daemons are managed by supervisord, which provides:

- **Automatic restart** if a daemon crashes
- **Proper startup ordering** via priority settings
- **Individual log files** for each daemon
- **Process monitoring** and status reporting

### Check Process Status

```bash
podman exec ceph-dev supervisorctl status
```

Output will show something like:
```
ceph-mgr                         RUNNING   pid 62, uptime 0:01:26
ceph-mon                         RUNNING   pid 60, uptime 0:01:26
ceph-osd-0                       RUNNING   pid 63, uptime 0:01:26
ceph-rgw                         RUNNING   pid 2618, uptime 0:00:34
dashboard-setup                  EXITED    Oct 15 10:48 AM
mgr-bootstrap                    EXITED    Oct 15 10:48 AM
rbd-pool-setup                   EXITED    Oct 15 10:49 AM
rgw-setup                        EXITED    Oct 15 10:50 AM
```

### Restart a Specific Daemon

```bash
podman exec ceph-dev supervisorctl restart ceph-mgr
```

### View Daemon Logs

```bash
# Via supervisor logs
podman exec ceph-dev tail -f /var/log/supervisor/ceph-mon.log
podman exec ceph-dev tail -f /var/log/supervisor/ceph-osd-0.log

# Or via podman logs (shows all output)
podman logs -f ceph-dev
```

## Persistent Data

To persist cluster data between container restarts:

```bash
podman run -d \
  --name ceph-dev \
  -v ceph-data:/var/lib/ceph:z \
  -v ceph-config:/etc/ceph:z \
  -p 3300:3300 \
  -p 6789:6789 \
  -p 8000:8000 \
  -p 8443:8443 \
  ceph-aio:latest
```

The bootstrap script is idempotent - it will skip setup if the cluster is already initialised.

## Common Operations

### Create a Pool

```bash
podman exec ceph-dev ceph osd pool create mypool 32
```

### Store an Object via RADOS

```bash
podman exec ceph-dev rados -p mypool put testobj /etc/hosts
podman exec ceph-dev rados -p mypool ls
podman exec ceph-dev rados -p mypool get testobj /tmp/retrieved
```

### Store an Object via S3

```bash
# Create RGW user first
podman exec ceph-dev radosgw-admin user create \
  --uid=testuser --display-name="Test" \
  --access-key=test --secret-key=test

# Use aws CLI
aws --endpoint-url http://localhost:8000 \
  s3 cp /etc/hosts s3://testbucket/myfile
```

### Check OSD Status

```bash
podman exec ceph-dev ceph osd stat
podman exec ceph-dev ceph osd tree
podman exec ceph-dev ceph osd df
```

### View Health Details

```bash
podman exec ceph-dev ceph health detail
```

### Test Replication (Multiple OSDs)

With multiple OSDs, you can verify replication is working:

```bash
# Start cluster with 3 OSDs
podman run -d --name ceph-dev -e OSD_COUNT=3 -p 3300:3300 -p 6789:6789 -p 8000:8000 -p 8443:8443 ceph-aio:latest

# Wait for startup (approximately 90 seconds with 3 OSDs)
sleep 90

# Verify all OSDs are up
podman exec ceph-dev ceph osd tree

# Check pool replication settings
podman exec ceph-dev ceph osd pool get rbd size
podman exec ceph-dev ceph osd pool get rbd min_size

# Write test object
echo "test data" | podman exec -i ceph-dev rados put testobj - -p rbd

# Verify object is replicated across OSDs
podman exec ceph-dev ceph osd map rbd testobj

# Check object copies
podman exec ceph-dev rados -p rbd ls
```

## Architecture

This container uses a **supervisor-based architecture** with **modular setup scripts**:

```
entrypoint.sh
    ↓
bootstrap.sh (one-time setup)
    ↓ creates FSID, keyrings, monmap
    ↓ prepares OSD directories
    ↓ generates supervisor config for OSDs
    ↓
supervisord (process manager)
    ↓
    ├── run-mon.sh (priority 10) - Monitor daemon wrapper
    ├── setup-mgr.sh (priority 15, one-shot) - Configures MGR
    ├── run-mgr.sh (priority 20) - Manager daemon wrapper
    ├── setup-osd.sh (priority 30+N, per-OSD) - Initialises OSDs
    ├── setup-auth.sh (priority 95, one-shot) - Configures cephx authentication
    ├── setup-dashboard.sh (priority 100, one-shot) - Configures dashboard
    ├── setup-rbd.sh (priority 105, one-shot) - Creates RBD pool
    ├── setup-rgw.sh (priority 110, one-shot) - Configures RGW realm/zone
    └── run-rgw.sh (priority 120) - RGW daemon wrapper
```

### Setup Scripts

All setup logic has been extracted to maintainable scripts in `/scripts/`:

- **run-mon.sh**: Starts monitor daemon with logging
- **run-mgr.sh**: Waits for keyring, then starts manager daemon
- **run-rgw.sh**: Waits for keyring, then starts RGW daemon
- **setup-mgr.sh**: Creates manager keyring, sets PG limits, disables autoscaler, configures security
- **setup-auth.sh**: Configures cephx authentication for secure client connections
- **setup-dashboard.sh**: Enables dashboard, creates user, configures SSL
- **setup-rbd.sh**: Creates and initialises RBD pool for block storage
- **setup-rgw.sh**: Creates RGW realm/zonegroup/zone, restarts daemon
- **setup-osd.sh**: Serialises OSD creation, initialises with BlueStore, starts daemon
- **lib/common.sh**: Shared utilities (logging, waiting, idempotency)

All scripts are **idempotent** with marker files in `/var/run/ceph/`.

### Key Design Decisions

1. **Supervisord**: Manages all daemons with automatic restarts
2. **Modular Scripts**: All logic extracted to separate, testable scripts
3. **Bootstrap Script**: One-time initialisation, idempotent
4. **Priority-based Startup**: Ensures MON, MGR, OSDs, RGW ordering
5. **One-shot Programs**: Dashboard and RGW setup run once then exit
6. **Dynamic OSD Config**: Supervisor config generated based on OSD_COUNT
7. **Zero Inline Bash**: All commands in supervisord.conf are simple script calls
8. **Serialised OSD Creation**: OSDs initialise sequentially to prevent race conditions
9. **Intelligent Replication**: Pool size scales automatically with OSD count

## Advantages of This Approach

Compared to manual script-based daemon management:

- **Robust**: Automatic restart on daemon failure
- **Observable**: Easy to check status and logs per daemon
- **Maintainable**: Clear separation of bootstrap vs runtime, modular scripts
- **Debuggable**: Each script can be tested independently with clear error messages
- **Production-like**: Uses real daemon commands
- **Simple**: Short entrypoint, clean supervisor config, all complexity in scripts
- **Idempotent**: Can restart container without re-bootstrapping
- **Consistent**: Uniform logging and error handling across all components

## Differences from Production

**Warning**: This is for development only! Key differences from production:

- Single node (no fault tolerance at node level)
- File-backed OSDs (not real block devices)
- Self-signed certificates
- All services on one host
- No high availability
- Simplified authentication
- All daemons share the same hostname
- Default single OSD configuration (replication can be enabled via `OSD_COUNT`)

**Default single OSD**: For development and testing application code, a single OSD provides all necessary functionality (object storage, S3 API, RGW) with faster startup and lower resource usage. Multiple OSDs can be configured to test replication and failure scenarios.

## Troubleshooting

### Container Will Not Start

Check the logs:
```bash
podman logs ceph-dev
```

Look for bootstrap errors or supervisor startup issues.

### Daemon Keeps Restarting

Check supervisor status:
```bash
podman exec ceph-dev supervisorctl status
```

Check specific daemon logs:
```bash
podman exec ceph-dev tail -100 /var/log/supervisor/ceph-osd-0-error.log
```

### Dashboard Not Accessible

1. Check if dashboard setup completed:
   ```bash
   podman exec ceph-dev supervisorctl status dashboard-setup
   ```

2. Check if dashboard is enabled:
   ```bash
   podman exec ceph-dev ceph mgr module ls | grep dashboard
   ```

3. Check dashboard URL:
   ```bash
   podman exec ceph-dev ceph mgr services
   ```

### RGW Not Working

1. Check RGW daemon status:
   ```bash
   podman exec ceph-dev supervisorctl status ceph-rgw
   ```

2. Check RGW logs:
   ```bash
   podman exec ceph-dev tail -100 /var/log/supervisor/ceph-rgw.log
   ```

3. Test connectivity (should return 404 with NoSuchBucket error in XML):
   ```bash
   curl http://localhost:8000
   ```

4. Check if realm was created:
   ```bash
   podman exec ceph-dev radosgw-admin realm list
   ```

**Note**: RGW in single-OSD setups may require PG autoscaling to be disabled, otherwise realm creation can fail with "Numerical result out of range". This is automatically configured in the bootstrap.

### Health Warnings

The cluster is configured to maintain `HEALTH_OK` status in development:

**Automatically resolved:**
- `AUTH_INSECURE_GLOBAL_ID_RECLAIM_ALLOWED`: Disabled by default (security best practice, CVE-2021-20288)
- `POOL_NO_REDUNDANCY`: Warnings silenced for single-OSD setups (expected behaviour)

**Other potential warnings:**
- `TOO_FEW_PGS`: Fine for testing with small pools
- `MGR_MODULE_ERROR`: Check which module and its logs

With multiple OSDs (`OSD_COUNT > 1`), pool redundancy warnings are enabled and replication is configured automatically.

### Reset Everything

Stop and remove the container:
```bash
podman stop ceph-dev
podman rm ceph-dev
```

If using volumes:
```bash
podman volume rm ceph-data ceph-config
```

Start fresh:
```bash
podman run -d --name ceph-dev -p 3300:3300 -p 6789:6789 -p 8000:8000 -p 8443:8443 ceph-aio:latest
```

## Development Workflow

### Typical Development Session

1. **Start the cluster**:
   ```bash
   podman run -d --name ceph-dev -p 3300:3300 -p 6789:6789 -p 8000:8000 -p 8443:8443 ceph-aio:latest
   ```

2. **Watch startup** (takes approximately 60 seconds for single OSD, 90 seconds for 3 OSDs):
   ```bash
   podman logs -f ceph-dev
   # Wait for "Bootstrap complete!"
   ```

3. **Check cluster health**:
   ```bash
   podman exec ceph-dev ceph -s
   ```

4. **Access dashboard**: Open https://localhost:8443 (admin/admin@ceph123)

5. **Test S3 API**: Create user and test with aws CLI

6. **Stop when done**:
   ```bash
   podman stop ceph-dev
   podman rm ceph-dev
   ```

### Testing Replication Scenarios

For testing replication, recovery, or failure scenarios:

1. **Start with multiple OSDs**:
   ```bash
   podman run -d --name ceph-dev -e OSD_COUNT=3 -p 3300:3300 -p 6789:6789 -p 8000:8000 -p 8443:8443 ceph-aio:latest
   ```

2. **Verify replication**:
   ```bash
   podman exec ceph-dev ceph osd pool get rbd size  # Should show: size: 3
   ```

3. **Test with replicated data** and observe behaviour with multiple copies

## Nomad Deployment

For production-like deployments using HashiCorp Nomad, see the [nomad/README.md](nomad/README.md) for detailed deployment instructions and Ceph-CSI integration.

## Extending the Setup

### Adding MDS (CephFS)

You would need to:
- Create `/scripts/setup-mds.sh` for MDS keyring and configuration
- Create `/scripts/run-mds.sh` for MDS daemon wrapper
- Add `[program:ceph-mds]` section to supervisord.conf

### Custom Configuration

Mount your own ceph.conf:
```bash
podman run -d \
  --name ceph-dev \
  -v ./my-ceph.conf:/etc/ceph/ceph.conf:z \
  ceph-aio:latest
```

Note: The bootstrap script will skip if config already exists.

## Version Information

- Base image: `quay.io/ceph/ceph` (version specified via `CEPH_VERSION` ARG in Containerfile)
- Supervisor: Installed from RHEL repos

To use a different Ceph version, update the `CEPH_VERSION` ARG in the Containerfile.

### Pre-built Images

Pre-built images are available for the 3 most recent Ceph major releases with two tagging strategies:

```bash
# Rolling tags (always latest build for this major version)
podman pull quay.io/benjamin_holmes/ceph-aio:v19  # Latest v19.x build
podman pull quay.io/benjamin_holmes/ceph-aio:v18  # Latest v18.x build
podman pull quay.io/benjamin_holmes/ceph-aio:v17  # Latest v17.x build

# Immutable dated tags (specific build, never changes)
podman pull quay.io/benjamin_holmes/ceph-aio:v19-20251003  # Build from Oct 3, 2025
podman pull quay.io/benjamin_holmes/ceph-aio:v18-20250915  # Build from Sep 15, 2025
```

**Tagging Strategy:**
- **Rolling tags** (`v19`, `v18`, etc.): Best for development - automatically updated with each new build
- **Dated tags** (`v19-20251003`): Best for production - immutable reference to specific build date
- Build dates use format `YYYYMMDD` matching Ceph's convention

Images are automatically built and tested weekly via GitHub Actions. See [CI-CD-SETUP.md](CI-CD-SETUP.md) for details on the automated build pipeline.

## CI/CD Pipeline

This project includes a fully automated GitHub Actions pipeline that:
- **Dynamically discovers** the 2 most recent stable Ceph releases using `skopeo`
- **Automatically adapts** when new major versions are released (e.g., v20.x)
- **Runs comprehensive tests** validating all functionality for each version
- **Publishes successful builds** to Quay.io with semantic versioning tags

The pipeline runs weekly and on every code change, ensuring images are always current with the latest stable Ceph releases. **Zero maintenance required** - the workflow automatically detects and builds new versions!

**For setup instructions**, see [CI-CD-SETUP.md](CI-CD-SETUP.md).

## References

- [Ceph Documentation](https://docs.ceph.com/)
- [Ceph Manual Deployment](https://docs.ceph.com/en/latest/install/manual-deployment/)
- [RADOS Gateway Documentation](https://docs.ceph.com/en/latest/radosgw/)
- [Ceph Dashboard Documentation](https://docs.ceph.com/en/latest/mgr/dashboard/)
- [Supervisor Documentation](http://supervisord.org/)
