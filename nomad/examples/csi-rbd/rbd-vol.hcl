# Dynamic RBD volume: `nomad volume create rbd-vol.hcl`
id           = "test-rbd-vol"
name         = "test-rbd-vol"
type         = "csi"
plugin_id    = "rbd.csi.ceph.com"
capacity_min = "1GiB"
capacity_max = "1GiB"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}

# Pin ext4: the plugin's default format is ext2, which fails the
# node-stage resize check ("Could not parse fs info ... ext2")
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
