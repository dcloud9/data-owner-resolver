#!/bin/bash
# Stop and remove containers created by run-containers.sh

set -e

echo "=== Stopping Data Owner Resolver Containers ==="
echo

# Configuration
# Must match run-containers.sh
NETWORK_NAME="podman"  # Default podman network
LDAP_CONTAINER="test-ldap"
LDAP_ADMIN_CONTAINER="ldap-admin"

# Stop and remove LDAP admin
if podman ps -a --format '{{.Names}}' | grep -q "^${LDAP_ADMIN_CONTAINER}$"; then
    echo "Stopping LDAP admin..."
    podman stop "$LDAP_ADMIN_CONTAINER" 2>/dev/null || true
    podman rm "$LDAP_ADMIN_CONTAINER" 2>/dev/null || true
    echo "✓ LDAP admin stopped and removed"
else
    echo "✓ LDAP admin not running"
fi

# Stop and remove LDAP server
if podman ps -a --format '{{.Names}}' | grep -q "^${LDAP_CONTAINER}$"; then
    echo "Stopping LDAP server..."
    podman stop "$LDAP_CONTAINER" 2>/dev/null || true
    podman rm "$LDAP_CONTAINER" 2>/dev/null || true
    echo "✓ LDAP server stopped and removed"
else
    echo "✓ LDAP server not running"
fi

# Note: Not removing network (using default podman network)
if [ "$NETWORK_NAME" != "podman" ]; then
    # Only remove custom networks
    if podman network exists "$NETWORK_NAME" 2>/dev/null; then
        echo "Removing network..."
        podman network rm "$NETWORK_NAME" 2>/dev/null || true
        echo "✓ Network removed"
    fi
fi

echo
echo "=== Cleanup Complete ==="
echo
echo "To start services again, run:"
echo "  ./run-containers.sh --run-resolver"
