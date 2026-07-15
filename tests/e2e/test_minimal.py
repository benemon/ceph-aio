"""Minimal cluster: every optional subsystem disabled.

Boots with all four ENABLE_ flags false and asserts the container still
reaches healthy without creating any subsystem resources. Together with
the default-flags suite this covers the interesting points of the flag
space; the other fourteen combinations are supported by construction
(each subsystem's wiring is generated independently from its own flag).

Fast tier deliberately: this is the sole guard that the healthcheck's
marker list actually respects the flags — a regression there makes
disabled clusters unhealthy forever.
"""

import pytest

from conftest import CephCluster, _dump_logs_on_failure, make_cluster

MINIMAL_FLAGS = {
    "ENABLE_RGW": "false",
    "ENABLE_DASHBOARD": "false",
    "ENABLE_RBD": "false",
    "ENABLE_CEPHFS": "false",
}


@pytest.fixture
def minimal_cluster(request):
    with make_cluster(1, **MINIMAL_FLAGS) as container:
        cluster = CephCluster(container)
        cluster.wait_healthy()
        yield cluster
        _dump_logs_on_failure(request, cluster)


def test_minimal_cluster_has_no_optional_subsystems(minimal_cluster):
    cluster = minimal_cluster

    # No subsystem pools: rbd, RGW's realm/zone pools, CephFS pools
    pools = cluster.exec("ceph", "osd", "pool", "ls").split()
    assert "rbd" not in pools
    assert not any(p.startswith((".rgw", "default.rgw")) for p in pools)
    assert not any(p.startswith("cephfs_") for p in pools)

    # No filesystem, no dashboard module
    assert "No filesystems enabled" in cluster.exec("ceph", "fs", "ls")
    modules = cluster.ceph_json("ceph", "mgr", "module", "ls")
    assert "dashboard" not in modules["enabled_modules"]

    # Supervisor never wired the subsystem programs (supervisorctl exits
    # non-zero when one-shots sit in EXITED, so don't assert on rc)
    programs = cluster.exec("bash", "-c", "supervisorctl status || true")
    for program in ("ceph-rgw", "rgw-setup", "ceph-mds", "mds-setup",
                    "dashboard-setup", "rbd-pool-setup"):
        assert program not in programs
