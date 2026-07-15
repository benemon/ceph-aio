# Consumer of the dynamic RBD volume created from rbd-vol.hcl
job "rbd-demo" {
  datacenters = ["dc1"]
  type        = "service"

  group "demo" {
    volume "data" {
      type            = "csi"
      source          = "test-rbd-vol"
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
    }

    task "app" {
      driver = "podman"

      config {
        image   = "registry.access.redhat.com/ubi9/ubi-minimal:latest"
        command = "sleep"
        args    = ["3600"]
        # Demo shortcut; confined alternative: a volume mount flag of
        # context="system_u:object_r:container_file_t:s0"
        security_opt = ["label=disable"]
      }

      volume_mount {
        volume      = "data"
        destination = "/data"
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }
  }
}
