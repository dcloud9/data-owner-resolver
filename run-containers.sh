#!/usr/bin/env bash
# Run containers using plain podman commands (no docker-compose required)
# Works on Amazon Linux 2023 and other systems with only podman installed

set -e

# Ensure we're using bash
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash"
    exit 1
fi

echo "=== Data Owner Resolver - Container Runner ==="
echo

# Detect platform (for informational purposes)
if [[ "$OSTYPE" == "darwin"* ]]; then
    PLATFORM="macOS"
else
    PLATFORM="Linux"
fi

echo "Detected platform: $PLATFORM"
echo

# Configuration
# Use default podman network to avoid CNI issues on Amazon Linux 2023
# Alternative: data-owner-resolver-net (custom network)
NETWORK_NAME="podman"  # Default podman network (always exists)
LDAP_CONTAINER="test-ldap"
LDAP_ADMIN_CONTAINER="ldap-admin"
RESOLVER_IMAGE="data-owner-resolver:latest"

# Port configuration
# Use non-privileged ports (>= 1024) to avoid needing root on Linux
# Bitnami LDAP listens on port 1389 internally (not 389)
LDAP_HOST_PORT="33389"  # Host port (non-privileged)
LDAP_CONTAINER_PORT="1389"  # Container internal port (Bitnami default)
LDAP_ADMIN_HOST_PORT="8080"  # Host port for admin UI

# Parse command line arguments
KEEP_RUNNING=false
FORCE_REBUILD=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --keep-running)
            KEEP_RUNNING=true
            shift
            ;;
        --rebuild)
            FORCE_REBUILD=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--keep-running] [--rebuild]"
            echo "  --keep-running: Keep services running (don't stop at end)"
            echo "  --rebuild:      Force rebuild of resolver image"
            exit 1
            ;;
    esac
done


# Verify network exists (default podman network should always exist)
echo "Setting up network..."
if podman network exists "$NETWORK_NAME" 2>/dev/null; then
    echo "✓ Using network: $NETWORK_NAME"
else
    echo "ERROR: Network '$NETWORK_NAME' not found"
    echo "Available networks:"
    podman network ls
    exit 1
fi
echo

# Start LDAP server
echo "Starting LDAP server..."
if podman ps -a --format '{{.Names}}' | grep -q "^${LDAP_CONTAINER}$"; then
    if podman ps --format '{{.Names}}' | grep -q "^${LDAP_CONTAINER}$"; then
        echo "✓ LDAP server already running"
    else
        podman start "$LDAP_CONTAINER"
        echo "✓ LDAP server started (existing container)"
    fi
else
    # Use Bitnami image from AWS ECR Public (no rate limits)
    # Alternative to osixia/openldap:1.5.0 from Docker Hub
    LDAP_IMAGE="public.ecr.aws/bitnami/openldap:2.6"

    # Run the command - if it fails, show debug info
    if ! podman run -d --name "$LDAP_CONTAINER" --network "$NETWORK_NAME" \
        -p "${LDAP_HOST_PORT}:${LDAP_CONTAINER_PORT}" \
        -e LDAP_ROOT="dc=example,dc=com" \
        -e LDAP_ADMIN_USERNAME="admin" \
        -e LDAP_ADMIN_PASSWORD="admin" \
        "$LDAP_IMAGE"; then
        echo ""
        echo "ERROR: Failed to start LDAP container"
        echo "Container: $LDAP_CONTAINER"
        echo "Network: $NETWORK_NAME"
        echo "Image: $LDAP_IMAGE"
        echo "Port: ${LDAP_HOST_PORT}:${LDAP_CONTAINER_PORT}"
        echo ""
        echo "Try running manually:"
        echo "  podman run -d --name $LDAP_CONTAINER --network $NETWORK_NAME \\"
        echo "    -p ${LDAP_HOST_PORT}:${LDAP_CONTAINER_PORT} \\"
        echo "    -e LDAP_ROOT='dc=example,dc=com' -e LDAP_ADMIN_USERNAME='admin' \\"
        echo "    -e LDAP_ADMIN_PASSWORD='admin' $LDAP_IMAGE"
        exit 1
    fi
    echo "✓ LDAP server started (new container)"
fi
echo

# Wait for LDAP to be ready
echo "Waiting for LDAP server to be ready..."
echo "  (Bitnami LDAP can take 60-90 seconds to fully initialize)"

# Wait for the logs to show "slapd starting"
sleep 10

MAX_RETRIES=90  # 3 minutes total
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    # Try both port 1389 and 389 (Bitnami uses 1389)
    if podman exec "$LDAP_CONTAINER" ldapsearch -x -H ldap://localhost:1389 -b '' -s base >/dev/null 2>&1 || \
       podman exec "$LDAP_CONTAINER" ldapsearch -x -H ldap://localhost:389 -b '' -s base >/dev/null 2>&1; then
        echo "✓ LDAP server is ready (after $((RETRY_COUNT * 2 + 10)) seconds)"
        sleep 2
        break
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))

    # Show progress every 15 attempts (30 seconds)
    if [ $((RETRY_COUNT % 15)) -eq 0 ]; then
        echo "  Still waiting... ($((RETRY_COUNT * 2 + 10))s elapsed)"
    fi

    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        echo ""
        echo "⚠ LDAP server not responding after $((MAX_RETRIES * 2 + 10)) seconds"
        echo ""
        echo "Last 50 lines of container logs:"
        podman logs "$LDAP_CONTAINER" 2>&1 | tail -50
        echo ""
        echo "Container is running but LDAP may not be fully initialized."
        echo "This can happen with Bitnami LDAP on slow systems."
        echo ""
        echo "Continuing anyway - errors may occur if LDAP is not ready..."
        echo ""
        break
    fi

    sleep 2
done
echo

# Import LDAP seed data
echo "Importing LDAP seed data..."

# Try to check if users exist (with retry)
USER_EXISTS=false
for i in {1..10}; do
    if podman exec "$LDAP_CONTAINER" ldapsearch -x -H ldap://localhost:1389 \
        -b dc=example,dc=com -D 'cn=admin,dc=example,dc=com' -w admin \
        "(uid=alice)" 2>/dev/null | grep -q "^dn: uid=alice"; then
        USER_EXISTS=true
        break
    fi
    sleep 2
done

if [ "$USER_EXISTS" = true ]; then
    echo "✓ Users already exist, skipping import"
else
    if [ -f "users-updated.ldif" ]; then
        # Try to import with retry
        echo "  Attempting to import seed data..."
        for i in {1..5}; do
            if cat users-updated.ldif | podman exec -i "$LDAP_CONTAINER" \
                ldapadd -x -H ldap://localhost:1389 -D "cn=admin,dc=example,dc=com" -w admin 2>&1; then
                echo "✓ Seed data imported successfully"
                break
            else
                if [ $i -lt 5 ]; then
                    echo "  Import failed, retrying in 5 seconds... (attempt $i/5)"
                    sleep 5
                else
                    echo "⚠ Warning: Failed to import seed data after 5 attempts"
                    echo "  LDAP may not be fully ready yet"
                fi
            fi
        done
    else
        echo "⚠ Warning: users-updated.ldif not found, skipping seed data import"
    fi
fi
echo

# Start LDAP admin
echo "Starting LDAP admin interface..."
if podman ps -a --format '{{.Names}}' | grep -q "^${LDAP_ADMIN_CONTAINER}$"; then
    if podman ps --format '{{.Names}}' | grep -q "^${LDAP_ADMIN_CONTAINER}$"; then
        echo "✓ LDAP admin already running"
    else
        podman start "$LDAP_ADMIN_CONTAINER"
        echo "✓ LDAP admin started (existing container)"
    fi
else
    # LDAP admin is optional - skip if you hit rate limits
    echo "⚠ Skipping LDAP admin UI (optional - to avoid rate limits)"
    echo "  You can use ldapsearch commands directly on the container"
fi
echo

# Build resolver image
echo "Checking resolver image..."

# Check if image exists
IMAGE_EXISTS=false
if podman image exists "$RESOLVER_IMAGE" 2>/dev/null; then
    IMAGE_EXISTS=true
fi

# Only rebuild if forced or if image doesn't exist
if [ "$FORCE_REBUILD" = true ] || [ "$IMAGE_EXISTS" = false ]; then
    if [ "$FORCE_REBUILD" = true ]; then
        echo "  Force rebuilding resolver image..."
    else
        echo "  Building resolver image (first time)..."
    fi

    # Use build cache for faster builds
    # Mount Go module cache and build cache
    podman build -t "$RESOLVER_IMAGE" . \
        --layers \
        2>&1 | grep -v "^STEP" || true

    echo "✓ Resolver image built"
else
    echo "✓ Resolver image already exists (use --rebuild to force rebuild)"
fi
echo

# Summary
echo "=== Services Status ==="
echo
echo "✓ LDAP server:    running at localhost:${LDAP_HOST_PORT}"
if podman ps --format '{{.Names}}' | grep -q "^${LDAP_ADMIN_CONTAINER}$"; then
    echo "✓ LDAP admin UI:  http://localhost:${LDAP_ADMIN_HOST_PORT}"
else
    echo "- LDAP admin UI:  not running (optional)"
fi
echo "✓ Resolver image: $RESOLVER_IMAGE"
echo
echo "Note: LDAP accessible from host at localhost:${LDAP_HOST_PORT}"
echo "      Containers communicate via Bitnami LDAP port 1389"
echo

echo "To resolve directory owners:"
echo "  ./resolve-owners.sh testdata/alice-data testdata/bob-data"
echo "  ./resolve-owners.sh /mnt/data/project1 /mnt/data/project2"
echo

if [ "$KEEP_RUNNING" = false ]; then
    echo "To stop services:"
    echo "  ./stop-containers.sh"
    echo
    echo "Or manually:"
    echo "  podman stop $LDAP_CONTAINER $LDAP_ADMIN_CONTAINER"
    echo "  podman rm $LDAP_CONTAINER $LDAP_ADMIN_CONTAINER"
    if [ "$NETWORK_NAME" != "podman" ]; then
        echo "  podman network rm $NETWORK_NAME"
    fi
fi

echo
echo "=== Setup Complete ==="
