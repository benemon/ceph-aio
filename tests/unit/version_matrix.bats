#!/usr/bin/env bats
# Unit tests for Ceph version discovery (used by the discover-versions
# job in .github/workflows/build-and-publish.yml)

setup() {
    source "$BATS_TEST_DIRNAME/../../scripts/lib/config.sh"
}

@test "keeps only bare major version tags" {
    tags=$'v18\nv19\nv19.2.0\nlatest\nv20\nv18.2.4-20240723'
    [ "$(filter_recent_major_tags "$tags")" = $'v18\nv19\nv20' ]
}

@test "returns the most recent majors version-sorted, not lexically" {
    # lexical sort would order v9 after v10..v12
    tags=$'v9\nv12\nv10\nv11'
    [ "$(filter_recent_major_tags "$tags")" = $'v10\nv11\nv12' ]
}

@test "count parameter limits the number of majors" {
    tags=$'v17\nv18\nv19\nv20'
    [ "$(filter_recent_major_tags "$tags" 2)" = $'v19\nv20' ]
}

@test "returns empty for a tag list with no majors" {
    [ -z "$(filter_recent_major_tags $'latest\nv19.2.0')" ]
}

@test "comma list converts to a trimmed JSON matrix" {
    [ "$(versions_to_json_matrix 'v18, v19 ,v20')" = '["v18","v19","v20"]' ]
}

@test "trailing commas and blank elements do not produce empty matrix entries" {
    # an empty-string entry would reach docker build as CEPH_VERSION=""
    [ "$(versions_to_json_matrix 'v19,')" = '["v19"]' ]
    [ "$(versions_to_json_matrix 'v19,,v20')" = '["v19","v20"]' ]
}

@test "single version produces a single-element matrix" {
    [ "$(versions_to_json_matrix 'v19')" = '["v19"]' ]
}
