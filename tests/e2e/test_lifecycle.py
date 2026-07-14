"""Container lifecycle: bootstrap must be idempotent across restarts."""

import pytest

from conftest import CephCluster, make_cluster, _dump_logs_on_failure


@pytest.fixture
def restartable_cluster(request):
    with make_cluster(1) as container:
        cluster = CephCluster(container)
        cluster.wait_healthy()
        yield cluster
        _dump_logs_on_failure(request, cluster)


def test_cluster_survives_restart_with_same_fsid(restartable_cluster):
    cluster = restartable_cluster

    fsid_before = cluster.exec("ceph", "fsid").strip()

    cluster.restart()
    cluster.wait_healthy()

    assert cluster.exec("ceph", "fsid").strip() == fsid_before
    assert cluster.exec("ceph", "health").strip() == "HEALTH_OK"