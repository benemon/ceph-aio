# CI/CD Setup Guide

This document explains how to set up the GitHub Actions pipeline that automatically builds, tests, and publishes Ceph AIO container images.

## Overview

The CI/CD pipeline automatically:
1. Discovers the latest stable Ceph releases (Squid v19.x and Reef v18.x)
2. Builds container images for each version
3. Runs comprehensive tests on each build
4. Publishes successful builds to Quay.io with appropriate tags

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
4. Optionally specify custom versions (e.g., `v19.2.3,v18.2.7`)

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
- Authenticates with Quay.io
- Tags and pushes images with multiple tags:
  - Full version: `v19.2.3`
  - Major.minor: `v19.2`
  - Latest (for Squid only): `latest`

### Job 4: Summary
Generates a workflow summary showing:
- Versions built
- Test results
- Publication status

## Image Tags

Published images are tagged as follows:

| Tag Pattern | Example | Description |
|-------------|---------|-------------|
| `vX` | `v19`, `v18`, `v17` | Major version (tracks latest patch automatically) |
| `latest` | `latest` | Most recent stable release |

**Note:** The shorthand tags (`v19`, `v18`, etc.) automatically track the latest patch release. When Ceph releases v19.2.4, the `v19` tag automatically points to it without requiring a rebuild.

## Usage Examples

### Pull Latest Stable
```bash
podman pull quay.io/benjamin_holmes/ceph-aio:latest
```

### Pull Specific Major Version (auto-updates to latest patch)
```bash
# Always gets latest v19.x.x patch
podman pull quay.io/benjamin_holmes/ceph-aio:v19

# Always gets latest v18.x.x patch
podman pull quay.io/benjamin_holmes/ceph-aio:v18

# Always gets latest v17.x.x patch
podman pull quay.io/benjamin_holmes/ceph-aio:v17
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

1. **Detects new major releases**: When Ceph releases a new stable version (e.g., v20.x) and marks it as "Active" on their releases page, the pipeline will automatically discover and build it
2. **Stops building EOL versions**: When a version is no longer marked as "Active" in the Ceph documentation, the pipeline will automatically stop building it
3. **Tracks latest patches**: Always builds the latest patch release for each active major version

### Manual Override

If you need to build specific versions regardless of official status:

```bash
# Via GitHub Actions UI
Go to Actions → Build and Publish Ceph AIO → Run workflow
Enter versions: v19.2.3,v18.2.7,v17.2.9
```

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
- Each build takes approximately 30-40 minutes
- Weekly schedule + occasional manual runs should stay within free tier

### Quay.io
- Free for public repositories
- Storage scales with number of tags kept
- Consider retention policies to manage storage

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

## References

- [Ceph Releases](https://docs.ceph.com/en/latest/releases/)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Quay.io Documentation](https://docs.quay.io/)
- [Docker Build Documentation](https://docs.docker.com/engine/reference/commandline/build/)
