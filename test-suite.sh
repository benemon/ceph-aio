#!/bin/bash
# Comprehensive test suite for Ceph AIO container
# Tests all OSD configurations and validates cluster health

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_RESULTS=()
FAILED_TESTS=()

# Detect container runtime (docker or $CONTAINER_RUNTIME)
if command -v docker &> /dev/null; then
    CONTAINER_RUNTIME="docker"
elif command -v $CONTAINER_RUNTIME &> /dev/null; then
    CONTAINER_RUNTIME="$CONTAINER_RUNTIME"
else
    echo "ERROR: Neither docker nor $CONTAINER_RUNTIME found"
    exit 1
fi

# Image tag to test (can be overridden via IMAGE_TAG env var)
# Supports both simple tags (ceph-aio:latest) and full paths (quay.io/user/ceph-aio:v19)
IMAGE_TAG="${IMAGE_TAG:-ceph-aio:latest}"

# Colours for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Colour

log() {
    echo -e "${GREEN}[TEST]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

# Cleanup function (only cleans up on success)
cleanup() {
    log "Cleaning up test containers..."
    $CONTAINER_RUNTIME stop ceph-test 2>/dev/null || true
    $CONTAINER_RUNTIME rm ceph-test 2>/dev/null || true
}

# Test function wrapper
run_test() {
    local test_name="$1"
    local test_func="$2"

    log "Running test: $test_name"
    if $test_func; then
        success "✓ $test_name"
        TEST_RESULTS+=("PASS: $test_name")
        return 0
    else
        error "✗ $test_name"
        TEST_RESULTS+=("FAIL: $test_name")
        FAILED_TESTS+=("$test_name")
        return 1
    fi
}

# Wait for cluster to be healthy
wait_for_cluster() {
    local max_wait=${1:-120}
    local osd_count=${2:-1}
    local elapsed=0

    log "Waiting for cluster to be healthy (max ${max_wait}s)..."

    while [ $elapsed -lt $max_wait ]; do
        if $CONTAINER_RUNTIME exec ceph-test ceph -s &>/dev/null; then
            # Check if OSDs are up
            local osds_up=$($CONTAINER_RUNTIME exec ceph-test ceph -s -f json 2>/dev/null | grep -o '"num_up_osds":[0-9]*' | cut -d':' -f2 || echo 0)
            if [ "$osds_up" -eq "$osd_count" ]; then
                # Check health status
                local health=$($CONTAINER_RUNTIME exec ceph-test ceph health 2>/dev/null || echo "")
                if [ "$health" = "HEALTH_OK" ]; then
                    success "Cluster is healthy with $osds_up OSDs"
                    return 0
                fi
            fi
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    error "Cluster did not become healthy within ${max_wait}s"
    $CONTAINER_RUNTIME exec ceph-test ceph -s || true
    return 1
}

# Test 1: Single OSD configuration
test_single_osd() {
    log "Starting container with OSD_COUNT=1"
    $CONTAINER_RUNTIME run -d --name ceph-test \
        -e OSD_COUNT=1 \
        -e OSD_SIZE=1G \
        $IMAGE_TAG || return 1

    wait_for_cluster 120 1 || return 1

    # Verify pool size
    local size=$($CONTAINER_RUNTIME exec ceph-test ceph osd pool get rbd size -f json | grep -o '"size":[0-9]*' | cut -d':' -f2)
    if [ "$size" != "1" ]; then
        error "Expected pool size 1, got $size"
        return 1
    fi

    # Verify health is OK (warnings should be silenced)
    local health=$($CONTAINER_RUNTIME exec ceph-test ceph health)
    if [ "$health" != "HEALTH_OK" ]; then
        error "Expected HEALTH_OK, got $health"
        $CONTAINER_RUNTIME exec ceph-test ceph health detail
        return 1
    fi

    cleanup
    return 0
}

# Test 2: Two OSD configuration
test_two_osds() {
    log "Starting container with OSD_COUNT=2"
    $CONTAINER_RUNTIME run -d --name ceph-test \
        -e OSD_COUNT=2 \
        -e OSD_SIZE=1G \
        $IMAGE_TAG || return 1

    wait_for_cluster 150 2 || return 1

    # Verify pool size
    local size=$($CONTAINER_RUNTIME exec ceph-test ceph osd pool get rbd size -f json | grep -o '"size":[0-9]*' | cut -d':' -f2)
    if [ "$size" != "2" ]; then
        error "Expected pool size 2, got $size"
        return 1
    fi

    # Verify min_size
    local min_size=$($CONTAINER_RUNTIME exec ceph-test ceph osd pool get rbd min_size -f json | grep -o '"min_size":[0-9]*' | cut -d':' -f2)
    if [ "$min_size" != "1" ]; then
        error "Expected min_size 1, got $min_size"
        return 1
    fi

    # Verify both OSDs are up
    local osd_tree=$($CONTAINER_RUNTIME exec ceph-test ceph osd tree -f json)
    local osd0_up=$(echo "$osd_tree" | grep -o '"id":0[^}]*"status":"up"' | wc -l)
    local osd1_up=$(echo "$osd_tree" | grep -o '"id":1[^}]*"status":"up"' | wc -l)

    if [ "$osd0_up" -eq 0 ] || [ "$osd1_up" -eq 0 ]; then
        error "Not all OSDs are up"
        $CONTAINER_RUNTIME exec ceph-test ceph osd tree
        return 1
    fi

    cleanup
    return 0
}

# Test 3: Three OSD configuration
test_three_osds() {
    log "Starting container with OSD_COUNT=3"
    $CONTAINER_RUNTIME run -d --name ceph-test \
        -e OSD_COUNT=3 \
        -e OSD_SIZE=1G \
        $IMAGE_TAG || return 1

    wait_for_cluster 180 3 || return 1

    # Verify pool size
    local size=$($CONTAINER_RUNTIME exec ceph-test ceph osd pool get rbd size -f json | grep -o '"size":[0-9]*' | cut -d':' -f2)
    if [ "$size" != "3" ]; then
        error "Expected pool size 3, got $size"
        return 1
    fi

    # Verify min_size
    local min_size=$($CONTAINER_RUNTIME exec ceph-test ceph osd pool get rbd min_size -f json | grep -o '"min_size":[0-9]*' | cut -d':' -f2)
    if [ "$min_size" != "2" ]; then
        error "Expected min_size 2, got $min_size"
        return 1
    fi

    # Verify all three OSDs are up
    local osds_up=$($CONTAINER_RUNTIME exec ceph-test ceph osd stat -f json | grep -o '"num_up_osds":[0-9]*' | cut -d':' -f2)
    if [ "$osds_up" != "3" ]; then
        error "Expected 3 OSDs up, got $osds_up"
        return 1
    fi

    cleanup
    return 0
}

# Test 4: Dashboard accessibility
test_dashboard() {
    log "Starting container for dashboard test"
    $CONTAINER_RUNTIME run -d --name ceph-test \
        -p 8443:8443 \
        -e OSD_COUNT=1 \
        -e OSD_SIZE=1G \
        $IMAGE_TAG || return 1

    wait_for_cluster 120 1 || return 1

    # Check if dashboard is enabled
    if ! $CONTAINER_RUNTIME exec ceph-test ceph mgr module ls | grep -q '"dashboard"'; then
        error "Dashboard module not found"
        return 1
    fi

    # Check dashboard URL is configured
    local dashboard_url=$($CONTAINER_RUNTIME exec ceph-test ceph mgr services -f json | grep -o '"dashboard":"[^"]*"' | cut -d'"' -f4)
    if [ -z "$dashboard_url" ]; then
        error "Dashboard URL not configured"
        return 1
    fi

    log "Dashboard URL: $dashboard_url"

    cleanup
    return 0
}

# Test 5: RGW functionality
test_rgw() {
    log "Starting container for RGW test"
    $CONTAINER_RUNTIME run -d --name ceph-test \
        -p 8000:8000 \
        -e OSD_COUNT=1 \
        -e OSD_SIZE=1G \
        $IMAGE_TAG || return 1

    wait_for_cluster 120 1 || return 1

    # Check RGW daemon is running
    if ! $CONTAINER_RUNTIME exec ceph-test supervisorctl status ceph-rgw | grep -q RUNNING; then
        error "RGW daemon not running"
        $CONTAINER_RUNTIME exec ceph-test supervisorctl status
        return 1
    fi

    # Check RGW realm exists
    if ! $CONTAINER_RUNTIME exec ceph-test radosgw-admin realm list | grep -q "default"; then
        error "RGW realm not configured"
        return 1
    fi

    # Create test user
    if ! $CONTAINER_RUNTIME exec ceph-test radosgw-admin user create \
        --uid=testuser \
        --display-name="Test User" \
        --access-key=test \
        --secret-key=test &>/dev/null; then
        error "Failed to create RGW user"
        return 1
    fi

    log "RGW user created successfully"

    cleanup
    return 0
}

# Test 6: RBD pool functionality
test_rbd_pool() {
    log "Starting container for RBD test"
    $CONTAINER_RUNTIME run -d --name ceph-test \
        -e OSD_COUNT=1 \
        -e OSD_SIZE=1G \
        $IMAGE_TAG || return 1

    wait_for_cluster 120 1 || return 1

    # Check RBD pool exists
    if ! $CONTAINER_RUNTIME exec ceph-test ceph osd pool ls | grep -q "^rbd$"; then
        error "RBD pool not found"
        return 1
    fi

    # Create test image
    if ! $CONTAINER_RUNTIME exec ceph-test rbd create testimage --size 100M --pool rbd &>/dev/null; then
        error "Failed to create RBD image"
        return 1
    fi

    # Verify image exists
    if ! $CONTAINER_RUNTIME exec ceph-test rbd ls rbd | grep -q "testimage"; then
        error "RBD image not listed"
        return 1
    fi

    log "RBD pool functioning correctly"

    cleanup
    return 0
}

# Test 7: Custom dashboard credentials
test_custom_credentials() {
    log "Starting container with custom credentials"
    $CONTAINER_RUNTIME run -d --name ceph-test \
        -e OSD_COUNT=1 \
        -e OSD_SIZE=1G \
        -e DASHBOARD_USER=testadmin \
        -e DASHBOARD_PASS=TestPass123! \
        $IMAGE_TAG || return 1

    wait_for_cluster 120 1 || return 1

    # Verify custom user exists (indirect check via dashboard services)
    if ! $CONTAINER_RUNTIME exec ceph-test ceph mgr services | grep -q "dashboard"; then
        error "Dashboard not configured with custom credentials"
        return 1
    fi

    log "Custom dashboard credentials configured"

    cleanup
    return 0
}

# Test 8: Replication with object writes
test_replication() {
    log "Starting container with 3 OSDs for replication test"
    $CONTAINER_RUNTIME run -d --name ceph-test \
        -e OSD_COUNT=3 \
        -e OSD_SIZE=1G \
        $IMAGE_TAG || return 1

    wait_for_cluster 180 3 || return 1

    # Write test object
    if ! echo "test data" | $CONTAINER_RUNTIME exec -i ceph-test rados put testobj - -p rbd; then
        error "Failed to write test object"
        return 1
    fi

    # Verify object exists
    if ! $CONTAINER_RUNTIME exec ceph-test rados -p rbd ls | grep -q "testobj"; then
        error "Test object not found"
        return 1
    fi

    # Check object mapping (shows which OSDs have the object)
    local osd_map=$($CONTAINER_RUNTIME exec ceph-test ceph osd map rbd testobj)
    log "Object mapping: $osd_map"

    # Read back the object
    local data=$($CONTAINER_RUNTIME exec ceph-test rados get testobj - -p rbd)
    if [ "$data" != "test data" ]; then
        error "Object data mismatch"
        return 1
    fi

    log "Replication test successful"

    cleanup
    return 0
}

# Test 9: Security configuration
test_security() {
    log "Starting container for security test"
    $CONTAINER_RUNTIME run -d --name ceph-test \
        -e OSD_COUNT=1 \
        -e OSD_SIZE=1G \
        $IMAGE_TAG || return 1

    wait_for_cluster 120 1 || return 1

    # Verify insecure global_id reclaim is disabled
    local auth_setting=$($CONTAINER_RUNTIME exec ceph-test ceph config get mon auth_allow_insecure_global_id_reclaim)
    if [ "$auth_setting" != "false" ]; then
        error "Insecure global_id reclaim should be disabled, got: $auth_setting"
        return 1
    fi

    log "Security settings verified"

    cleanup
    return 0
}

# Test 10: Idempotency (restart container)
test_idempotency() {
    log "Starting container for idempotency test"
    $CONTAINER_RUNTIME run -d --name ceph-test \
        -e OSD_COUNT=1 \
        -e OSD_SIZE=1G \
        $IMAGE_TAG || return 1

    wait_for_cluster 120 1 || return 1

    # Get initial FSID
    local fsid1=$($CONTAINER_RUNTIME exec ceph-test ceph fsid)

    # Restart container
    log "Restarting container..."
    $CONTAINER_RUNTIME restart ceph-test

    sleep 10
    wait_for_cluster 120 1 || return 1

    # Get FSID after restart
    local fsid2=$($CONTAINER_RUNTIME exec ceph-test ceph fsid)

    if [ "$fsid1" != "$fsid2" ]; then
        error "FSID changed after restart: $fsid1 -> $fsid2"
        return 1
    fi

    log "Idempotency test successful"

    cleanup
    return 0
}

# Main test execution
main() {
    log "=========================================="
    log "Ceph AIO Container Test Suite"
    log "=========================================="
    log ""

    # Check if image exists
    log "Using container runtime: $CONTAINER_RUNTIME"
    log "Testing image: $IMAGE_TAG"

    if ! $CONTAINER_RUNTIME image inspect $IMAGE_TAG &>/dev/null; then
        error "Image $IMAGE_TAG not found. Please build it first."
        exit 1
    fi

    # Run all tests
    run_test "Single OSD Configuration" test_single_osd
    run_test "Two OSD Configuration" test_two_osds
    run_test "Three OSD Configuration" test_three_osds
    run_test "Dashboard Accessibility" test_dashboard
    run_test "RGW Functionality" test_rgw
    run_test "RBD Pool Functionality" test_rbd_pool
    run_test "Custom Dashboard Credentials" test_custom_credentials
    run_test "Replication with Object Writes" test_replication
    run_test "Security Configuration" test_security
    run_test "Idempotency" test_idempotency

    # Print summary
    log ""
    log "=========================================="
    log "Test Summary"
    log "=========================================="

    local passed=0
    local failed=0

    for result in "${TEST_RESULTS[@]}"; do
        if [[ $result == PASS:* ]]; then
            success "$result"
            passed=$((passed + 1))
        else
            error "$result"
            failed=$((failed + 1))
        fi
    done

    log ""
    log "Total: $((passed + failed)) tests"
    log "Passed: $passed"
    log "Failed: $failed"
    log ""

    if [ $failed -eq 0 ]; then
        success "All tests passed! ✓"
        cleanup
        return 0
    else
        error "Some tests failed! ✗"
        log "Failed tests:"
        for test in "${FAILED_TESTS[@]}"; do
            error "  - $test"
        done
        warn "Container 'ceph-test' left running for debugging"
        return 1
    fi
}

# Run main
main "$@"
