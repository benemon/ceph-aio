"""OpenShift-style arbitrary-UID boot and storage smoke coverage."""

import os
import time

import boto3
import pytest
import requests
from botocore.config import Config

from conftest import CephCluster, _dump_logs_on_failure, make_cluster

# libcephfs enforces POSIX permissions using the caller's uid/gid, and a
# fresh CephFS root is 0755 root:root — so an arbitrary-UID client cannot
# write at the root. Real workloads consume CephFS via ceph-csi subvolumes;
# here we mount as the admin identity (uid/gid 0) to exercise the data path.
LIBCEPHFS_ROUNDTRIP = """
import cephfs
fs = cephfs.LibCephFS(conffile="/etc/ceph/ceph.conf")
fs.conf_set("client_mount_uid", "0")
fs.conf_set("client_mount_gid", "0")
fs.mount()
fd = fs.open("/arbitrary-uid.txt", "w", 0o644)
fs.write(fd, b"arbitrary uid payload", 0)
fs.close(fd)
fd = fs.open("/arbitrary-uid.txt", "r", 0o644)
data = fs.read(fd, 0, 1024)
fs.close(fd)
fs.unmount()
assert data == b"arbitrary uid payload", data
"""


@pytest.fixture
def arbitrary_uid_cluster(request):
    if not os.environ.get("CEPH_AIO_UID"):
        pytest.skip("CEPH_AIO_UID is required for the arbitrary-UID lane")

    with make_cluster(1) as container:
        cluster = CephCluster(container)
        cluster.wait_healthy()
        yield cluster
        _dump_logs_on_failure(request, cluster)


def test_arbitrary_uid_boots_with_empty_ceph_volumes(tmp_path):
    if not os.environ.get("CEPH_AIO_UID"):
        pytest.skip("CEPH_AIO_UID is required for the arbitrary-UID lane")

    data_dir = tmp_path / "ceph-data"
    conf_dir = tmp_path / "ceph-conf"
    for path in (data_dir, conf_dir):
        path.mkdir()
        # Docker bind mounts preserve host ownership; keep this test focused
        # on empty mounts shadowing image content, as a fresh PVC would.
        path.chmod(0o777)

    container = (
        make_cluster(1)
        .with_volume_mapping(str(data_dir), "/var/lib/ceph", "rw")
        .with_volume_mapping(str(conf_dir), "/etc/ceph", "rw")
    )
    with container:
        cluster = CephCluster(container)
        cluster.wait_healthy()


def test_arbitrary_uid_storage_smoke(arbitrary_uid_cluster):
    cluster = arbitrary_uid_cluster

    assert cluster.exec("id", "-u").strip() == "1000680000"
    assert cluster.exec("id", "-g").strip() == "0"
    identity = cluster.exec(
        "bash", "-c",
        ". /scripts/lib/common.sh; getent passwd 1000680000",
    )
    assert "ceph-aio" in identity

    cluster.exec("rbd", "create", "arbitrary-uid", "--size", "8M", "--pool", "rbd")
    assert "arbitrary-uid" in cluster.exec("rbd", "ls", "rbd").split()

    deadline = time.time() + 120
    while True:
        try:
            requests.get(cluster.rgw_endpoint(), timeout=10)
            break
        except requests.exceptions.ConnectionError:
            if time.time() >= deadline:
                raise TimeoutError("RGW did not answer within 120s")
            time.sleep(3)

    cluster.exec(
        "radosgw-admin", "user", "create",
        "--uid=arbitrary-uid", "--display-name=Arbitrary UID",
        "--access-key=arbitrary-access", "--secret-key=arbitrary-secret",
    )
    s3 = boto3.client(
        "s3",
        endpoint_url=cluster.rgw_endpoint(),
        aws_access_key_id="arbitrary-access",
        aws_secret_access_key="arbitrary-secret",
        region_name="default",
        config=Config(s3={"addressing_style": "path"}, retries={"max_attempts": 3}),
    )
    s3.create_bucket(Bucket="arbitrary-uid")
    s3.put_object(Bucket="arbitrary-uid", Key="smoke", Body=b"rgw payload")
    assert s3.get_object(Bucket="arbitrary-uid", Key="smoke")["Body"].read() == b"rgw payload"

    cluster.exec("python3", "-c", LIBCEPHFS_ROUNDTRIP)

    logs = cluster._wrapped.logs().decode(errors="replace")
    logs += cluster.exec(
        "bash", "-c",
        "find /ceph-run/supervisor -type f -name '*.log' -exec cat {} +",
    )
    logs = logs.lower()
    for forbidden in ("chown", "setuser", "operation not permitted"):
        assert forbidden not in logs
