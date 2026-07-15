# Clone-from-snapshot: `nomad volume create rbd-clone.hcl`
# snapshot_id comes from `nomad volume snapshot create` output —
# see "Snapshots and clones" in README.md
id           = "rbd-clone"
name         = "rbd-clone"
type         = "csi"
plugin_id    = "rbd.csi.ceph.com"
snapshot_id  = "<SNAPSHOT_ID>"
capacity_min = "1GiB"
capacity_max = "1GiB"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}

mount_options {
  fs_type = "ext4"
}

secrets {
  userID  = "admin"
  userKey = "<CLIENT_ADMIN_KEY>"
}

parameters {
  clusterID     = "<CEPH_FSID>"
  pool          = "rbd"
  imageFeatures = "layering"
}
