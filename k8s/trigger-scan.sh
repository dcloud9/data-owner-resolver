#!/usr/bin/env bash
# External script to trigger data ownership scans in Kubernetes
# Can be called by automation systems, CI/CD, or manually

set -e

# Configuration
NAMESPACE="${NAMESPACE:-default}"
JOB_TEMPLATE="data-owner-resolver"
TIMEOUT="${TIMEOUT:-300}"  # 5 minutes

# Parse arguments
if [ $# -lt 1 ]; then
    echo "Usage: $0 <directory> [directory2 ...]"
    echo ""
    echo "Triggers a Kubernetes Job to scan directories and resolve ownership."
    echo ""
    echo "Examples:"
    echo "  $0 /mnt/data/project1"
    echo "  $0 /mnt/data/project1 /mnt/data/project2"
    echo ""
    echo "Environment variables:"
    echo "  NAMESPACE - Kubernetes namespace (default: default)"
    echo "  TIMEOUT   - Job timeout in seconds (default: 300)"
    exit 1
fi

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl not found. Please install kubectl."
    exit 1
fi

# Generate unique job name
TIMESTAMP=$(date +%s)
JOB_NAME="data-owner-resolver-${TIMESTAMP}"

echo "=== Triggering Data Ownership Scan ==="
echo "Job name: $JOB_NAME"
echo "Namespace: $NAMESPACE"
echo "Directories: $@"
echo ""

# Create job YAML with custom directories
cat > /tmp/${JOB_NAME}.yaml <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: data-owner-resolver
    triggered-by: external-script
spec:
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app: data-owner-resolver
    spec:
      restartPolicy: OnFailure
      containers:
      - name: resolver
        image: data-owner-resolver:latest
        imagePullPolicy: IfNotPresent
        args:
EOF

# Add directories as arguments
for dir in "$@"; do
    echo "          - \"${dir}\"" >> /tmp/${JOB_NAME}.yaml
done

# Add rest of job spec
cat >> /tmp/${JOB_NAME}.yaml <<'EOF'
        env:
        - name: LDAP_URL
          valueFrom:
            configMapKeyRef:
              name: data-owner-resolver-config
              key: LDAP_URL
        - name: LDAP_BIND_DN
          valueFrom:
            configMapKeyRef:
              name: data-owner-resolver-config
              key: LDAP_BIND_DN
        - name: LDAP_BASE_DN
          valueFrom:
            configMapKeyRef:
              name: data-owner-resolver-config
              key: LDAP_BASE_DN
        - name: LDAP_BIND_PASS
          valueFrom:
            secretKeyRef:
              name: data-owner-resolver-secret
              key: LDAP_BIND_PASS
        volumeMounts:
        - name: data
          mountPath: /mnt/data
          readOnly: true
        securityContext:
          runAsUser: 0
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
      volumes:
      - name: data
        hostPath:
          path: /mnt/data
          type: Directory
EOF

echo "Creating Job..."
if ! kubectl create -f /tmp/${JOB_NAME}.yaml; then
    echo "Error: Failed to create Job"
    rm -f /tmp/${JOB_NAME}.yaml
    exit 1
fi

echo "✓ Job created successfully"
echo ""

# Wait for job to complete
echo "Waiting for Job to complete (timeout: ${TIMEOUT}s)..."
if kubectl wait --for=condition=complete --timeout=${TIMEOUT}s job/${JOB_NAME} -n ${NAMESPACE}; then
    echo "✓ Job completed successfully"
    echo ""
else
    echo "✗ Job failed or timed out"
    echo ""
    echo "Check job status:"
    echo "  kubectl describe job/${JOB_NAME} -n ${NAMESPACE}"
    echo "  kubectl logs job/${JOB_NAME} -n ${NAMESPACE}"
    rm -f /tmp/${JOB_NAME}.yaml
    exit 1
fi

# Get results
echo "=== Scan Results ==="
kubectl logs job/${JOB_NAME} -n ${NAMESPACE} 2>/dev/null | grep -v "===" | grep -v "Stage" || true

# Save results to file
RESULTS_FILE="scan-results-${TIMESTAMP}.json"
kubectl logs job/${JOB_NAME} -n ${NAMESPACE} 2>/dev/null | grep '^{' > "${RESULTS_FILE}" || true

if [ -s "${RESULTS_FILE}" ]; then
    echo ""
    echo "✓ Results saved to: ${RESULTS_FILE}"
else
    rm -f "${RESULTS_FILE}"
fi

# Cleanup
echo ""
echo "Cleaning up Job..."
kubectl delete job/${JOB_NAME} -n ${NAMESPACE} --wait=false
rm -f /tmp/${JOB_NAME}.yaml

echo "✓ Done"
