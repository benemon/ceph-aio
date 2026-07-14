"""Extended tier: deep use-case scenarios.

These run on the weekly schedule and manual dispatch (pytest -m extended
is excluded on PR/push runs) — they trade wall-clock for coverage of
realistic consumer behaviour and failure modes.
"""

import hashlib
import os

import boto3
import pytest
import requests
from botocore.config import Config
from testcontainers.core.container import DockerContainer
from testcontainers.core.network import Network

from conftest import IMAGE_TAG, CephCluster, make_cluster
from test_services import _wait_for_http

pytestmark = pytest.mark.extended


@pytest.fixture(scope="module")
def s3(cluster):
    _wait_for_http(cluster.rgw_endpoint())
    cluster.exec(
        "radosgw-admin", "user", "create",
        "--uid=extended", "--display-name=Extended Tier",
        "--access-key=ext-access", "--secret-key=ext-secret",
    )
    return boto3.client(
        "s3",
        endpoint_url=cluster.rgw_endpoint(),
        aws_access_key_id="ext-access",
        aws_secret_access_key="ext-secret",
        region_name="default",
        config=Config(s3={"addressing_style": "path"}, retries={"max_attempts": 3}),
    )


def test_s3_multipart_upload(s3):
    s3.create_bucket(Bucket="multipart-bucket")

    # Two parts: the S3 minimum 5MiB part plus a smaller final part
    part1 = os.urandom(5 * 1024 * 1024)
    part2 = os.urandom(1024 * 1024)
    expected = hashlib.sha256(part1 + part2).hexdigest()

    mpu = s3.create_multipart_upload(Bucket="multipart-bucket", Key="big.bin")
    upload_id = mpu["UploadId"]
    parts = []
    for number, body in ((1, part1), (2, part2)):
        resp = s3.upload_part(
            Bucket="multipart-bucket", Key="big.bin",
            UploadId=upload_id, PartNumber=number, Body=body,
        )
        parts.append({"PartNumber": number, "ETag": resp["ETag"]})
    s3.complete_multipart_upload(
        Bucket="multipart-bucket", Key="big.bin",
        UploadId=upload_id, MultipartUpload={"Parts": parts},
    )

    body = s3.get_object(Bucket="multipart-bucket", Key="big.bin")["Body"].read()
    assert len(body) == len(part1) + len(part2)
    assert hashlib.sha256(body).hexdigest() == expected


def test_s3_presigned_url(s3):
    s3.create_bucket(Bucket="presign-bucket")
    s3.put_object(Bucket="presign-bucket", Key="signed.txt", Body=b"presigned payload")

    url = s3.generate_presigned_url(
        "get_object",
        Params={"Bucket": "presign-bucket", "Key": "signed.txt"},
        ExpiresIn=300,
    )
    resp = requests.get(url, timeout=10)
    assert resp.status_code == 200
    assert resp.content == b"presigned payload"


def test_cluster_recovers_from_sigkill():
    """Crash-consistency: the marker-file bootstrap must recover from an
    unclean shutdown, not just an orderly SIGTERM restart."""
    with make_cluster(1) as container:
        cluster = CephCluster(container)
        cluster.wait_healthy()
        fsid = cluster.exec("ceph", "fsid").strip()

        cluster.kill()
        cluster.start()
        cluster.wait_healthy()

        assert cluster.exec("ceph", "fsid").strip() == fsid
        assert cluster.exec("ceph", "health").strip() == "HEALTH_OK"


def test_rbd_data_path_from_network_client():
    """Drive RBD over the wire from a second container: validates the mon
    advertised address, cephx over the network, and the OSD data path via
    userspace librbd — the sidecar topology real deployments use."""
    with Network() as net:
        with make_cluster(1).with_network(net) as server_container:
            server = CephCluster(server_container)
            server.wait_healthy()

            conf_b64 = server.exec("base64", "-w0", "/etc/ceph/ceph.conf").strip()
            key_b64 = server.exec(
                "base64", "-w0", "/etc/ceph/ceph.client.admin.keyring"
            ).strip()

            client_container = (
                DockerContainer(IMAGE_TAG)
                .with_network(net)
                .with_kwargs(entrypoint=["sleep", "infinity"])
            )
            with client_container:
                client = CephCluster(client_container)
                client.exec("bash", "-c", f"echo {conf_b64} | base64 -d > /etc/ceph/ceph.conf")
                client.exec(
                    "bash", "-c",
                    f"echo {key_b64} | base64 -d > /etc/ceph/ceph.client.admin.keyring",
                )

                # Full data roundtrip through librbd from the client side
                client.exec(
                    "bash", "-c",
                    "head -c 1048576 /dev/urandom > /tmp/payload"
                    " && rbd import /tmp/payload rbd/net-image"
                    " && rbd export rbd/net-image /tmp/roundtrip"
                    " && cmp /tmp/payload /tmp/roundtrip",
                )
                assert "net-image" in client.exec("rbd", "ls", "rbd")
