"""Dashboard enabled with RGW disabled: the one real cross-subsystem edge.

setup-dashboard.sh branches on ENABLE_RGW to decide whether to enable
the mgr rgw module — the only place one subsystem's setup references
another subsystem's flag. Flag-combination tests are added only when
such a coupling exists in the scripts; the rest of the flag space is
covered by the defaults and minimal boots plus independent-by-
construction wiring.

Extended tier: the coupling changes rarely, so the weekly run guards it.
"""

import pytest

from conftest import CephCluster, _dump_logs_on_failure, make_cluster
from test_services import _wait_for_http

pytestmark = pytest.mark.extended


@pytest.fixture
def no_rgw_cluster(request):
    with make_cluster(1, ENABLE_RGW="false") as container:
        cluster = CephCluster(container)
        cluster.wait_healthy()
        yield cluster
        _dump_logs_on_failure(request, cluster)


def test_dashboard_serves_without_rgw(no_rgw_cluster):
    cluster = no_rgw_cluster

    # Dashboard reached full setup and answers over HTTPS
    modules = cluster.ceph_json("ceph", "mgr", "module", "ls")
    assert "dashboard" in modules["enabled_modules"]
    resp = _wait_for_http(cluster.dashboard_endpoint(), verify=False)
    assert resp.status_code == 200

    # And nothing RGW-shaped exists: no mgr module, no pools, no daemon
    assert "rgw" not in modules["enabled_modules"]
    pools = cluster.exec("ceph", "osd", "pool", "ls").split()
    assert not any(p.startswith((".rgw", "default.rgw")) for p in pools)
    assert "ceph-rgw" not in cluster.exec("bash", "-c", "supervisorctl status || true")
