# ceph-csi CephFS plugin (controller + node in one task).
# See README.md in this directory for setup steps and gotchas.
job "ceph-csi-cephfs" {
  datacenters = ["dc1"]
  type        = "system"

  group "csi" {
    task "plugin" {
      driver = "podman"

      config {
        image        = "quay.io/cephcsi/cephcsi:v3.12.0"
        network_mode = "host"
        privileged   = true
        args = [
          "--type=cephfs",
          "--endpoint=unix://csi/csi.sock",
          "--nodeid=${node.unique.name}",
          "--nodeserver=true",
          "--controllerserver=true",
          "--drivername=cephfs.csi.ceph.com",
          "--instanceid=nomad-cephfs",
          "--pidlimit=-1",
          "--v=5",
        ]
        volumes = [
          "/opt/ceph-csi/config.json:/etc/ceph-csi-config/config.json:ro",
          "/lib/modules:/lib/modules:ro",
        ]
        # ceph-csi writes temporary keyfiles here; without the tmpfs,
        # CreateVolume fails with "error creating a temporary keyfile"
        tmpfs = ["/tmp/csi/keys"]
      }

      csi_plugin {
        id        = "cephfs.csi.ceph.com"
        type      = "monolith"
        mount_dir = "/csi"
      }

      resources {
        cpu    = 150
        memory = 512
      }
    }
  }
}
