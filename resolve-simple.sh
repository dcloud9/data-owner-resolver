#!/usr/bin/env bash
# Simple all-in-one resolver: Scan directories and resolve owners via LDAP
# Designed to run inside Kubernetes pods with hostPath volumes

set -e

# Configuration from environment variables
LDAP_URL="${LDAP_URL:-ldap://localhost:389}"
LDAP_BIND_DN="${LDAP_BIND_DN:-cn=admin,dc=example,dc=com}"
LDAP_BIND_PASS="${LDAP_BIND_PASS:-admin}"
LDAP_BASE_DN="${LDAP_BASE_DN:-dc=example,dc=com}"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <directory> [directory2 ...]" >&2
    echo "" >&2
    echo "Scans directories and resolves ownership via LDAP." >&2
    echo "" >&2
    echo "Environment variables:" >&2
    echo "  LDAP_URL        - LDAP server URL (default: ldap://localhost:389)" >&2
    echo "  LDAP_BIND_DN    - LDAP bind DN" >&2
    echo "  LDAP_BIND_PASS  - LDAP bind password" >&2
    echo "  LDAP_BASE_DN    - LDAP search base DN" >&2
    echo "" >&2
    echo "Example:" >&2
    echo "  $0 /mnt/data/project1 /mnt/data/project2" >&2
    exit 1
fi

echo "=== Data Owner Resolver ===" >&2
echo "" >&2

# Test LDAP connectivity
echo "Testing LDAP connection..." >&2
if ! ldapsearch -x -H "$LDAP_URL" -b "$LDAP_BASE_DN" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASS" -s base > /dev/null 2>&1; then
    echo "Error: Cannot connect to LDAP server at $LDAP_URL" >&2
    exit 1
fi
echo "✓ LDAP connection successful" >&2
echo "" >&2

# Start JSON output
echo "{"

first_dir=true
for dir in "$@"; do
    # Check if directory exists
    if [ ! -d "$dir" ]; then
        echo "Warning: $dir is not a directory, skipping" >&2
        continue
    fi

    # Get UID of directory
    uid=$(stat -c '%u' "$dir" 2>/dev/null || stat -f '%u' "$dir" 2>/dev/null)

    echo "  Scanning $dir -> UID $uid" >&2

    # Query LDAP for email address
    email=""
    ldap_result=$(ldapsearch -x -H "$LDAP_URL" \
        -b "$LDAP_BASE_DN" \
        -D "$LDAP_BIND_DN" \
        -w "$LDAP_BIND_PASS" \
        -LLL \
        "(uidNumber=$uid)" \
        mail 2>/dev/null || true)

    # Extract email from LDAP result
    if echo "$ldap_result" | grep -q "^mail:"; then
        email=$(echo "$ldap_result" | grep "^mail:" | head -1 | awk '{print $2}')
        echo "    └─ Resolved to: $email" >&2
    else
        echo "    └─ No LDAP entry found" >&2
    fi

    # Output JSON (Option B format)
    if [ "$first_dir" = false ]; then
        echo ","
    fi
    first_dir=false

    echo "  \"$dir\": {"
    echo "    \"uid\": $uid,"
    echo -n "    \"email\": \"$email\""
    echo ""
    echo -n "  }"
done

echo ""
echo "}"

echo "" >&2
echo "=== Resolution Complete ===" >&2
