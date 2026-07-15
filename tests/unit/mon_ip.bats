#!/usr/bin/env bats
# Unit tests for monitor IP auto-detection parsing (used by bootstrap.sh)

setup() {
    source "$BATS_TEST_DIRNAME/../../scripts/lib/config.sh"
}

@test "extracts src address from a typical route lookup" {
    output="1.0.0.1 via 192.168.1.1 dev eth0 src 192.168.1.50 uid 0"
    [ "$(route_src_ip "$output")" = "192.168.1.50" ]
}

@test "extracts src address on a masquerade guest" {
    output="1.0.0.1 via 10.0.2.1 dev eth0 src 10.0.2.2 uid 0
    cache"
    [ "$(route_src_ip "$output")" = "10.0.2.2" ]
}

@test "prints nothing when no src field is present" {
    [ -z "$(route_src_ip "unreachable 1.0.0.1")" ]
}

@test "prints nothing for empty input" {
    [ -z "$(route_src_ip "")" ]
}
