# CI/CD Setup Guide

This document explains how to set up the GitHub Actions pipeline that automatically builds, tests, and publishes Ceph AIO container images.

## Overview

The CI/CD pipeline automatically:
1. Discovers the **3 most recent** Ceph major releases using `skopeo` (e.g., v19, v18, v17)
2. Builds container images for each major version (using shorthand tags that auto-track latest patches)
3. Runs comprehensive tests on each build (10 test scenarios covering all features)
4. Publishes successful builds to Quay.io with version tags and `latest` tag

## Prerequisites

### 1. Quay.io Account and Repository

You need a Quay.io account with a repository for the images:

1. Go to [quay.io](https://quay.io) and create an account
2. Create a new repository named `ceph-aio`
3. Set repository visibility (public recommended for easy access)

### 2. GitHub Repository Setup

Ensure your repository has:
- The workflow file at `.github/workflows/build-and-publish.yml`
- The test suite script at `test-suite.sh`
- All Ceph AIO source files (Containerfile, scripts/, etc.)

## GitHub Secrets Configuration

The workflow requires two secrets to be configured in your GitHub repository:

### Setting up Secrets

1. Go to your GitHub repository
2. Navigate to **Settings** → **Secrets and variables** → **Actions**
3. Click **New repository secret**
4. Add the following secrets:

#### `QUAY_USERNAME`
- **Description**: Your Quay.io username
- **Value**: Your Quay.io username (e.g., `benjamin_holmes`)

#### `QUAY_PASSWORD`
- **Description**: Quay.io access token or password
- **Value**:
  - **Recommended**: Generate a robot account token in Quay.io:
    1. Go to your Quay.io repository
    2. Navigate to **Settings** → **Robot Accounts**
    3. Create a new robot account with write permissions
    4. Copy the generated token
  - **Alternative**: Use your Quay.io password (less secure)

## Workflow Triggers

The pipeline runs automatically on:

### 1. Weekly Schedule
```yaml
schedule:
  - cron: '0 0 * * 1'  # Every Monday at 00:00 UTC
```
This catches new Ceph releases automatically.

### 2. Push to Main Branch
Triggers when any of these files change:
- `Containerfile`
- `scripts/**`
- `bootstrap.sh`
- `entrypoint.sh`
- `supervisord.conf`
- `.github/workflows/build-and-publish.yml`

### 3. Pull Requests
Runs builds and tests (but doesn't publish) on PRs to main branch.

### 4. Manual Trigger
You can manually trigger builds with custom versions:

1. Go to **Actions** tab in GitHub
2. Select **Build and Publish Ceph AIO** workflow
3. Click **Run workflow**
4. Optionally specify custom versions (e.g., `v19,v18,v17` or `v19.2.3,v18.2.7` for specific patches)

## Workflow Jobs

### Job 1: Discover Versions
Automatically discovers the latest stable Ceph releases using `skopeo`:

**Discovery Process:**
1. Uses `skopeo list-tags` to fetch all available Ceph container tags from Quay.io
2. Filters for shorthand major version tags (format: `vX` - e.g., `v19`, `v18`)
3. Selects the **3 most recent major versions**
4. These shorthand tags automatically track the latest patch release

**Why 3 versions?**
- Covers unreleased/pre-release versions (e.g., v20 before public release)
- Ensures we always have 2-3 publicly stable versions available
- Matches Ceph's typical support window

**Why shorthand tags?**
- Tags like `v19`, `v18` automatically point to the latest patch (e.g., v19.2.3)
- Simplifies maintenance - no need to track individual patch releases
- Users get automatic updates to latest patches

**Example:**
```bash
# All tags from Quay.io
skopeo list-tags docker://quay.io/ceph/ceph

# Filter for major version tags: v20, v19, v18, v17, ...
# Take 3 most recent: v19, v18, v17
# (Note: v20 may exist but not be publicly released yet)
```

**Discovery Flow:**
```
┌──────────────────────────────────────┐
│  skopeo list-tags                    │
│  docker://quay.io/ceph/ceph          │
└────────────┬─────────────────────────┘
             │ Get all tags
             ▼
┌──────────────────────────────────────┐
│  Filter major version tags           │
│  v20, v19, v18, v17, v16, etc.       │
└────────────┬─────────────────────────┘
             │ Sort and take 3 recent
             ▼
┌──────────────────────────────────────┐
│  3 most recent major versions        │
│  Result: v19, v18, v17               │
└────────────┬─────────────────────────┘
             │
             ▼
    Build Matrix: [v19, v18, v17]
    (Each tag tracks latest patch automatically)
```

This approach is **fully automatic** and **simple**:
- No semantic version parsing required
- Uses Quay.io's maintained shorthand tags
- Automatically gets latest patches without rebuilding
- When Ceph releases a new major version, the pipeline automatically detects and builds it

### Job 2: Build and Test
For each discovered version:
- Builds the Ceph AIO container image
- Runs comprehensive test suite covering:
  - Single OSD configuration
  - Multiple OSD configurations (2 and 3 OSDs)
  - Dashboard accessibility
  - RGW (S3/Swift) functionality
  - RBD block storage
  - Custom credentials
  - Replication testing
  - Security configuration
  - Idempotency
- Saves successful builds as artifacts
- Collects logs on failure for debugging

### Job 3: Publish
Only runs on successful builds from main branch or scheduled runs:
- Loads tested image from artifacts
- Authenticates with Quay.io using robot account credentials
- Tags and pushes images with two tag formats:
  - **Rolling tag**: Major version only (e.g., `v19`) - always points to latest build
  - **Immutable tag**: Major version + build date (e.g., `v19-20251003`) - permanent reference

### Job 4: Summary
Generates a workflow summary showing:
- Versions built
- Test results
- Publication status

## Image Tags

Published images use a dual tagging strategy:

| Tag Pattern | Example | Description | When to Use |
|-------------|---------|-------------|-------------|
| `vX` | `v19`, `v18`, `v17` | Rolling tag - always latest build for this major version | Development, testing, general use |
| `vX-YYYYMMDD` | `v19-20251003` | Immutable tag - specific build date | Production, reproducible environments |

**Tag Behavior:**
- **Rolling tags** (`v19`, `v18`, etc.) get updated with each new build on that version
- **Dated tags** (`v19-20251003`) never change - permanent reference to a specific build
- Build date format matches Ceph's convention: `YYYYMMDD`

**Example Scenario:**
```bash
# First build on 2025-10-03
v19           → points to build from 2025-10-03
v19-20251003  → permanent reference to this build

# New build on 2025-10-15
v19           → now points to build from 2025-10-15
v19-20251003  → still points to original build (immutable)
v19-20251015  → new permanent reference
```

## Usage Examples

### Pull Latest Build (Rolling Tag)
```bash
# Latest v19.x build - tag updates with each new build
podman pull quay.io/benjamin_holmes/ceph-aio:v19

# Latest v18.x build
podman pull quay.io/benjamin_holmes/ceph-aio:v18
```

### Pull Specific Build (Immutable Tag)
```bash
# Exact build from October 3rd, 2025 - never changes
podman pull quay.io/benjamin_holmes/ceph-aio:v19-20251003

# Exact build from September 15th, 2025
podman pull quay.io/benjamin_holmes/ceph-aio:v18-20250915
```

### Run Container
```bash
# Using rolling tag (development)
podman run -d --name ceph \
  -p 8443:8443 -p 8000:8000 \
  -e OSD_COUNT=3 \
  quay.io/benjamin_holmes/ceph-aio:v19

# Using immutable tag (production)
podman run -d --name ceph \
  -p 8443:8443 -p 8000:8000 \
  -e OSD_COUNT=3 \
  quay.io/benjamin_holmes/ceph-aio:v19-20251003
```

## Test Suite

The test suite (`test-suite.sh`) validates:

1. **Single OSD Configuration**
   - Verifies pool size = 1
   - Checks warnings are silenced
   - Validates HEALTH_OK status

2. **Multiple OSD Configurations**
   - Tests 2 OSD setup (size=2, min_size=1)
   - Tests 3 OSD setup (size=3, min_size=2)
   - Verifies all OSDs are up and in

3. **Dashboard Accessibility**
   - Checks dashboard module is enabled
   - Verifies dashboard URL is configured
   - Tests custom credentials

4. **RGW Functionality**
   - Verifies RGW daemon is running
   - Checks realm configuration
   - Tests user creation

5. **RBD Pool**
   - Verifies RBD pool exists
   - Tests image creation and listing

6. **Replication**
   - Tests object writes with multiple OSDs
   - Verifies object distribution
   - Validates data integrity

7. **Security**
   - Checks AUTH_INSECURE_GLOBAL_ID_RECLAIM is disabled
   - Validates security best practices

8. **Idempotency**
   - Tests container restart
   - Verifies cluster FSID persists

## Monitoring and Debugging

### View Workflow Runs
1. Go to **Actions** tab in your GitHub repository
2. Select a workflow run to view details
3. Expand job steps to see detailed logs

### Test Failures
When tests fail, the workflow automatically collects:
- Container logs
- Supervisor logs
- Ceph cluster status

These are displayed in the job logs under "Collect logs on failure".

### Build Failures
Check the "Build image" step logs for:
- Containerfile syntax errors
- Missing dependencies
- Build argument issues

### Publishing Failures
Common issues:
- Invalid Quay.io credentials (check secrets)
- Repository permissions (ensure robot account has write access)
- Network issues (temporary, retry usually works)

## Local Testing

Test the workflow locally before pushing:

### Build Image
```bash
podman build -t ceph-aio:latest -f Containerfile .
```

### Run Test Suite
```bash
chmod +x test-suite.sh
./test-suite.sh
```

### Test Specific Version
```bash
podman build \
  --build-arg CEPH_VERSION=v19.2.3 \
  -t ceph-aio:v19.2.3 \
  -f Containerfile .

# Update test-suite.sh to use v19.2.3 tag
./test-suite.sh
```

## Maintenance

### Version Discovery

**No manual maintenance required!** The workflow automatically:

1. **Detects new major releases**: When Ceph publishes a new major version to Quay.io (e.g., v20), the pipeline automatically discovers and builds it on the next run
2. **Maintains 3 most recent versions**: Always builds the 3 most recent major versions, providing coverage for current and previous stable releases
3. **Auto-tracks patches**: Uses shorthand tags (`v19`, `v18`) that automatically resolve to the latest patch without requiring rebuilds

### Manual Override

If you need to build specific versions:

**Via GitHub Actions UI:**
1. Go to **Actions** → **Build and Publish Ceph AIO** → **Run workflow**
2. Enter versions in the input field:
   - Shorthand tags: `v19,v18,v17` (recommended - auto-tracks patches)
   - Specific patches: `v19.2.3,v18.2.7` (locks to exact versions)

### How It Works

The discovery is based entirely on what's available in the container registry:
- Uses `skopeo` to query Quay.io directly (no API rate limits, no HTML parsing)
- Automatically adapts to new releases as they're published
- Simple and reliable - works directly with the source of truth (the registry)

### Updating Test Suite

To add new tests:

1. Add test function to `test-suite.sh`:
   ```bash
   test_my_feature() {
       # Test implementation
       return 0  # Success
   }
   ```

2. Call test in main():
   ```bash
   run_test "My Feature Test" test_my_feature
   ```

## Cost Considerations

### GitHub Actions
- Free for public repositories (2000 minutes/month for private repos)
- Each version build takes approximately 30-40 minutes
- 3 versions × 40 minutes = ~120 minutes per run
- Weekly schedule + occasional pushes should stay well within free tier
- Estimated monthly usage: ~500-600 minutes (25-30% of free tier)

### Quay.io
- Free for public repositories
- Only 4 tags total: `v19`, `v18`, `v17`, `latest`
- Minimal storage footprint (~2-3GB per version × 3 = 6-9GB total)
- Well within free tier limits

## Security Best Practices

1. **Use Robot Accounts**: Create dedicated robot accounts in Quay.io instead of using personal credentials
2. **Limit Permissions**: Grant only write permissions to the specific repository
3. **Rotate Secrets**: Periodically rotate Quay.io tokens
4. **Review Logs**: Regularly check workflow logs for security issues
5. **Pin Actions**: Consider pinning GitHub Actions to specific commits for reproducibility

## Troubleshooting

### "No versions discovered"
- Check Quay.io API is accessible
- Verify tag naming patterns match Ceph's versioning
- Ensure `jq` is available in runner

### "Image push failed: unauthorized"
- Verify `QUAY_USERNAME` secret is correct
- Check `QUAY_PASSWORD` secret is valid
- Ensure robot account has write permissions
- Verify repository name matches `benjamin_holmes/ceph-aio`

### "Tests timeout"
- Increase timeout in workflow (currently 30 minutes)
- Check if cluster takes longer to start with new Ceph version
- Review container logs for startup issues

### "Artifact upload failed"
- Check artifact size (GitHub has 10GB limit)
- Compressed images should be <2GB each
- Verify sufficient storage quota

## Quick Reference

### Current Build Configuration
- **Versions built**: 3 most recent major versions (currently v19, v18, v17)
- **Discovery method**: `skopeo list-tags` filtering for `vX` tags
- **Base images**: `quay.io/ceph/ceph:v19`, `quay.io/ceph/ceph:v18`, `quay.io/ceph/ceph:v17`
- **Published tags**: `v19`, `v18`, `v17`, `latest`
- **Test suite**: 10 comprehensive tests per version
- **Build frequency**: Weekly + on code changes
- **Estimated runtime**: ~120 minutes per full run

### Tag Behavior
- `v19` → Always latest v19.x.x patch (auto-updated by Quay.io)
- `v18` → Always latest v18.x.x patch (auto-updated by Quay.io)
- `v17` → Always latest v17.x.x patch (auto-updated by Quay.io)
- `latest` → Points to highest major version (currently v19)

### When New Versions Release
**Patch releases** (e.g., v19.2.3 → v19.2.4):
- Quay.io automatically updates the `v19` tag
- Your images inherit this without rebuilding
- Users pulling `v19` get the latest patch immediately

**Major releases** (e.g., v20 published):
- Next weekly run automatically detects v20
- Builds v20, v19, v18 (drops v17)
- Updates `latest` to point to v20

## References

- [Ceph Releases](https://docs.ceph.com/en/latest/releases/)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Quay.io Documentation](https://docs.quay.io/)
- [Skopeo Documentation](https://github.com/containers/skopeo)
- [Docker Build Documentation](https://docs.docker.com/engine/reference/commandline/build/)
