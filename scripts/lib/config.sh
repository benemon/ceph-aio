#!/bin/bash
# Pure configuration helpers shared by bootstrap.sh, test-suite.sh and CI.
# No side effects, no external state: everything here is unit-tested in
# tests/unit/ and must stay sourceable outside the container.

# Replication size for a pool: one replica per OSD, capped at 3
# Usage: calc_pool_size <osd_count>
calc_pool_size() {
    local osd_count=$1
    if [ "$osd_count" -le 3 ]; then
        echo "$osd_count"
    else
        echo 3
    fi
}

# Minimum replicas required for I/O: size - 1, floor of 1
# Usage: calc_pool_min_size <pool_size>
calc_pool_min_size() {
    local pool_size=$1
    if [ "$pool_size" -gt 1 ]; then
        echo $((pool_size - 1))
    else
        echo 1
    fi
}

# Test container name for an image tag: strip registry/repository,
# sanitize anything Docker won't accept in a container name
# Usage: test_container_name <image_tag>
test_container_name() {
    local image_tag=$1
    echo "ceph-test-$(echo "$image_tag" | sed 's/.*://;s/[^a-zA-Z0-9_-]/_/g')"
}

# Filter a newline-separated tag list down to the most recent bare major
# version tags (v18, v19, ...), version-sorted
# Usage: filter_recent_major_tags <tags> [count]
filter_recent_major_tags() {
    local tags=$1
    local count=${2:-3}
    echo "$tags" | grep -E '^v[0-9]+$' | sort -V | tail -"$count"
}

# Convert a comma-separated version list to a compact JSON array for the
# build matrix, trimming whitespace and dropping empty elements. Trimming
# must happen before the empty check so trailing commas and stray
# whitespace don't produce empty matrix entries.
# Usage: versions_to_json_matrix <versions>
versions_to_json_matrix() {
    local versions=$1
    echo "$versions" | jq -R -s -c \
        'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'
}
