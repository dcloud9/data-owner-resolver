#!/bin/bash
# Deploy Data Owner Resolver to k3d with hostPath (production-like setup)
set -e

CLUSTER_NAME="data-resolver"
HOST_DATA_DIR="/tmp/data-resolver-test"

echo "=== Data Owner Resolver K8s Deployment (hostPath) ==="
echo ""

# Check if cluster exists
if k3d cluster list | grep -q "$CLUSTER_NAME"; then
  echo "⚠ Cluster '$CLUSTER_NAME' already exists"
  read -p "Delete and recreate? [y/N] " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Deleting existing cluster..."
    k3d cluster delete "$CLUSTER_NAME"
  else
    echo "Using existing cluster. Skipping cluster creation."
    SKIP_CLUSTER=true
  fi
fi

if [ "$SKIP_CLUSTER" != "true" ]; then
  # Create test data on host with real UIDs
  echo "1. Creating test data on host with real UIDs..."
  sudo rm -rf "$HOST_DATA_DIR"
  sudo mkdir -p "$HOST_DATA_DIR"/{alice-data,bob-data,charlie-data,diana-data,shared-team}

  # Create sample files
  echo "Alice's README" | sudo tee "$HOST_DATA_DIR/alice-data/README.txt" > /dev/null
  echo "Bob's data" | sudo tee "$HOST_DATA_DIR/bob-data/data.csv" > /dev/null
  echo "Charlie's analysis" | sudo tee "$HOST_DATA_DIR/charlie-data/analysis.txt" > /dev/null
  echo "Diana's project" | sudo tee "$HOST_DATA_DIR/diana-data/project.md" > /dev/null
  echo "Team notes" | sudo tee "$HOST_DATA_DIR/shared-team/team-notes.txt" > /dev/null

  # Set ownership to specific UIDs
  sudo chown -R 30001:30001 "$HOST_DATA_DIR/alice-data"
  sudo chown -R 30002:30002 "$HOST_DATA_DIR/bob-data"
  sudo chown -R 30003:30003 "$HOST_DATA_DIR/charlie-data"
  sudo chown -R 30004:30004 "$HOST_DATA_DIR/diana-data"
  sudo chown -R 30005:30005 "$HOST_DATA_DIR/shared-team"

  echo "   Test data created on host:"
  ls -la "$HOST_DATA_DIR"
  echo ""

  # Create k3d cluster with volume mount
  echo "2. Creating k3d cluster with hostPath volume mount..."
  k3d cluster create "$CLUSTER_NAME" \
    --agents 1 \
    --volume "$HOST_DATA_DIR:/mnt/data@all" \
    --wait
  echo ""
fi

# Build the Docker image
echo "3. Building Docker image..."
docker build -t data-owner-resolver:latest .. > /dev/null 2>&1

# Import image into k3d
echo "4. Loading image into k3d cluster..."
k3d image import data-owner-resolver:latest -c "$CLUSTER_NAME"
echo ""

# Deploy resources
echo "5. Deploying Kubernetes resources..."
kubectl apply -f namespace.yaml > /dev/null

echo "   Deploying LDAP server (Bitnami OpenLDAP)..."
kubectl apply -f ldap-configmap.yaml > /dev/null
kubectl apply -f ldap-statefulset.yaml > /dev/null

echo "   Waiting for LDAP to be ready..."
kubectl wait --for=condition=ready pod -l app=ldap -n data-resolver --timeout=180s > /dev/null

echo "   Initializing LDAP with test users..."
kubectl apply -f init-ldap-job.yaml > /dev/null
kubectl wait --for=condition=complete job/ldap-init -n data-resolver --timeout=60s > /dev/null
echo ""

# Deploy resolver with hostPath
echo "6. Deploying resolver job with hostPath..."
kubectl delete job data-owner-resolver -n data-resolver --ignore-not-found > /dev/null 2>&1
kubectl apply -f job-hostpath.yaml > /dev/null

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "View resolver output:"
echo "  kubectl logs -n data-resolver job/data-owner-resolver -f"
echo ""
echo "Verify host data was created:"
echo "  ls -la $HOST_DATA_DIR"
echo ""
echo "Cleanup:"
echo "  k3d cluster delete $CLUSTER_NAME"
echo "  sudo rm -rf $HOST_DATA_DIR"
echo ""
