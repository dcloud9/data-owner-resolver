# Production Kubernetes Deployment Guide

Deploy the data-owner-resolver in production Kubernetes clusters with **hostPath volume access** for resolving directory ownership.

## Architecture

The resolver runs **both stages inside a single pod**:

```
┌──────────────────────────────────────────────┐
│  Kubernetes Pod (with hostPath volume)       │
│                                              │
│  resolve-in-pod.sh (entrypoint)              │
│    │                                         │
│    ├─► Stage 1: scan-uids.sh                 │
│    │   └─ Scans /mnt/data (hostPath)         │
│    │   └─ Extracts real host UIDs            │
│    │   └─ Outputs JSON: {"path": uid}        │
│    │                                         │
│    └─► Stage 2: resolver                     │
│        └─ Reads JSON from Stage 1            │
│        └─ Queries LDAP for emails            │
│        └─ Outputs {"path": {"uid": "email"}} │
└──────────────────────────────────────────────┘
```

**Key Feature**: hostPath volume allows the pod to see **real host filesystem UIDs**, bypassing container UID mapping issues.

## Prerequisites

1. **Kubernetes cluster** (1.19+)
2. **LDAP server** accessible from cluster
3. **Container registry** access
4. **hostPath** access to data filesystem (typically on storage nodes)

## Setup Steps

### 1. Build and Push Container Image

```bash
# Build multi-stage image
podman build -t your-registry.com/data-owner-resolver:latest .

# Push to registry
podman push your-registry.com/data-owner-resolver:latest

# Or with Docker
docker build -t your-registry.com/data-owner-resolver:latest .
docker push your-registry.com/data-owner-resolver:latest
```

### 2. Configure LDAP Settings

Create/edit `k8s/configmap.yaml`:

```yaml
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
type: Opaque
stringData:
  LDAP_BIND_PASS: "your-secure-password-here"
```

Deploy:

```bash
kubectl apply -f k8s/configmap.yaml
```

### 3. Update Job Manifest

Edit `k8s/job.yaml` to match your environment:

**Update image**:
```yaml
containers:
- name: resolver
  image: your-registry.com/data-owner-resolver:latest  # YOUR IMAGE
```

**Update directories to scan**:
```yaml
args:
  - "/mnt/data/project-alpha"      # YOUR PATHS
  - "/mnt/data/project-beta"
  - "/mnt/data/shared-datasets"
```

**Update hostPath volume**:
```yaml
volumes:
- name: data
  hostPath:
    path: /mnt/data  # YOUR DATA PATH
    type: Directory
```

### 4. Deploy and Run

**Option A: One-time Job** (triggered manually or by external scripts):

```bash
# Create job
kubectl create -f k8s/job.yaml

# Watch progress
kubectl get jobs -w

# Get results
kubectl logs job/data-owner-resolver

# Cleanup
kubectl delete job data-owner-resolver
```

**Option B: Scheduled CronJob** (automatic periodic scans):

```bash
# Deploy CronJob
kubectl apply -f k8s/cronjob.yaml

# View schedule
kubectl get cronjobs

# View completed runs
kubectl get jobs -l type=scheduled --sort-by=.metadata.creationTimestamp
```

## Usage Patterns

### Pattern 1: Triggered by External Scripts

External automation can trigger scans on-demand:

```bash
#!/bin/bash
# External script: trigger-ownership-scan.sh

# Generate unique job name
JOB_NAME="data-owner-resolver-$(date +%s)"

# Create job from template (replace name for uniqueness)
kubectl create job $JOB_NAME \
  --from=cronjob/data-owner-resolver-scheduled

# Wait for completion (max 5 minutes)
kubectl wait --for=condition=complete --timeout=300s job/$JOB_NAME

# Retrieve results
RESULTS=$(kubectl logs job/$JOB_NAME)
echo "$RESULTS"

# Optionally parse and process
echo "$RESULTS" | jq '."/mnt/data/project-alpha"'

# Cleanup
kubectl delete job $JOB_NAME
```

### Pattern 2: REST API Wrapper

Create a simple API service that triggers Jobs:

```python
# api-server.py
from flask import Flask, request, jsonify
from kubernetes import client, config
import json

app = Flask(__name__)
config.load_incluster_config()

@app.route('/scan', methods=['POST'])
def trigger_scan():
    """
    POST /scan
    Body: {"paths": ["/mnt/data/project1", "/mnt/data/project2"]}
    """
    paths = request.json.get('paths', [])

    # Create Job
    batch_api = client.BatchV1Api()
    job = create_resolver_job(paths)
    batch_api.create_namespaced_job(namespace="default", body=job)

    # Wait and get results
    results = wait_for_job_and_get_logs(job.metadata.name)

    return jsonify(json.loads(results))

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
```

### Pattern 3: Kubernetes CronJob

Automatic daily scans at 2 AM:

```bash
kubectl apply -f k8s/cronjob.yaml
```

Schedule can be customized in the manifest:
```yaml
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM
  # schedule: "0 */6 * * *"  # Every 6 hours
  # schedule: "0 0 * * 0"  # Weekly on Sunday
```

## Security Considerations

### 1. hostPath Volumes

**Risk**: Direct access to host filesystem

**Mitigations**:
- Use read-only mounts: `readOnly: true`
- Restrict to specific nodes with nodeSelector
- Apply Pod Security Standards/Policies
- Audit access with PodSecurityPolicy

```yaml
# Pin to storage nodes only
nodeSelector:
  node-role: storage
  data-access: allowed
```

### 2. Running as Root

Required to see host UIDs correctly.

**Alternatives**:
- Use specific UID that matches data ownership
- Use `privileged: true` if UID 0 doesn't work
- Consider running on dedicated nodes

```yaml
securityContext:
  runAsUser: 0
  # Or specific UID:
  # runAsUser: 30000
  # runAsGroup: 30000
```

### 3. LDAP Credentials

**Best Practices**:
- Use Kubernetes Secrets (not ConfigMaps)
- Integrate with external secret management:
  - HashiCorp Vault
  - AWS Secrets Manager
  - Azure Key Vault
  - Google Secret Manager

**Example with External Secrets Operator**:
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: ldap-credentials
spec:
  secretStoreRef:
    name: vault-backend
  target:
    name: data-owner-resolver-secret
  data:
  - secretKey: LDAP_BIND_PASS
    remoteRef:
      key: ldap/readonly-account
      property: password
```

### 4. Network Policies

Restrict pod network access:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: resolver-policy
spec:
  podSelector:
    matchLabels:
      app: data-owner-resolver
  policyTypes:
  - Egress
  egress:
  # Allow DNS
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
    ports:
    - protocol: UDP
      port: 53
  # Allow LDAP
  - to:
    - podSelector:
        matchLabels:
          app: ldap
    ports:
    - protocol: TCP
      port: 389
```

## Monitoring and Observability

### 1. Prometheus Metrics

Add metrics endpoint to resolver:

```go
// Future enhancement: Add Prometheus metrics
import "github.com/prometheus/client_golang/prometheus"

var (
    directoriesScanned = prometheus.NewCounter(...)
    ldapQueriesTotal = prometheus.NewCounter(...)
    ldapQueryDuration = prometheus.NewHistogram(...)
)
```

### 2. Logging

Logs go to stdout/stderr and are collected by cluster logging:

```bash
# View live logs
kubectl logs -f job/data-owner-resolver

# View logs from specific time
kubectl logs --since=1h job/data-owner-resolver

# Export logs to file
kubectl logs job/data-owner-resolver > scan-results.json
```

### 3. Alerts

Example Prometheus alert:

```yaml
groups:
- name: resolver
  rules:
  - alert: ResolverJobFailed
    expr: kube_job_failed{job="data-owner-resolver"} > 0
    for: 5m
    annotations:
      summary: "Data owner resolver job failed"
```

## Troubleshooting

### Issue: Permission Denied on Host Filesystem

**Symptoms**:
```
Error: failed to stat /mnt/data/project1: permission denied
```

**Solutions**:
1. Check hostPath is mounted correctly
2. Verify `runAsUser: 0` or use privileged mode
3. Check node-level permissions
4. Verify Pod Security Policy allows hostPath

```bash
# Debug: Check what user container runs as
kubectl exec -it <pod> -- id

# Debug: Check mount point
kubectl exec -it <pod> -- ls -la /mnt/data
```

### Issue: LDAP Connection Failed

**Symptoms**:
```
ldap dial after 5 retries: dial tcp: lookup ldap.example.com: no such host
```

**Solutions**:
1. Verify LDAP_URL is correct and accessible
2. Check DNS resolution from pod
3. Verify network policies allow egress
4. Test LDAP connectivity:

```bash
kubectl run -it --rm debug --image=ubuntu:22.04 --restart=Never -- bash
apt update && apt install -y ldap-utils
ldapsearch -x -H ldap://your-ldap-server:389 -b "dc=example,dc=com"
```

### Issue: UIDs Still Show as 65534

**Symptoms**:
```json
{
  "/mnt/data/project1": {
    "65534": ""
  }
}
```

**Causes**:
- hostPath not mounted correctly
- Pod running on wrong node
- UID mapping still occurring

**Solutions**:
1. Verify hostPath volume:
```bash
kubectl describe pod <pod-name> | grep -A 5 Volumes
```

2. Check if on correct node:
```bash
kubectl get pod <pod-name> -o wide
```

3. Try privileged mode:
```yaml
securityContext:
  privileged: true
```

### Issue: Job Never Completes

**Symptoms**: Job stuck in "Running" state

**Debug**:
```bash
# Check pod status
kubectl describe pod <pod-name>

# Check events
kubectl get events --sort-by=.metadata.creationTimestamp

# Check logs
kubectl logs -f <pod-name>
```

## Performance Optimization

### Large Filesystems

For scanning millions of files:

1. **Increase resources**:
```yaml
resources:
  requests:
    memory: "1Gi"
    cpu: "1000m"
  limits:
    memory: "4Gi"
    cpu: "2000m"
```

2. **Partition scans**: Split into multiple jobs
```bash
# Job 1: Scan projects A-M
# Job 2: Scan projects N-Z
```

3. **Node affinity**: Run on nodes with fast storage access
```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: storage-tier
          operator: In
          values:
          - fast
```

## Integration Examples

### Airflow DAG

```python
from airflow import DAG
from airflow.providers.cncf.kubernetes.operators.kubernetes_pod import KubernetesPodOperator

dag = DAG('data_ownership_scan', schedule_interval='@daily')

scan_task = KubernetesPodOperator(
    task_id='scan_owners',
    name='data-owner-resolver',
    namespace='default',
    image='your-registry.com/data-owner-resolver:latest',
    cmds=['/usr/local/bin/resolve-in-pod.sh'],
    arguments=['/mnt/data/project1', '/mnt/data/project2'],
    env_from=[
        k8s.V1EnvFromSource(config_map_ref=k8s.V1ConfigMapEnvSource(name='data-owner-resolver-config')),
        k8s.V1EnvFromSource(secret_ref=k8s.V1SecretEnvSource(name='data-owner-resolver-secret'))
    ],
    volumes=[...],
    volume_mounts=[...],
    dag=dag
)
```

### GitLab CI/CD

```yaml
scan_data_ownership:
  stage: audit
  image: bitnami/kubectl:latest
  script:
    - kubectl create job data-scan-$CI_PIPELINE_ID --from=cronjob/data-owner-resolver
    - kubectl wait --for=condition=complete job/data-scan-$CI_PIPELINE_ID --timeout=300s
    - kubectl logs job/data-scan-$CI_PIPELINE_ID > ownership-report.json
  artifacts:
    paths:
      - ownership-report.json
  only:
    - schedules
```

## Production Checklist

Before deploying to production:

- [ ] Container image built and pushed to registry
- [ ] LDAP credentials stored in Kubernetes Secret
- [ ] ConfigMap updated with production LDAP settings
- [ ] hostPath volume path verified on target nodes
- [ ] Directories to scan specified in Job manifest
- [ ] nodeSelector configured to target correct nodes
- [ ] Resource requests/limits set appropriately
- [ ] Network policies configured
- [ ] Pod Security Policy allows hostPath and runAsUser: 0
- [ ] Monitoring and alerting configured
- [ ] Logs forwarded to central logging system
- [ ] Backup/retention policy for scan results defined
- [ ] Tested on non-production cluster first

## Next Steps

1. Review and customize `k8s/job.yaml` for your paths
2. Build and push container image
3. Deploy ConfigMap and Secret with your LDAP settings
4. Test with one-off Job
5. Deploy CronJob for scheduled scans
6. Integrate with your automation/orchestration systems
7. Set up monitoring and alerts
