# Kubernetes Deployment for Data Owner Resolver

This directory contains Kubernetes manifests using **hostPath volumes** for both local testing (k3d) and production deployment. This approach is production-realistic and I/O efficient.

## Deployment Modes

### 1. Local Testing (k3d with hostPath)
Test in k3d with production-like hostPath configuration. Test data is created on your host with real UIDs.

**Files:**
- `deploy.sh` - Automated deployment script
- `job-hostpath.yaml` - Resolver job (uses embedded LDAP in `data-resolver` namespace)
- `namespace.yaml` - Creates `data-resolver` namespace
- `ldap-configmap.yaml` - LDAP server configuration
- `ldap-statefulset.yaml` - LDAP server deployment (Bitnami)
- `init-ldap-job.yaml` - Seeds LDAP with test users

**Storage**: Uses hostPath with k3d volume mount (`/tmp/data-resolver-test` on host → `/mnt/data` in k3d nodes)

**LDAP**: Embedded Bitnami LDAP in cluster (hardcoded in job-hostpath.yaml)

### 2. Production Deployment (hostPath + external LDAP)
For production use with **hostPath volumes** to access real filesystem data on Kubernetes nodes.

**Files:**
- `configmap.yaml` - LDAP connection configuration (for external LDAP)
- `job.yaml` - One-time resolver job (reads LDAP config from ConfigMap/Secret)
- `cronjob.yaml` - Scheduled resolver job (reads LDAP config from ConfigMap/Secret)
- `trigger-scan.sh` - Helper script to trigger scans dynamically

**Storage**: Uses hostPath to access real node filesystems (e.g., `/mnt/data`) with native UIDs preserved.

**LDAP**: External LDAP server (configured via ConfigMap/Secret)

**Important - I/O Efficiency**: Always specify exact directories to scan in the `args:` section. This avoids scanning thousands of unnecessary directories. External scripts should pass only the specific paths that need ownership resolution.

### Key Differences: Local vs Production

| Aspect | Local Testing | Production |
|--------|--------------|------------|
| Job File | `job-hostpath.yaml` | `job.yaml` |
| Namespace | `data-resolver` | `default` (or your namespace) |
| LDAP | Embedded Bitnami (in cluster) | External LDAP server |
| LDAP Config | Hardcoded in job | ConfigMap + Secret |
| Storage | hostPath (k3d volume mount) | hostPath (real node filesystem) |
| TTL | 600s (10 min) | 3600s (1 hour) |
| Use Case | Pre-production validation | Production workloads |

## Prerequisites

- **k3d** (for local testing)
- **kubectl**
- **Docker** or **Podman**

## Quick Start - Local Testing with hostPath

Test the resolver in k3d with **production-like hostPath** configuration:

```bash
cd k8s
./deploy.sh
```

This script will:
1. Create test data on your **host** at `/tmp/data-resolver-test` with real UIDs (30001-30005)
2. Create k3d cluster with volume mount (host → k3d nodes)
3. Build and import the Docker image
4. Deploy LDAP server with test users
5. Run the resolver job with **hostPath**

## View Results

```bash
# Watch the resolver job
kubectl logs -n data-resolver job/data-owner-resolver -f

# Verify host data was created with correct UIDs
ls -la /tmp/data-resolver-test

# Check all resources
kubectl get all -n data-resolver
```

Expected output:
```json
{
  "/mnt/data/alice-data": {
    "30001": "alice.johnson@example.com"
  },
  "/mnt/data/bob-data": {
    "30002": "bob.smith@example.com"
  },
  ...
}
```

This validates that the resolver correctly reads **native host UIDs** through hostPath mounts - identical to production!

## Manual Local Deployment

If you prefer to deploy step-by-step instead of using deploy.sh:

```bash
# 1. Create test data on host with real UIDs
sudo rm -rf /tmp/data-resolver-test
sudo mkdir -p /tmp/data-resolver-test/{alice-data,bob-data,charlie-data,diana-data,shared-team}
echo "Alice's README" | sudo tee /tmp/data-resolver-test/alice-data/README.txt > /dev/null
echo "Bob's data" | sudo tee /tmp/data-resolver-test/bob-data/data.csv > /dev/null
echo "Charlie's analysis" | sudo tee /tmp/data-resolver-test/charlie-data/analysis.txt > /dev/null
echo "Diana's project" | sudo tee /tmp/data-resolver-test/diana-data/project.md > /dev/null
echo "Team notes" | sudo tee /tmp/data-resolver-test/shared-team/team-notes.txt > /dev/null
sudo chown -R 30001:30001 /tmp/data-resolver-test/alice-data
sudo chown -R 30002:30002 /tmp/data-resolver-test/bob-data
sudo chown -R 30003:30003 /tmp/data-resolver-test/charlie-data
sudo chown -R 30004:30004 /tmp/data-resolver-test/diana-data
sudo chown -R 30005:30005 /tmp/data-resolver-test/shared-team

# 2. Create k3d cluster with hostPath volume mount
k3d cluster create data-resolver --agents 1 --volume /tmp/data-resolver-test:/mnt/data@all --wait

# 3. Build and import image
docker build -t data-owner-resolver:latest ..
k3d image import data-owner-resolver:latest -c data-resolver

# 4. Create namespace
kubectl apply -f namespace.yaml

# 5. Deploy LDAP server
kubectl apply -f ldap-configmap.yaml
kubectl apply -f ldap-statefulset.yaml
kubectl wait --for=condition=ready pod -l app=ldap -n data-resolver --timeout=120s

# 6. Initialize LDAP with test users
kubectl apply -f init-ldap-job.yaml
kubectl wait --for=condition=complete job/ldap-init -n data-resolver --timeout=60s

# 7. Run resolver with hostPath
kubectl apply -f job-hostpath.yaml
kubectl logs -n data-resolver job/data-owner-resolver -f
```

## Re-running the Resolver

To run the resolver again:

```bash
kubectl delete job data-owner-resolver -n data-resolver
kubectl apply -f job-hostpath.yaml
kubectl logs -n data-resolver job/data-owner-resolver -f
```

## Troubleshooting

### Check LDAP is accessible

```bash
# Note: Bitnami LDAP uses port 1389 (not 389)
kubectl exec -n data-resolver ldap-0 -- ldapsearch -x -H ldap://localhost:1389 -b dc=example,dc=com -D 'cn=admin,dc=example,dc=com' -w admin
```

### Check test data permissions

```bash
# Verify test data was created on host with correct UIDs
ls -la /tmp/data-resolver-test
```

### Verify resolver can connect to LDAP

```bash
kubectl logs -n data-resolver job/data-owner-resolver
```

## Cleanup

```bash
# Delete the k3d cluster
k3d cluster delete data-resolver

# Remove host test data
sudo rm -rf /tmp/data-resolver-test
```

## Production Deployment

> **Note**: Both local testing (k3d) and production use **hostPath volumes**. The local `deploy.sh` script creates a production-realistic environment by mounting host directories into k3d nodes.

For production use with real filesystem data and external LDAP:

### 1. Configure LDAP Connection

Edit `configmap.yaml` with your LDAP server details:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: data-owner-resolver-config
  namespace: default  # or your namespace
data:
  LDAP_URL: "ldap://your-ldap-server.company.com:389"
  LDAP_BIND_DN: "cn=readonly,dc=company,dc=com"
  LDAP_BASE_DN: "dc=company,dc=com"
---
apiVersion: v1
kind: Secret
metadata:
  name: data-owner-resolver-secret
  namespace: default  # or your namespace
type: Opaque
stringData:
  LDAP_BIND_PASS: "your-secure-password"
```

Apply the configuration:
```bash
kubectl apply -f configmap.yaml
```

### 2. Update Job Paths

Edit `job.yaml` to specify the directories you want to scan:

```yaml
args:
  - "/mnt/data/project1"
  - "/mnt/data/project2"
  # Add more paths as needed
```

Ensure the `hostPath` matches your data location:
```yaml
volumes:
- name: data
  hostPath:
    path: /mnt/data  # Your actual data path
    type: Directory
```

### 3. Build and Push Image

```bash
# Build the image
docker build -t your-registry.com/data-owner-resolver:latest ..

# Push to your registry
docker push your-registry.com/data-owner-resolver:latest
```

Update the image reference in `job.yaml` and `cronjob.yaml`.

### 4. Run One-Time Job

```bash
kubectl apply -f job.yaml
kubectl logs -f job/data-owner-resolver
```

### 5. Or Schedule Regular Scans

```bash
# Deploy CronJob (runs daily at 2 AM by default)
kubectl apply -f cronjob.yaml

# View CronJob status
kubectl get cronjob data-owner-resolver-scheduled

# Manually trigger the CronJob
kubectl create job manual-scan-$(date +%s) --from=cronjob/data-owner-resolver-scheduled
```

### 6. Trigger from External Scripts (Recommended for Production)

Use the helper script to trigger scans programmatically with **specific directories only**:

```bash
# Scan only specific directories (I/O efficient)
./trigger-scan.sh /mnt/data/project1 /mnt/data/project2

# Your external script determines which directories need scanning
# Example: Scan directories modified in the last day
DIRS=$(find /mnt/data -maxdepth 1 -type d -mtime -1)
./trigger-scan.sh $DIRS

# Example: Scan directories from a list
./trigger-scan.sh $(cat directories-to-scan.txt)
```

**Key Benefits**:
- ✅ Only scans what you specify (I/O efficient)
- ✅ Suitable for thousands of directories
- ✅ External logic determines what needs scanning
- ✅ No wasted I/O on unchanged directories

Or integrate with your automation:

```python
# Python example
from kubernetes import client, config

config.load_kube_config()
batch_api = client.BatchV1Api()

# Create job from CronJob template
job = batch_api.create_namespaced_job(
    namespace="default",
    body={...}  # Job specification
)
```

## Testing hostPath in k3d (Production Simulation)

You can test the **production hostPath setup** in k3d to validate before deploying to real Kubernetes. This creates a realistic environment where the resolver reads UIDs directly from the host filesystem.

### Quick Start - Automated Script

Use the provided script to test hostPath:

```bash
cd k8s
chmod +x test-hostpath.sh
./test-hostpath.sh
```

This will:
1. Create a k3d cluster with host volume mount
2. Create test data on your host with real UIDs
3. Deploy LDAP server
4. Run the resolver with hostPath (production config)
5. Show results

### Manual Testing

If you prefer to test manually:

```bash
# 1. Create test data on YOUR HOST (not in containers)
# This simulates production data with real UIDs
sudo mkdir -p /tmp/k3d-testdata/project{1,2,3}
sudo chown 30001:30001 /tmp/k3d-testdata/project1
sudo chown 30002:30002 /tmp/k3d-testdata/project2
sudo chown 30003:30003 /tmp/k3d-testdata/project3
echo "Project 1 data" | sudo tee /tmp/k3d-testdata/project1/data.txt
echo "Project 2 data" | sudo tee /tmp/k3d-testdata/project2/data.txt
echo "Project 3 data" | sudo tee /tmp/k3d-testdata/project3/data.txt

# 2. Create k3d cluster with volume mount from host -> k3d nodes
k3d cluster create resolver-hostpath \
  --agents 1 \
  --volume /tmp/k3d-testdata:/mnt/data@all

# 3. Build and import image
docker build -t data-owner-resolver:latest ..
k3d image import data-owner-resolver:latest -c resolver-hostpath

# 4. Deploy LDAP
kubectl apply -f namespace.yaml
kubectl apply -f ldap-configmap.yaml
kubectl apply -f ldap-statefulset.yaml
kubectl wait --for=condition=ready pod -l app=ldap -n data-resolver --timeout=180s
kubectl apply -f init-ldap-job.yaml
kubectl wait --for=condition=complete job/ldap-init -n data-resolver --timeout=60s

# 5. Create a hostPath job (modified from job.yaml)
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: data-owner-resolver-hostpath
  namespace: data-resolver
spec:
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: resolver
        image: data-owner-resolver:latest
        imagePullPolicy: Never
        args:
          - "/mnt/data/project1"
          - "/mnt/data/project2"
          - "/mnt/data/project3"
        env:
        - name: LDAP_URL
          value: "ldap://ldap:1389"
        - name: LDAP_BIND_DN
          value: "cn=admin,dc=example,dc=com"
        - name: LDAP_BIND_PASS
          value: "admin"
        - name: LDAP_BASE_DN
          value: "dc=example,dc=com"
        volumeMounts:
        - name: data
          mountPath: /mnt/data
          readOnly: true
        securityContext:
          runAsUser: 0
      volumes:
      - name: data
        hostPath:
          path: /mnt/data  # This path exists in k3d nodes
          type: Directory
EOF

# 6. Check results
kubectl logs -n data-resolver job/data-owner-resolver-hostpath -f
```

### Verify hostPath is Working

Check that the UIDs from your **host** are preserved:

```bash
# Verify the host data was created with correct UIDs (30001, 30002, 30003)
ls -la /tmp/k3d-testdata
```

### Cleanup

```bash
k3d cluster delete resolver-hostpath
sudo rm -rf /tmp/k3d-testdata
```

This hostPath testing is **almost identical** to production and validates that the resolver correctly reads native filesystem UIDs through Kubernetes hostPath mounts.

### k3d vs kind for hostPath Testing

Both k3d and kind support hostPath testing:

**k3d** (Recommended):
- ✅ Simpler volume mount syntax: `--volume /host/path:/container/path@all`
- ✅ Lightweight (uses k3s)
- ✅ Faster startup
- ✅ Built-in load balancer

**kind**:
- ✅ Also supports volume mounts (via extraMounts in config)
- ✅ Uses full Kubernetes
- ✅ More similar to production Kubernetes

Either works fine for testing hostPath! We use k3d in this project for simplicity.

## Production Considerations

1. **Secrets Management**: Use Kubernetes Secrets for LDAP credentials
2. **Node Placement**: Use `nodeSelector` to run on nodes with data access
3. **Security Context**: Run as root (uid 0) to see real filesystem UIDs
4. **Resource Limits**: Adjust CPU/memory based on data size
5. **Network Policies**: Restrict egress to LDAP server only
6. **RBAC**: Use service accounts with minimal permissions
7. **Logging**: Integrate with cluster logging solution
8. **Monitoring**: Add alerts for job failures
9. **hostPath Volume**: Ensure the path exists on all target nodes and pods are scheduled correctly
