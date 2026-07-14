#!/bin/bash
# Common utilities for Ceph setup scripts

# Logging functions
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

success() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] SUCCESS: $*"
}

# Wait for a file to exist
# Usage: wait_for_file <filepath> [timeout_seconds]
wait_for_file() {
    local file=$1
    local timeout=${2:-60}
    local elapsed=0

    log "Waiting for file: $file (timeout: ${timeout}s)"

    while [ $elapsed -lt $timeout ]; do
        if [ -f "$file" ]; then
            success "File exists: $file"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    error "Timeout waiting for file: $file"
    return 1
}

# Wait for a command to succeed
# Usage: wait_for_command <timeout_seconds> <command> [args...]
wait_for_command() {
    local timeout=$1
    shift
    local elapsed=0

    log "Waiting for command to succeed: $* (timeout: ${timeout}s)"

    while [ $elapsed -lt $timeout ]; do
        if "$@" 2>/dev/null; then
            success "Command succeeded: $*"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    error "Timeout waiting for command: $*"
    return 1
}

# Wait for Ceph cluster to be responsive
# Usage: wait_for_cluster [timeout_seconds]
wait_for_cluster() {
    wait_for_command "${1:-30}" ceph mon stat
}

# Wait for at least <count> OSDs to be up
# Usage: wait_for_osds <count> [timeout_seconds]
wait_for_osds() {
    local count=$1
    local timeout=${2:-180}
    local elapsed=0
    local osds_up=0

    log "Waiting for $count OSD(s) to be up (timeout: ${timeout}s)"

    while [ $elapsed -lt $timeout ]; do
        osds_up=$(ceph osd stat -f json 2>/dev/null | jq -r '.num_up_osds // 0' 2>/dev/null || echo 0)
        if [ "${osds_up:-0}" -ge "$count" ]; then
            success "$osds_up OSD(s) up"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    error "Only ${osds_up:-0} of $count OSD(s) up after ${timeout}s"
    return 1
}

# Wait for an active mgr to be available
# Usage: wait_for_mgr [timeout_seconds]
wait_for_mgr() {
    local timeout=${1:-120}
    local elapsed=0

    log "Waiting for active mgr (timeout: ${timeout}s)"

    while [ $elapsed -lt $timeout ]; do
        if ceph mgr dump -f json 2>/dev/null | jq -e '.available == true' >/dev/null 2>&1; then
            success "Active mgr available"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    error "No active mgr after ${timeout}s"
    return 1
}

# Stable node identity for mon/mgr naming. Recorded by bootstrap.sh on
# first bootstrap so a recreated container (fresh random hostname) keeps
# addressing the same daemon data on persistent volumes.
ceph_node_name() {
    if [ -f /etc/ceph/node_name ]; then
        cat /etc/ceph/node_name
    else
        hostname -s
    fi
}

# Check if already configured (generic marker file approach)
# Usage: check_done <marker_file> <description>
check_done() {
    local marker=$1
    local description=$2

    if [ -f "$marker" ]; then
        log "$description already configured (marker: $marker)"
        return 0
    fi
    return 1
}

# Mark task as done
# Usage: mark_done <marker_file> <description>
mark_done() {
    local marker=$1
    local description=$2

    mkdir -p "$(dirname "$marker")"
    touch "$marker"
    success "$description configured (marker: $marker)"
}
