#!/usr/bin/env bash
# Local testing wrapper for data-owner-resolver
# Runs directly on host to avoid rootless Podman UID mapping issues

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <directory> [directory2 ...]"
    echo ""
    echo "Example:"
    echo "  $0 testdata/alice-data testdata/bob-data"
    echo "  $0 /mnt/data/project1 /mnt/data/project2"
    echo ""
    echo "Requirements:"
    echo "  - LDAP server running (./run-containers.sh --keep-running)"
    echo "  - ldap-utils installed on host (sudo dnf install openldap-clients)"
    exit 1
fi

# Check if LDAP container is running
if ! podman ps --format '{{.Names}}' | grep -q '^test-ldap$'; then
    echo "Error: LDAP container not running" >&2
    echo "" >&2
    echo "Start it with:" >&2
    echo "  ./run-containers.sh --keep-running" >&2
    echo "" >&2
    exit 1
fi

# Check if ldapsearch is available
if ! command -v ldapsearch &> /dev/null; then
    echo "Error: ldapsearch not found" >&2
    echo "" >&2
    echo "Install ldap-utils:" >&2
    echo "  sudo dnf install openldap-clients" >&2
    echo "  # or" >&2
    echo "  sudo apt-get install ldap-utils" >&2
    echo "" >&2
    exit 1
fi

# Run resolver on host with LDAP connection to container
LDAP_URL="ldap://localhost:33389" \
LDAP_BIND_DN="cn=admin,dc=example,dc=com" \
LDAP_BIND_PASS="admin" \
LDAP_BASE_DN="dc=example,dc=com" \
./resolve-simple.sh "$@"
