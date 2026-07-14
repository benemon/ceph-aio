"""CephFS: opt-in filesystem via ENABLE_CEPHFS=true.

Fast tier deliberately: push-to-main runs publish images and execute the
fast tier only, and this test is the feature's sole guard.
"""

import time

import pytest

from conftest import CephCluster, _dump_logs_on_failure, make_cluster

LIBCEPHFS_ROUNDTRIP = """
import cephfs
fs = cephfs.LibCephFS(conffile="/etc/ceph/ceph.conf")
fs.mount()
fd = fs.open("/e2e-file.txt", "w", 0o644)
fs.write(fd, b"cephfs payload", 0)
fs.close(fd)
fd = fs.open("/e2e-file.txt", "r", 0o644)
data = fs.read(fd, 0, 1024)
fs.close(fd)
fs.unmount()
assert data == b"cephfs payload", data
print("roundtrip ok")
"""


@pytest.fixture
def cephfs_cluster(request):
    with make_cluster(1, ENABLE_CEPHFS="true") as container:
        cluster = CephCluster(container)
        cluster.wait_healthy()
        yield cluster
        _dump_logs_on_failure(request, cluster)


def _wait_for_active_mds(cluster: CephCluster, timeout: int = 120) -> None:
    deadline = time.time() + timeout
    status = ""
    while time.time() < deadline:
        status = cluster.exec("ceph", "mds", "stat").strip()
        if "up:active" in status:
            return
        time.sleep(3)
    # Surface the daemon's own logs before failing: a crash-looping MDS
    # is invisible in cluster state
    for logfile in ("ceph-mds-error.log", "ceph-mds.log", "mds-setup-error.log"):
        print(f"===== /var/log/supervisor/{logfile} =====")
        try:
            print(cluster.exec("bash", "-c", f"cat /var/log/supervisor/{logfile} 2>&1 || true"))
        except AssertionError:
            pass
    raise TimeoutError(f"no active MDS within {timeout}s (mds stat: {status})")


def test_cephfs_filesystem_and_client_io(cephfs_cluster):
    cluster = cephfs_cluster

    # Filesystem exists and an MDS goes active
    assert "cephfs" in cluster.exec("ceph", "fs", "ls")
    _wait_for_active_mds(cluster)

    # Client I/O through userspace libcephfs (no kernel, no FUSE)
    out = cluster.exec("python3", "-c", LIBCEPHFS_ROUNDTRIP)
    assert "roundtrip ok" in out
