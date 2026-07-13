#!/usr/bin/env bats
# Unit tests for replication sizing logic (used by bootstrap.sh)

setup() {
    source "$BATS_TEST_DIRNAME/../../scripts/lib/config.sh"
}

@test "pool size equals OSD count up to 3" {
    [ "$(calc_pool_size 1)" -eq 1 ]
    [ "$(calc_pool_size 2)" -eq 2 ]
    [ "$(calc_pool_size 3)" -eq 3 ]
}

@test "pool size caps at 3 for larger clusters" {
    [ "$(calc_pool_size 4)" -eq 3 ]
    [ "$(calc_pool_size 10)" -eq 3 ]
}

@test "min size is 1 for a single replica" {
    [ "$(calc_pool_min_size 1)" -eq 1 ]
}

@test "min size is size minus one otherwise" {
    [ "$(calc_pool_min_size 2)" -eq 1 ]
    [ "$(calc_pool_min_size 3)" -eq 2 ]
}
