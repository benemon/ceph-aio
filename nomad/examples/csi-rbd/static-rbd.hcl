# Static / pre-provisioned volume: `nomad volume register static-rbd.hcl`
# Create the image out-of-band first:
#   rbd create rbd/static-img --size 1024 --image-feature layering
# external_id is the RBD image name; static volumes use `context`
# (not `parameters`) and need staticVolume=true.
id          = "static-rbd"
external_id = "static-img"
type        = "csi"
plugin_id   = "rbd.csi.ceph.com"

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

context {
  clusterID     = "<CEPH_FSID>"
  pool          = "rbd"
  staticVolume  = "true"
  imageFeatures = "layering"
}
