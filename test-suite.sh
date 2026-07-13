#!/bin/bash
# Comprehensive test suite for Ceph AIO container
# Tests all OSD configurations and validates cluster health

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_RESULTS=()
FAILED_TESTS=()

# Detect container runtime (docker or podman)
# Can be overridden via CONTAINER_RUNTIME env var
if [ -n "$CONTAINER_RUNTIME" ] && command -v "$CONTAINER_RUNTIME" &> /dev/null; then
    # Use explicitly set CONTAINER_RUNTIME if valid
    :
elif command -v docker &> /dev/null; then
    CONTAINER_RUNTIME="docker"
elif command -v podman &> /dev/null; then
    CONTAINER_RUNTIME="podman"
else
    echo "ERROR: Neither docker nor podman found"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is required to parse cluster state"
    exit 1
fi

# Shared pure helpers (container naming, etc.)
source "$SCRIPT_DIR/scripts/lib/config.sh"

# Image tag to test (can be overridden via IMAGE_TAG env var)
# Supports both simple tags (ceph-aio:latest) and full paths (quay.io/user/ceph-aio:v19)
IMAGE_TAG="${IMAGE_TAG:-ceph-aio:latest}"

# Container name (unique per image to avoid conflicts in parallel CI runs)
CONTAINER_NAME="$(test_container_name "$IMAGE_TAG")"

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
    $CONTAINER_RUNTIME stop $CONTAINER_NAME 2>/dev/null || true
    $CONTAINER_RUNTIME rm $CONTAINER_NAME 2>/dev/null || true
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
        if $CONTAINER_RUNTIME exec $CONTAINER_NAME ceph -s &>/dev/null; then
            # Check if OSDs are up
            local osds_up=$($CONTAINER_RUNTIME exec $CONTAINER_NAME ceph osd stat -f json 2>/dev/null | jq -r '.num_up_osds // 0' || echo 0)
            if [ "$osds_up" -eq "$osd_count" ]; then
                # Check health status
                local health=$($CONTAINER_RUNTIME exec $CONTAINER_NAME ceph health 2>/dev/null || echo "")
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
    $CONTAINER_RUNTIME exec $CONTAINER_NAME ceph -s || true
    return 1
}

# Verify health is HEALTH_OK, retrying to ride out transient warnings.
# Background setup jobs (e.g. RGW pool creation) can briefly raise warnings
# such as POOL_APP_NOT_ENABLED after the cluster first reports healthy.
verify_health_ok() {
    local max_wait=${1:-60}
    local elapsed=0
    local health=""

    while [ $elapsed -lt $max_wait ]; do
        health=$($CONTAINER_RUNTIME exec $CONTAINER_NAME ceph health 2>/dev/null || echo "")
        if [ "$health" = "HEALTH_OK" ]; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    error "Expected HEALTH_OK within ${max_wait}s, got $health"
    $CONTAINER_RUNTIME exec $CONTAINER_NAME ceph health detail || true
    return 1
}

# Wait for a supervisor-managed program to reach RUNNING state.
# A one-shot status check can catch a program in STARTING/BACKOFF while
# it waits on its prerequisites.
wait_for_supervisor_program() {
    local program=$1
    local max_wait=${2:-90}
    local elapsed=0

    log "Waiting for supervisor program '$program' to be RUNNING (max ${max_wait}s)..."

    while [ $elapsed -lt $max_wait ]; do
        if $CONTAINER_RUNTIME exec $CONTAINER_NAME supervisorctl status "$program" 2>/dev/null | grep -q RUNNING; then
            success "Program '$program' is RUNNING"
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done

    error "Program '$program' not RUNNING within ${max_wait}s"
    $CONTAINER_RUNTIME exec $CONTAINER_NAME supervisorctl status || true
    return 1
}

# Wait for a file to exist inside the test container. Setup one-shots
# write completion markers under /var/run/ceph/; waiting on those is the
# only reliable way to order test assertions against background setup.
wait_for_container_file() {
    local path=$1
    local max_wait=${2:-120}

    log "Waiting for $path in container (max ${max_wait}s)..."

    if ! $CONTAINER_RUNTIME exec $CONTAINER_NAME \
        timeout "$max_wait" bash -c "while [ ! -f '$path' ]; do sleep 2; done"; then
        error "File $path did not appear within ${max_wait}s"
        return 1
    fi
    return 0
}

# Test 1: Single OSD configuration
test_single_osd() {
    log "Starting container with OSD_COUNT=1"
    $CONTAINER_RUNTIME run -d --name $CONTAINER_NAME \
        -e OSD_COUNT=1 \
        -e OSD_SIZE=1G \
        -e DISABLE_MON_DISK_WARNINGS=true \
        $IMAGE_TAG || return 1

    wait_for_cluster 120 1 || return 1

    # Pool assertions need rbd-pool-setup to have finished
    wait_for_container_file /var/run/ceph/rbd-configured 120 || {
        error "RBD pool setup did not complete"
        return 1
    }

    # Verify pool size
    local size=$($CONTAINER_RUNTIME exec $CONTAINER_NAME ceph osd pool get rbd size -f json | jq -r '.size')
    if [ "$size" != "1" ]; then
        error "Expected pool size 1, got $size"
        return 1
    fi

    # Verify health is OK (warnings should be silenced)
    verify_health_ok 60 || return 1

    cleanup
    return 0
}

# Test 2: Two OSD configuration
test_two_osds() {
    log "Starting container with OSD_COUNT=2"
    $CONTAINER_RUNTIME run -d --name $CONTAINER_NAME \
        -e OSD_COUNT=2 \
        -e OSD_SIZE=1G \
        -e DISABLE_MON_DISK_WARNINGS=true \
        $IMAGE_TAG || return 1

    wait_for_cluster 150 2 || return 1

    # Pool assertions need rbd-pool-setup to have finished
    wait_for_container_file /var/run/ceph/rbd-configured 120 || {
        error "RBD pool setup did not complete"
        return 1
    }

    # Verify pool size
    local size=$($CONTAINER_RUNTIME exec $CONTAINER_NAME ceph osd pool get rbd size -f json | jq -r '.size')
    if [ "$size" != "2" ]; then
        error "Expected pool size 2, got $size"
        return 1
    fi

    # Verify min_size
    local min_size=$($CONTAINER_RUNTIME exec $CONTAINER_NAME ceph osd pool get rbd min_size -f json | jq -r '.min_size')
    if [ "$min_size" != "1" ]; then
        error "Expected min_size 1, got $min_size"
        return 1
    fi

    # Verify both OSDs are up (already confirmed by wait_for_cluster)
    # Just double-check with osd stat
    local osds_up=$($CONTAINER_RUNTIME exec $CONTAINER_NAME ceph osd stat -f json | jq -r '.num_up_osds')
    if [ "$osds_up" != "2" ]; then
        error "Expected 2 OSDs up, got $osds_up"
        $CONTAINER_RUNTIME exec $CONTAINER_NAME ceph osd tree
        return 1
    fi

    cleanup
    return 0
}

# Test 3: Three OSD configuration
test_three_osds() {
    log "Starting container with OSD_COUNT=3"
    $CONTAINER_RUNTIME run -d --name $CONTAINER_NAME \
        -e OSD_COUNT=3 \
        -e OSD_SIZE=1G \
        -e DISABLE_MON_DISK_WARNINGS=true \
        $IMAGE_TAG || return 1

    wait_for_cluster 180 3 || return 1

    # Pool assertions need rbd-pool-setup to have finished
    wait_for_container_file /var/run/ceph/rbd-configured 120 || {
        error "RBD pool setup did not complete"
        return 1
    }

    # Verify pool size
    local size=$($CONTAINER_RUNTIME exec $CONTAINER_NAME ceph osd pool get rbd size -f json | jq -r '.size')
    if [ "$size" != "3" ]; then
        error "Expected pool size 3, got $size"
        return 1
    fi

    # Verify min_size
    local min_size=$($CONTAINER_RUNTIME exec $CONTAINER_NAME ceph osd pool get rbd min_size -f json | jq -r '.min_size')
    if [ "$min_size" != "2" ]; then
        error "Expected min_size 2, got $min_size"
        return 1
    fi

    # Verify all three OSDs are up
    local osds_up=$($CONTAINER_RUNTIME exec $CONTAINER_NAME ceph osd stat -f json | jq -r '.num_up_osds')
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
    $CONTAINER_RUNTIME run -d --name $CONTAINER_NAME \
        -p 8443:8443 \
        -e OSD_COUNT=1 \
        -e OSD_SIZE=1G \
        -e DISABLE_MON_DISK_WARNINGS=true \
        $IMAGE_TAG || return 1

    wait_for_cluster 120 1 || return 1

    # Wait for dashboard setup to complete (runs as a separate supervisor job)
    wait_for_container_file /var/run/ceph/dashboard-configured 120 || {
        error "Dashboard setup did not complete"
        return 1
    }

    # Check if dashboard is enabled by checking mgr services directly
    local dashboard_url=$($CONTAINER_RUNTIME exec $CONTAINER_NAME ceph mgr services -f json 2>/dev/null | jq -r '.dashboard // empty')
    if [ -z "$dashboard_url" ]; then
        error "Dashboard URL not configured - dashboard may not be enabled"
        $CONTAINER_RUNTIME exec $CONTAINER_NAME ceph mgr services
        return 1
    fi

    log "Dashboard URL: $dashboard_url"

    cleanup
    return 0
}

# Test 5: RGW functionality
test_rgw() {
    log "Starting container for RGW test"
    $CONTAINER_RUNTIME run -d --name $CONTAINER_NAME \
        -p 8000:8000 \
        -e OSD_COUNT=1 \
        -e OSD_SIZE=1G \
        -e DISABLE_MON_DISK_WARNINGS=true \
        $IMAGE_TAG || return 1

    wait_for_cluster 120 1 || return 1

    # Wait for RGW configuration to complete. setup-rgw.sh writes this
    # marker after the realm/zone/period are committed; realm queries and
    # user creation race the setup job if gated on cluster health alone.
    wait_for_container_file /var/run/ceph/rgw-configured 180 || {
        error "RGW setup did not complete"
        $CONTAINER_RUNTIME exec $CONTAINER_NAME cat /var/log/supervisor/rgw-setup.log 2>&1 || true
        $CONTAINER_RUNTIME exec $CONTAINER_NAME cat /var/log/supervisor/rgw-setup-error.log 2>&1 || true
        return 1
    }
    log "RGW setup complete"

    # Check RGW daemon is running (run-rgw.sh starts it only after the
    # configuration marker appears, so allow time for it to come up)
    wait_for_supervisor_program ceph-rgw 90 || {
        error "RGW daemon not running"
        return 1
    }

    # Check RGW realm exists
    if ! $CONTAINER_RUNTIME exec $CONTAINER_NAME radosgw-admin realm list | grep -q "default"; then
        error "RGW realm not configured"
        return 1
    fi

    # Create test user
    if ! $CONTAINER_RUNTIME exec $CONTAINER_NAME radosgw-admin user create \
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
    $CONTAINER_RUNTIME run -d --name $CONTAINER_NAME \
        -e OSD_COUNT=1 \
        -e OSD_SIZE=1G \
        -e DISABLE_MON_DISK_WARNINGS=true \
        $IMAGE_TAG || return 1

    wait_for_cluster 120 1 || return 1

    # Wait for rbd-pool-setup to finish before asserting on the pool
    wait_for_container_file /var/run/ceph/rbd-configured 120 || {
        error "RBD pool setup did not complete"
        return 1
    }

    # Check RBD pool exists
    if ! $CONTAINER_RUNTIME exec $CONTAINER_NAME ceph osd pool ls | grep -q "^rbd$"; then
        error "RBD pool not found"
        return 1
    fi

    # Create test image
    if ! $CONTAINER_RUNTIME exec $CONTAINER_NAME rbd create testimage --size 100M --pool rbd &>/dev/null; then
        error "Failed to create RBD image"
        return 1
    fi

    # Verify image exists
    if ! $CONTAINER_RUNTIME exec $CONTAINER_NAME rbd ls rbd | grep -q "testimage"; then
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
    $CONTAINER_RUNTIME run -d --name $CONTAINER_NAME \
        -e OSD_COUNT=1 \
        -e OSD_SIZE=1G \
        -e DISABLE_MON_DISK_WARNINGS=true \
        -e DASHBOARD_USER=testadmin \
        -e DASHBOARD_PASS=TestPass123! \
        $IMAGE_TAG || return 1

    wait_for_cluster 120 1 || return 1

    # Wait for dashboard setup to complete (runs as a separate supervisor job)
    wait_for_container_file /var/run/ceph/dashboard-configured 120 || {
        error "Dashboard setup did not complete"
        return 1
    }

    # Verify dashboard is running
    if ! $CONTAINER_RUNTIME exec $CONTAINER_NAME ceph mgr services | grep -q "dashboard"; then
        error "Dashboard not running"
        return 1
    fi

    # Verify custom user was created (not the default 'admin')
    if ! $CONTAINER_RUNTIME exec $CONTAINER_NAME ceph dashboard ac-user-show testadmin &>/dev/null; then
        error "Custom dashboard user 'testadmin' was not created"
        return 1
    fi

    log "Verified custom dashboard user 'testadmin' exists"

    log "Custom dashboard credentials configured"

    cleanup
    return 0
}

# Test 8: Replication with object writes
test_replication() {
    log "Starting container with 3 OSDs for replication test"
    $CONTAINER_RUNTIME run -d --name $CONTAINER_NAME \
        -e OSD_COUNT=3 \
        -e OSD_SIZE=1G \
        -e DISABLE_MON_DISK_WARNINGS=true \
        $IMAGE_TAG || return 1

    wait_for_cluster 180 3 || return 1

    # Object writes go to the rbd pool; wait for its setup to finish
    wait_for_container_file /var/run/ceph/rbd-configured 120 || {
        error "RBD pool setup did not complete"
        return 1
    }

    # Write test object
    if ! echo "test data" | $CONTAINER_RUNTIME exec -i $CONTAINER_NAME rados put testobj - -p rbd; then
        error "Failed to write test object"
        return 1
    fi

    # Verify object exists
    if ! $CONTAINER_RUNTIME exec $CONTAINER_NAME rados -p rbd ls | grep -q "testobj"; then
        error "Test object not found"
        return 1
    fi

    # Check object mapping (shows which OSDs have the object)
    local osd_map=$($CONTAINER_RUNTIME exec $CONTAINER_NAME ceph osd map rbd testobj)
    log "Object mapping: $osd_map"

    # Read back the object
    local data=$($CONTAINER_RUNTIME exec $CONTAINER_NAME rados get testobj - -p rbd)
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
    $CONTAINER_RUNTIME run -d --name $CONTAINER_NAME \
        -e OSD_COUNT=1 \
        -e OSD_SIZE=1G \
        -e DISABLE_MON_DISK_WARNINGS=true \
        $IMAGE_TAG || return 1

    wait_for_cluster 120 1 || return 1

    # Wait for auth-setup to complete
    wait_for_container_file /var/run/ceph/auth-configured 60 || {
        error "Auth setup did not complete"
        return 1
    }

    # Verify cephx authentication is configured
    log "Verifying cephx authentication settings..."

    local auth_client=$($CONTAINER_RUNTIME exec $CONTAINER_NAME ceph config get mon auth_client_required 2>/dev/null)
    if [ "$auth_client" != "cephx" ]; then
        error "auth_client_required should be cephx, got: $auth_client"
        return 1
    fi

    local auth_cluster=$($CONTAINER_RUNTIME exec $CONTAINER_NAME ceph config get mon auth_cluster_required 2>/dev/null)
    if [ "$auth_cluster" != "cephx" ]; then
        error "auth_cluster_required should be cephx, got: $auth_cluster"
        return 1
    fi

    local auth_service=$($CONTAINER_RUNTIME exec $CONTAINER_NAME ceph config get mon auth_service_required 2>/dev/null)
    if [ "$auth_service" != "cephx" ]; then
        error "auth_service_required should be cephx, got: $auth_service"
        return 1
    fi

    log "Cephx authentication properly configured"

    # Verify insecure global_id reclaim is disabled
    local auth_setting=$($CONTAINER_RUNTIME exec $CONTAINER_NAME ceph config get mon auth_allow_insecure_global_id_reclaim)
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
    $CONTAINER_RUNTIME run -d --name $CONTAINER_NAME \
        -e OSD_COUNT=1 \
        -e OSD_SIZE=1G \
        -e DISABLE_MON_DISK_WARNINGS=true \
        $IMAGE_TAG || return 1

    wait_for_cluster 120 1 || return 1

    # Get initial FSID
    local fsid1=$($CONTAINER_RUNTIME exec $CONTAINER_NAME ceph fsid)

    # Restart container
    log "Restarting container..."
    $CONTAINER_RUNTIME restart $CONTAINER_NAME

    sleep 10
    wait_for_cluster 120 1 || return 1

    # Get FSID after restart
    local fsid2=$($CONTAINER_RUNTIME exec $CONTAINER_NAME ceph fsid)

    if [ "$fsid1" != "$fsid2" ]; then
        error "FSID changed after restart: $fsid1 -> $fsid2"
        return 1
    fi

    log "Idempotency test successful"

    cleanup
    return 0
}

# Test 11: Container HEALTHCHECK reaches healthy
test_healthcheck() {
    log "Starting container for healthcheck test"
    $CONTAINER_RUNTIME run -d --name $CONTAINER_NAME \
        -e OSD_COUNT=1 \
        -e OSD_SIZE=1G \
        -e DISABLE_MON_DISK_WARNINGS=true \
        $IMAGE_TAG || return 1

    log "Waiting for container to report healthy (max 300s)..."
    local elapsed=0
    local status=""

    while [ $elapsed -lt 300 ]; do
        status=$($CONTAINER_RUNTIME inspect --format '{{.State.Health.Status}}' $CONTAINER_NAME 2>/dev/null || echo "")
        if [ "$status" = "healthy" ]; then
            success "Container reports healthy after ${elapsed}s"
            cleanup
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    error "Container did not report healthy within 300s (status: ${status:-unknown})"
    $CONTAINER_RUNTIME exec $CONTAINER_NAME /scripts/healthcheck.sh 2>&1 || true
    return 1
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
    run_test "Container Healthcheck" test_healthcheck

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
        warn "Container '$CONTAINER_NAME' left running for debugging"
        return 1
    fi
}

# Run main
main "$@"
