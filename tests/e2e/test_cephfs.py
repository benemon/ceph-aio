"""CephFS: opt-in filesystem via ENABLE_CEPHFS=true.

Fast tier deliberately: push-to-main runs publish images and execute the
fast tier only, and this test is the feature's sole guard.
"""

import time

from conftest import CephCluster, make_cluster

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


def _wait_for_active_mds(cluster: CephCluster, timeout: int = 120) -> None:
    deadline = time.time() + timeout
    status = ""
    while time.time() < deadline:
        status = cluster.exec("ceph", "mds", "stat").strip()
        if "up:active" in status:
            return
        time.sleep(3)
    raise TimeoutError(f"no active MDS within {timeout}s (mds stat: {status})")


def test_cephfs_filesystem_and_client_io():
    with make_cluster(1, ENABLE_CEPHFS="true") as container:
        cluster = CephCluster(container)
        cluster.wait_healthy()

        # Filesystem exists and an MDS goes active
        assert "cephfs" in cluster.exec("ceph", "fs", "ls")
        _wait_for_active_mds(cluster)

        # Client I/O through userspace libcephfs (no kernel, no FUSE)
        out = cluster.exec("python3", "-c", LIBCEPHFS_ROUNDTRIP)
        assert "roundtrip ok" in out
