# Docker-driver variant of ceph-aio.nomad.hcl — identical apart from the
# task driver. Host networking is required either way so the monitor
# advertises an address external clients can reach.
job "ceph-aio" {
  datacenters = ["dc1"]
  type        = "service"

  group "ceph" {
    count = 1

    # Host-mode port reservation: gives the service check a port label
    # and stops Nomad placing anything else on the monitor's port. The
    # task itself still uses driver-level host networking.
    network {
      port "mon_v1" {
        static = 6789
      }
    }

    # Nomad-native service checks are tcp/http only, so this signals
    # "monitor reachable", not "every subsystem configured". For the
    # image's full readiness contract see README: Readiness.
    service {
      name     = "ceph-aio"
      provider = "nomad"
      port     = "mon_v1"

      check {
        type     = "tcp"
        interval = "15s"
        timeout  = "5s"
      }
    }

    task "ceph-aio" {
      driver = "docker"

      config {
        image        = "quay.io/benjamin_holmes/ceph-aio:v20"
        network_mode = "host"
      }

      env {
        MON_IP               = "0.0.0.0" # Auto-detects the host's routable IP
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
