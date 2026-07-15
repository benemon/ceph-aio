# Docker-driver variant of ceph-aio.nomad.hcl — identical apart from the
# task driver. Host networking is required either way so the monitor
# advertises an address external clients can reach.
job "ceph-aio" {
  datacenters = ["dc1"]
  type        = "service"

  group "ceph" {
    count = 1
    task "ceph-aio" {
      driver = "docker"

      config {
        image        = "quay.io/benjamin_holmes/ceph-aio:v19"
        network_mode = "host"
      }

      env {
        MON_IP               = "0.0.0.0" # Will use host's IP
        OSD_COUNT            = "1"
        OSD_SIZE             = "10G"
        CEPH_PUBLIC_NETWORK  = "0.0.0.0/0"
        CEPH_CLUSTER_NETWORK = "0.0.0.0/0"
        DASHBOARD_USER       = "admin"
        DASHBOARD_PASS       = "admin@ceph123"
      }

      resources {
        cpu    = 4000
        memory = 8192
      }
    }
  }
}
