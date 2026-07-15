# Dynamic CephFS volume (RWX): `nomad volume create cephfs-vol.hcl`
id           = "test-cephfs-vol"
name         = "test-cephfs-vol"
type         = "csi"
plugin_id    = "cephfs.csi.ceph.com"
capacity_min = "1GiB"
capacity_max = "1GiB"

capability {
  access_mode     = "multi-node-multi-writer"
  attachment_mode = "file-system"
}

secrets {
  adminID  = "admin"
  adminKey = "<CLIENT_ADMIN_KEY>"
}

parameters {
  clusterID = "<CEPH_FSID>"
  fsName    = "cephfs"
}
