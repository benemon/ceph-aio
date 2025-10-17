job "ceph-aio" {
  datacenters = ["dc1"]
  type        = "service"

  group "ceph" {
    count = 1
    task "ceph-aio" {
      driver = "podman"

      config {
        image = "quay.io/benjamin_holmes/ceph-aio:v19"
        
        # Use host networking - uses host's IP directly
        network_mode = "host"
      }

      env {
        MON_IP = "0.0.0.0"  # Will use host's IP
        OSD_COUNT = "1"
        OSD_SIZE = "10G"
        CEPH_PUBLIC_NETWORK = "0.0.0.0/0"
        CEPH_CLUSTER_NETWORK = "0.0.0.0/0"
        DASHBOARD_USER = "admin"
        DASHBOARD_PASS = "admin@ceph123"
      }

      resources {
        cpu    = 4000
        memory = 8192
      }
    }
  }
}