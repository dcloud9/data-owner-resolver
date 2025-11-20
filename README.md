# Data Owner Resolver

A lightweight bash-based tool that resolves data ownership by scanning filesystems and looking up owner email addresses from LDAP.

## Overview

This tool maps filesystem directory ownership (UIDs) to user email addresses via LDAP queries. It's designed for:
- Production filesystems with arbitrary UIDs (not matching container users)
- Kubernetes deployments with hostPath volumes
- Integration with external automation/orchestration systems

## Features

- ✅ Scans directories and extracts UIDs from filesystem metadata
- ✅ Queries LDAP server to resolve UIDs to email addresses
- ✅ Single bash script - no complex dependencies
- ✅ Works in Kubernetes pods with hostPath volumes
- ✅ Can be triggered by external scripts and automation
- ✅ Returns JSON output mapping directories to owner information

## Architecture

### Local Testing (Two-Stage Approach)

For testing on Amazon Linux 2023 with rootless Podman:

```
┌─────────────────────────────────────────────┐
│  Host (Stage 1)                             │
│  scan-uids.sh → Scans dirs, outputs JSON    │
└──────────────────┬──────────────────────────┘
                   │ JSON: {"path": uid, ...}
                   ▼
┌─────────────────────────────────────────────┐
│  Container (Stage 2)                        │
│  Queries LDAP, outputs results              │
└─────────────────────────────────────────────┘
```

**Why two stages?** Rootless Podman has UID mapping limitations that prevent containers from seeing real host UIDs.

### Kubernetes Production (Single Script)

For Kubernetes deployments with hostPath volumes:

```
┌─────────────────────────────────────────────┐
│  Kubernetes Pod                             │
│                                             │
│  resolve-simple.sh (all-in-one)             │
│  ├─ Scans /mnt/data (hostPath volume)       │
│  ├─ Sees real host UIDs (no mapping!)       │
│  ├─ Queries LDAP                            │
│  └─ Outputs JSON results                    │
└─────────────────────────────────────────────┘
```

**Why single script?** Kubernetes hostPath volumes preserve real host UIDs without container UID mapping issues.

## Quick Start

### Local Testing on Amazon Linux 2023

1. **Start services**:
   ```bash
   ./run-containers.sh --keep-running
   ```

2. **Run resolver** (two-stage approach):
   ```bash
   ./resolve-owners.sh testdata/alice-data testdata/bob-data testdata/charlie-data
   ```

3. **Expected output**:
   ```json
   {
     "testdata/alice-data": {
       "uid": 30001,
       "email": "alice.johnson@example.com"
     },
     "testdata/bob-data": {
       "uid": 30002,
       "email": "bob.smith@example.com"
     },
     "testdata/charlie-data": {
       "uid": 30003,
       "email": "charlie.brown@example.com"
     }
   }
   ```

### Kubernetes Deployment

#### Quick Start - Local Testing with k3d (hostPath)

Test the resolver in k3d with **production-like hostPath** configuration:

```bash
cd k8s
./deploy.sh
```

This creates test data on your host with real UIDs, then deploys to k3d with hostPath mounts - identical to production! View results:

```bash
kubectl logs -n data-resolver job/data-owner-resolver -f
```

#### Production Deployment

For production use with real data and external LDAP:

1. **Configure LDAP**:
   ```bash
   # Edit k8s/configmap.yaml with your LDAP server details
   kubectl apply -f k8s/configmap.yaml
   ```

2. **Build and push image**:
   ```bash
   docker build -t your-registry.com/data-owner-resolver:latest .
   docker push your-registry.com/data-owner-resolver:latest
   ```

3. **Deploy job**:
   ```bash
   # Edit k8s/job.yaml with your image and data paths
   kubectl apply -f k8s/job.yaml
   kubectl logs -f job/data-owner-resolver
   ```

4. **Or schedule regular scans**:
   ```bash
   kubectl apply -f k8s/cronjob.yaml
   ```

See **[k8s/README.md](k8s/README.md)** for complete deployment guide.

## Prerequisites

### Local Testing
- **Podman/Docker**: Container runtime
- **Bash**: Shell environment
- **LDAP test server**: Provided via containers

### Kubernetes Production
- **Kubernetes cluster** (1.19+)
- **LDAP server**: Accessible from cluster
- **Container registry**: To store the image
- **hostPath access**: Pods need access to data filesystem

## Usage

### Local Testing

```bash
# Start LDAP and build resolver image
./run-containers.sh --keep-running

# Scan directories and resolve owners
./resolve-owners.sh /path/to/dir1 /path/to/dir2

# Stop services
./stop-containers.sh
```

### Kubernetes

**One-time Job** (triggered manually or by automation):
```bash
kubectl create -f k8s/job.yaml
kubectl logs job/data-owner-resolver
```

**Scheduled CronJob** (periodic scans):
```bash
kubectl apply -f k8s/cronjob.yaml
```

**Triggered by External Scripts**:
```bash
# Using provided helper script
./k8s/trigger-scan.sh /mnt/data/project1 /mnt/data/project2

# Or with kubectl directly
kubectl create job scan-$(date +%s) --from=cronjob/data-owner-resolver
```

## Configuration

### LDAP Connection

**Local Testing** (via environment variables):
```bash
LDAP_URL="ldap://localhost:33389" \
LDAP_BIND_DN="cn=admin,dc=example,dc=com" \
LDAP_BIND_PASS="admin" \
LDAP_BASE_DN="dc=example,dc=com" \
./resolve-owners.sh testdata/*
```

**Kubernetes** (via ConfigMap/Secret):
```yaml
# k8s/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: data-owner-resolver-config
data:
  LDAP_URL: "ldap://ldap.yourcompany.com:389"
  LDAP_BIND_DN: "cn=readonly,dc=yourcompany,dc=com"
  LDAP_BASE_DN: "dc=yourcompany,dc=com"
---
apiVersion: v1
kind: Secret
metadata:
  name: data-owner-resolver-secret
stringData:
  LDAP_BIND_PASS: "your-password"
```

### Directories to Scan

**Local Testing**:
```bash
./resolve-owners.sh /mnt/data/project1 /mnt/data/project2 /mnt/data/project3
```

**Kubernetes** (edit `k8s/job.yaml`):
```yaml
args:
  - "/mnt/data/project1"
  - "/mnt/data/project2"
  - "/mnt/data/project3"
```

## Project Structure

```
data-owner-resolver/
├── resolve-simple.sh          # Single script for Kubernetes
├── resolve-owners.sh          # Two-stage wrapper for local testing
├── scan-uids.sh               # Host-side UID scanner
├── Dockerfile                 # Container image (simplified)
├── run-containers.sh          # Start LDAP and build image
├── stop-containers.sh         # Stop services
├── k8s/                       # Kubernetes manifests
│   ├── configmap.yaml         # LDAP configuration
│   ├── job.yaml               # On-demand Job
│   ├── cronjob.yaml           # Scheduled CronJob
│   └── trigger-scan.sh        # External trigger script
├── testdata/                  # Test directories with UIDs
│   ├── alice-data/            # UID 30001
│   ├── bob-data/              # UID 30002
│   └── ...
└── ldap-seed/                 # LDAP test data
```

## How It Works

### Stage 1: UID Extraction
```bash
# Get UID of directory
uid=$(stat -c '%u' /path/to/directory)
# Output: 30001
```

### Stage 2: LDAP Resolution
```bash
# Query LDAP for email by uidNumber
ldapsearch -x -H ldap://server:389 \
  -b "dc=example,dc=com" \
  "(uidNumber=30001)" \
  mail
# Output: alice.johnson@example.com
```

### JSON Output
```json
{
  "/mnt/data/project1": {
    "uid": 30001,
    "email": "alice.johnson@example.com"
  },
  "/mnt/data/project2": {
    "uid": 30002,
    "email": "bob.smith@example.com"
  }
}
```

This standardized format makes it easy to parse with external scripts:
```bash
# Extract email for a specific path
cat results.json | jq '."/mnt/data/project1".email'
# Output: "alice.johnson@example.com"

# Extract UID
cat results.json | jq '."/mnt/data/project1".uid'
# Output: 30001

# List all emails
cat results.json | jq '.[] | .email'
```

## Troubleshooting

### Local Testing Issues

**Problem**: UIDs showing as 1-5 instead of 30001-30005

**Cause**: Rootless Podman UID mapping limitation

**Solution**: Use the two-stage approach (`resolve-owners.sh`) which scans on the host

---

**Problem**: "Cannot connect to LDAP server"

**Solution**:
```bash
# Check LDAP is running
podman ps | grep test-ldap

# Restart if needed
./stop-containers.sh
./run-containers.sh --keep-running
```

### Kubernetes Issues

**Problem**: Permission denied on hostPath

**Solution**: Ensure pod has `runAsUser: 0` in securityContext

---

**Problem**: UIDs showing as 65534

**Solution**: Verify hostPath is mounted correctly and pod is on the right node

See **[k8s/README.md](k8s/README.md)** for detailed troubleshooting.

## Integration Examples

### Shell Script
```bash
#!/bin/bash
# Trigger scan and save results
./k8s/trigger-scan.sh /mnt/data/project1 /mnt/data/project2 > results.json
```

### Python
```python
from kubernetes import client, config

def trigger_scan(directories):
    batch_api = client.BatchV1Api()
    job = create_resolver_job(directories)
    batch_api.create_namespaced_job("default", job)
    return get_job_results(job.metadata.name)
```

### Airflow
```python
KubernetesPodOperator(
    task_id='scan_ownership',
    image='registry.com/data-owner-resolver:latest',
    args=['/mnt/data/project1', '/mnt/data/project2'],
    ...
)
```

## Development

### Building Locally
```bash
# Build image
podman build -t data-owner-resolver:latest .

# Test locally
./resolve-owners.sh testdata/*
```

### Rebuilding After Changes
```bash
./run-containers.sh --rebuild --keep-running
```

## Testing

### Unit Testing
```bash
# Test with local LDAP server
./run-containers.sh --keep-running

# Run resolver on test data
./resolve-owners.sh testdata/alice-data testdata/bob-data

# Stop services
./stop-containers.sh
```

### Test Data

The `testdata/` directory contains test directories owned by different UIDs:
- `alice-data`: UID 30001 → alice.johnson@example.com
- `bob-data`: UID 30002 → bob.smith@example.com
- `charlie-data`: UID 30003 → charlie.brown@example.com
- `diana-data`: UID 30004 → diana.prince@example.com
- `shared-team`: UID 30005 → teamlead@example.com

## Security Considerations

1. **LDAP Credentials**: Store in Kubernetes Secrets, not ConfigMaps
2. **hostPath Volumes**: Use read-only mounts (`:ro` or `readOnly: true`)
3. **Pod Security**: Run on dedicated nodes with data access
4. **Network Policies**: Restrict egress to LDAP server only
5. **RBAC**: Use service accounts with minimal permissions

See **[k8s/README.md](k8s/README.md)** for detailed security and deployment guidance.

## License

See LICENSE file for details.

## Support

For issues or questions:
- Check the troubleshooting sections
- Review [k8s/README.md](k8s/README.md)
- File an issue in the project repository
