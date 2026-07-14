"""Cluster convergence and replication sizing across OSD counts.

Replaces the Single/Two/Three OSD Configuration tests from test-suite.sh
with one parametrized test body.
"""


def test_replication_scales_with_osd_count(sized_cluster):
    cluster, osd_count = sized_cluster

    assert cluster.ceph_json("ceph", "osd", "stat")["num_up_osds"] == osd_count

    expected_size = min(osd_count, 3)
    pool_size = cluster.ceph_json("ceph", "osd", "pool", "get", "rbd", "size")["size"]
    assert pool_size == expected_size

    expected_min = max(1, expected_size - 1)
    min_size = cluster.ceph_json("ceph", "osd", "pool", "get", "rbd", "min_size")["min_size"]
    assert min_size == expected_min

    assert cluster.exec("ceph", "health").strip() == "HEALTH_OK"

    # Objects replicate across the expected number of OSDs
    cluster.exec("bash", "-c", "echo replicated-payload | rados put repl-obj - -p rbd")
    assert cluster.exec("rados", "-p", "rbd", "get", "repl-obj", "-").strip() == "replicated-payload"
    acting = cluster.ceph_json("ceph", "osd", "map", "rbd", "repl-obj")["acting"]
    assert len(set(acting)) == expected_size
