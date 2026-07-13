#!/usr/bin/env bats
# Unit tests for test container naming (used by test-suite.sh; the
# workflow's collect-logs step must produce the same names)

setup() {
    source "$BATS_TEST_DIRNAME/../../scripts/lib/config.sh"
}

@test "extracts tag from full registry path" {
    [ "$(test_container_name 'quay.io/benjamin_holmes/ceph-aio:v19')" = "ceph-test-v19" ]
}

@test "handles simple repository:tag form" {
    [ "$(test_container_name 'ceph-aio:latest')" = "ceph-test-latest" ]
}

@test "sanitizes characters docker rejects in container names" {
    [ "$(test_container_name 'ceph-aio:v19.2.1')" = "ceph-test-v19_2_1" ]
}

@test "untagged image uses the sanitized image name" {
    [ "$(test_container_name 'ceph-aio')" = "ceph-test-ceph-aio" ]
}
