# ceph-csi RBD on Nomad

Block storage from a ceph-aio cluster via the [ceph-csi](https://github.com/ceph/ceph-csi)
RBD driver. Covers the full CSI lifecycle: dynamic create → snapshot →
clone → static import.

Tested with ceph-aio `:v20`, ceph-csi `v3.12.0`, Nomad 2.0.4, podman
driver. For the Docker task driver, change `driver = "podman"` in the
job files — the `config` blocks are compatible.

One Nomad-vs-Kubernetes nuance up front: **Nomad has no
auto-provision-on-claim.** A volume must exist (`nomad volume create`
or `nomad volume register`) before a job can mount it — there is no
PVC/StorageClass equivalent that provisions on demand.

## Prerequisites

- A running ceph-aio allocation with host networking (see
  [../../ceph-aio.nomad.hcl](../../ceph-aio.nomad.hcl))
- The `rbd` kernel module on every client node: `modprobe rbd`
- Nomad clients with `privileged` containers allowed for the plugin task

## Setup

1. Gather the cluster identity from the ceph-aio allocation:

   ```bash
   nomad alloc exec <ceph-aio-alloc> ceph fsid
   nomad alloc exec <ceph-aio-alloc> ceph auth get-key client.admin
   ```

2. Fill `<CEPH_FSID>` and `<HOST_IP>` (the ceph-aio host's IP) into
   [config.json](config.json) and place it on every Nomad client node at
   `/opt/ceph-csi/config.json`.

3. Run the plugin and wait for it to report healthy:

   ```bash
   nomad job run ceph-csi.nomad.hcl
   nomad plugin status rbd.csi.ceph.com
   ```

4. Fill `<CEPH_FSID>` and `<CLIENT_ADMIN_KEY>` into
   [rbd-vol.hcl](rbd-vol.hcl), create the volume, and run the consumer:

   ```bash
   nomad volume create rbd-vol.hcl
   nomad job run rbd-demo.nomad.hcl
   nomad alloc exec <demo-alloc> sh -c 'echo hello > /data/hello && cat /data/hello'
   ```

   The consumer mounts a freshly provisioned RBD image at `/data`;
   writes persist across reschedules.

## Snapshots and clones

`clusterID` must be passed as a `-parameter`, or snapshot creation fails
with "clusterID must be set":

```bash
nomad volume snapshot create -parameter clusterID=<CEPH_FSID> \
  -secret userID=admin -secret userKey=<CLIENT_ADMIN_KEY> test-rbd-vol snap1
```

Note the `ID` in the output, fill it into `snapshot_id` in
[rbd-clone.hcl](rbd-clone.hcl), then:

```bash
nomad volume create rbd-clone.hcl
```

A file written to the source volume before the snapshot is present in
the clone. Caveat: ceph-csi does not advertise `ListSnapshots`, so
`nomad volume snapshot list` returns "plugin does not support listing
snapshots" — create/delete by ID still work.

## Static (pre-provisioned) volumes

Create the image out-of-band, then register it (no provisioning —
`nomad volume register` with `external_id` and `staticVolume=true`, see
[static-rbd.hcl](static-rbd.hcl)):

```bash
nomad alloc exec <ceph-aio-alloc> rbd create rbd/static-img --size 1024 --image-feature layering
nomad volume register static-rbd.hcl
```

## Gotchas

- **`tmpfs = ["/tmp/csi/keys"]` is required** in the plugin job —
  ceph-csi writes temporary keyfiles there; without it `CreateVolume`
  fails with `error creating a temporary keyfile ... no such file or directory`.
- **Do not bind-mount `/dev`** into the plugin — `privileged = true`
  already provides it; an explicit bind gives
  `duplicate mount destination "/dev"`.
- **Pin `fs_type = "ext4"`** on volumes — the default format is `ext2`,
  and the node stage fails its resize check
  (`Could not parse fs info ... ext2`).
- **SELinux**: consumers need `security_opt = ["label=disable"]` (demo)
  or a `context="...:container_file_t:s0"` mount flag (confined).
