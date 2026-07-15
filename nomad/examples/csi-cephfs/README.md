# ceph-csi CephFS on Nomad

Shared (RWX) file storage from a ceph-aio cluster via the
[ceph-csi](https://github.com/ceph/ceph-csi) CephFS driver.

Tested with ceph-aio `:v20`, ceph-csi `v3.12.0`, Nomad 2.0.4, podman
driver. The setup mirrors the [RBD example](../csi-rbd/README.md) —
same `config.json`, same plugin image — so only the differences are
called out here.

## Prerequisites

- A running ceph-aio allocation with host networking. CephFS is on by
  default (`ENABLE_CEPHFS`), and the image pre-creates the `csi`
  subvolume group ceph-csi requires. On older images that don't,
  provisioning fails with `subvolume group 'csi' does not exist` — fix
  with:

  ```bash
  nomad alloc exec <ceph-aio-alloc> ceph fs subvolumegroup create cephfs csi
  ```

- The `ceph` kernel module on every client node for kernel-mode mounts:
  `modprobe ceph`
- `/opt/ceph-csi/config.json` on every client node (same file as the
  RBD example; the `cephFS.subvolumeGroup` key is what this driver
  reads)

## Setup

```bash
nomad job run ceph-csi-cephfs.nomad.hcl
nomad plugin status cephfs.csi.ceph.com

# Fill <CEPH_FSID> and <CLIENT_ADMIN_KEY> into cephfs-vol.hcl, then:
nomad volume create cephfs-vol.hcl
nomad job run cephfs-demo.nomad.hcl
```

The volume provisions a cephfs subvolume and the consumer gets a kernel
`ceph` mount (`<HOST_IP>:6789,...:/volumes/csi/csi-vol-.../...`) at
`/data`. Unlike RBD, the volume is `multi-node-multi-writer` — scale the
demo group and every instance shares the same filesystem.

Note the CephFS driver takes `adminID`/`adminKey` secrets where the RBD
driver takes `userID`/`userKey`.
