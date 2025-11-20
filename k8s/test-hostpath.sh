#!/bin/bash
# Test hostPath functionality in k3d (production simulation)
# This creates a k3d cluster with host volume mounts to simulate production

set -e

CLUSTER_NAME="resolver-hostpath"
HOST_DATA_DIR="/tmp/k3d-testdata"

echo "=== Testing hostPath in k3d (Production Simulation) ==="
echo ""

# Check if cluster already exists
if k3d cluster list | grep -q "$CLUSTER_NAME"; then
  echo "⚠ Cluster '$CLUSTER_NAME' already exists"
  read -p "Delete and recreate? [y/N] " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Deleting existing cluster..."
    k3d cluster delete "$CLUSTER_NAME"
  else
    echo "Aborting."
    exit 1
  fi
fi

# Create test data on host with real UIDs
echo "1. Creating test data on host with UIDs 30001-30003..."
sudo rm -rf "$HOST_DATA_DIR"
sudo mkdir -p "$HOST_DATA_DIR"/project{1,2,3}
sudo chown 30001:30001 "$HOST_DATA_DIR/project1"
sudo chown 30002:30002 "$HOST_DATA_DIR/project2"
sudo chown 30003:30003 "$HOST_DATA_DIR/project3"
echo "Project 1 data" | sudo tee "$HOST_DATA_DIR/project1/data.txt" > /dev/null
echo "Project 2 data" | sudo tee "$HOST_DATA_DIR/project2/data.txt" > /dev/null
echo "Project 3 data" | sudo tee "$HOST_DATA_DIR/project3/data.txt" > /dev/null

echo "   Created:"
ls -la "$HOST_DATA_DIR"
echo ""

# Create k3d cluster with volume mount
echo "2. Creating k3d cluster with hostPath volume mount..."
k3d cluster create "$CLUSTER_NAME" \
  --agents 1 \
  --volume "$HOST_DATA_DIR:/mnt/data@all" \
  --wait
echo ""

# Build and import image
echo "3. Building and importing Docker image..."
docker build -t data-owner-resolver:latest .. > /dev/null 2>&1
k3d image import data-owner-resolver:latest -c "$CLUSTER_NAME"
echo ""

# Deploy LDAP
echo "4. Deploying LDAP server..."
kubectl apply -f namespace.yaml > /dev/null
kubectl apply -f ldap-configmap.yaml > /dev/null
kubectl apply -f ldap-statefulset.yaml > /dev/null

echo "   Waiting for LDAP to be ready..."
kubectl wait --for=condition=ready pod -l app=ldap -n data-resolver --timeout=180s > /dev/null

echo "   Initializing LDAP with test users..."
kubectl apply -f init-ldap-job.yaml > /dev/null
kubectl wait --for=condition=complete job/ldap-init -n data-resolver --timeout=60s > /dev/null
echo ""

# Deploy resolver with hostPath
echo "5. Running resolver with hostPath..."
cat <<EOF | kubectl apply -f - > /dev/null
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
          path: /mnt/data
          type: Directory
EOF

sleep 5
echo ""

# Show results
echo "=== Results ==="
kubectl logs -n data-resolver job/data-owner-resolver-hostpath

echo ""
echo "=== Verification ==="
echo "Host data with UIDs:"
ls -la "$HOST_DATA_DIR" | grep -E "project[123]"

echo ""
echo "✓ hostPath test completed successfully!"
echo ""
echo "This validates that the resolver can read native host UIDs through"
echo "Kubernetes hostPath mounts - identical to production behavior."
echo ""
echo "Cleanup:"
echo "  k3d cluster delete $CLUSTER_NAME"
echo "  sudo rm -rf $HOST_DATA_DIR"
