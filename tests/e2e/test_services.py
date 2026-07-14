"""Client-perspective service tests against a shared single-OSD cluster.

These exercise the container from the outside — the S3 API over the
mapped RGW port and the dashboard over HTTPS — which test-suite.sh never
covered (it only asserted internal daemon state via docker exec).
"""

import time

import boto3
import pytest
import requests
import urllib3
from botocore.config import Config

from conftest import CephCluster, make_cluster

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

SERVICE_WAIT = 120


def _wait_for_http(url: str, timeout: int = SERVICE_WAIT, **kwargs) -> requests.Response:
    """Poll a URL until it answers with any HTTP response."""
    deadline = time.time() + timeout
    last_error = None
    while time.time() < deadline:
        try:
            return requests.get(url, timeout=10, **kwargs)
        except requests.exceptions.ConnectionError as exc:
            last_error = exc
            time.sleep(3)
    raise TimeoutError(f"no HTTP response from {url} within {timeout}s: {last_error}")


def test_rados_object_roundtrip(cluster):
    cluster.exec("bash", "-c", "echo e2e-payload | rados put e2e-obj - -p rbd")
    assert "e2e-obj" in cluster.exec("rados", "-p", "rbd", "ls")
    assert cluster.exec("rados", "-p", "rbd", "get", "e2e-obj", "-").strip() == "e2e-payload"


def test_rbd_image_lifecycle(cluster):
    cluster.exec("rbd", "create", "e2e-image", "--size", "64M", "--pool", "rbd")
    assert "e2e-image" in cluster.exec("rbd", "ls", "rbd")


def test_s3_object_roundtrip(cluster):
    # The RGW daemon binds its port shortly after the readiness marker;
    # wait for the endpoint to answer before driving the API
    _wait_for_http(cluster.rgw_endpoint())

    cluster.exec(
        "radosgw-admin", "user", "create",
        "--uid=e2e", "--display-name=E2E Test User",
        "--access-key=e2e-access", "--secret-key=e2e-secret",
    )

    s3 = boto3.client(
        "s3",
        endpoint_url=cluster.rgw_endpoint(),
        aws_access_key_id="e2e-access",
        aws_secret_access_key="e2e-secret",
        region_name="default",
        config=Config(s3={"addressing_style": "path"}, retries={"max_attempts": 3}),
    )

    s3.create_bucket(Bucket="e2e-bucket")
    s3.put_object(Bucket="e2e-bucket", Key="hello.txt", Body=b"hello from testcontainers")

    body = s3.get_object(Bucket="e2e-bucket", Key="hello.txt")["Body"].read()
    assert body == b"hello from testcontainers"

    keys = [o["Key"] for o in s3.list_objects_v2(Bucket="e2e-bucket").get("Contents", [])]
    assert keys == ["hello.txt"]


def test_dashboard_serves_https(cluster):
    resp = _wait_for_http(cluster.dashboard_endpoint(), verify=False)
    assert resp.status_code == 200
    assert "html" in resp.headers.get("content-type", "").lower()


def test_custom_dashboard_credentials():
    # Separate container: credentials are baked in at first boot
    with (
        make_cluster(1)
        .with_env("DASHBOARD_USER", "e2eadmin")
        .with_env("DASHBOARD_PASS", "E2ePass123!")
    ) as container:
        cluster = CephCluster(container)
        cluster.wait_healthy()
        cluster.exec("ceph", "dashboard", "ac-user-show", "e2eadmin")
        with pytest.raises(AssertionError):
            cluster.exec("ceph", "dashboard", "ac-user-show", "admin")
