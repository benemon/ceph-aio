"""Shared fixtures for the ceph-aio end-to-end suite.

Each fixture provisions a throwaway ceph-aio container via Testcontainers
and blocks on the image's Docker HEALTHCHECK, which reports healthy once
every setup one-shot has completed and the monitor responds. Containers
are reaped automatically (Ryuk), including on test-process crash.

The image under test is selected with the IMAGE_TAG environment variable,
matching test-suite.sh.
"""

import json
import os
import time

import docker
import docker.errors
import pytest
from testcontainers.core.container import DockerContainer

IMAGE_TAG = os.environ.get("IMAGE_TAG", "ceph-aio:latest")


@pytest.fixture(scope="session", autouse=True)
def require_local_image():
    """Refuse to run unless IMAGE_TAG exists in the local Docker daemon.

    docker-py pulls from the registry when a tag is missing locally, so
    without this guard a missing --load in the build step would silently
    test the previously *published* image instead of the one just built.
    """
    try:
        docker.from_env().images.get(IMAGE_TAG)
    except docker.errors.ImageNotFound:
        pytest.exit(
            f"Image {IMAGE_TAG} is not present in the local Docker daemon. "
            "Build it first (docker buildx build --load). Refusing to fall "
            "back to a registry pull.",
            returncode=1,
        )

RGW_PORT = 8000
DASHBOARD_PORT = 8443

HEALTHY_TIMEOUT = 300


class CephCluster:
    """Thin driver for a running ceph-aio container."""

    def __init__(self, container: DockerContainer):
        self._container = container

    @property
    def _wrapped(self):
        return self._container.get_wrapped_container()

    def exec(self, *cmd: str) -> str:
        """Run a command in the container, asserting it succeeds."""
        exit_code, output = self._wrapped.exec_run(list(cmd))
        text = output.decode(errors="replace")
        assert exit_code == 0, f"{' '.join(cmd)} failed ({exit_code}): {text}"
        return text

    def ceph_json(self, *cmd: str):
        return json.loads(self.exec(*cmd, "-f", "json"))

    def wait_healthy(self, timeout: int = HEALTHY_TIMEOUT) -> None:
        """Block until the container's HEALTHCHECK reports healthy."""
        deadline = time.time() + timeout
        status = "unknown"
        while time.time() < deadline:
            self._wrapped.reload()
            health = self._wrapped.attrs["State"].get("Health") or {}
            status = health.get("Status", "none")
            if status == "healthy":
                return
            time.sleep(5)
        raise TimeoutError(f"container not healthy after {timeout}s (status: {status})")

    def endpoint(self, container_port: int) -> str:
        host = self._container.get_container_host_ip()
        port = self._container.get_exposed_port(container_port)
        return f"{host}:{port}"

    def rgw_endpoint(self) -> str:
        return f"http://{self.endpoint(RGW_PORT)}"

    def dashboard_endpoint(self) -> str:
        return f"https://{self.endpoint(DASHBOARD_PORT)}"


def make_cluster(osd_count: int = 1) -> DockerContainer:
    return (
        DockerContainer(IMAGE_TAG)
        .with_env("OSD_COUNT", str(osd_count))
        .with_env("OSD_SIZE", "1G")
        .with_env("DISABLE_MON_DISK_WARNINGS", "true")
        .with_exposed_ports(RGW_PORT, DASHBOARD_PORT)
    )


@pytest.fixture(params=[1, 2, 3], ids=lambda n: f"{n}osd")
def sized_cluster(request):
    """A fresh cluster per OSD count; parametrizes the sizing tests."""
    with make_cluster(request.param) as container:
        cluster = CephCluster(container)
        cluster.wait_healthy()
        yield cluster, request.param


@pytest.fixture(scope="module")
def cluster():
    """A single-OSD cluster shared by the service-level tests in a module."""
    with make_cluster(1) as container:
        c = CephCluster(container)
        c.wait_healthy()
        yield c
