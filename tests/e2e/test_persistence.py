"""Data persistence across container recreation.

Distinct from the restart tests: the container is *removed* and a brand
new one is created over the same named volumes, as `docker compose up`
does after any config change. The image must rebuild its runtime wiring
(OSD supervisor programs, mon identity, advertised address) around the
existing cluster data.
"""

import uuid

import docker
import pytest

from conftest import CephCluster, make_cluster

pytestmark = pytest.mark.extended


def _volume_cluster(data_vol: str, conf_vol: str):
    return (
        make_cluster(1)
        .with_volume_mapping(data_vol, "/var/lib/ceph", "rw")
        .with_volume_mapping(conf_vol, "/etc/ceph", "rw")
    )


def test_data_survives_container_recreation():
    suffix = uuid.uuid4().hex[:8]
    data_vol = f"ceph-e2e-data-{suffix}"
    conf_vol = f"ceph-e2e-conf-{suffix}"
    client = docker.from_env()

    try:
        with _volume_cluster(data_vol, conf_vol) as first:
            cluster = CephCluster(first)
            cluster.wait_healthy()
            fsid = cluster.exec("ceph", "fsid").strip()
            cluster.exec(
                "bash", "-c",
                "echo persistent-payload | rados put persist-obj - -p rbd",
            )
        # First container is gone; only the volumes remain. The new
        # container gets a fresh hostname and (usually) a fresh IP.
        with _volume_cluster(data_vol, conf_vol) as second:
            cluster = CephCluster(second)
            cluster.wait_healthy()

            assert cluster.exec("ceph", "fsid").strip() == fsid
            payload = cluster.exec("rados", "-p", "rbd", "get", "persist-obj", "-")
            assert payload.strip() == "persistent-payload"
            assert cluster.exec("ceph", "health").strip() == "HEALTH_OK"
    finally:
        for name in (data_vol, conf_vol):
            try:
                client.volumes.get(name).remove(force=True)
            except docker.errors.NotFound:
                pass
