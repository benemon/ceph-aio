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
wait_for_cluster() {
    wait_for_command 30 ceph mon stat
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
