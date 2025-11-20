#!/usr/bin/env bash
# Host-side script: Scan directories and extract unique UIDs
# This runs on the host where real UIDs are visible (no container UID mapping issues)

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <directory> [directory2 ...]"
    echo ""
    echo "Scans directories and outputs unique UIDs as JSON"
    echo ""
    echo "Example:"
    echo "  $0 /mnt/data/project1 /mnt/data/project2"
    echo "  $0 testdata/*"
    exit 1
fi

# Collect all directories to scan
SCAN_DIRS=("$@")

echo "Scanning directories for file ownership..." >&2
echo "" >&2

# Find all unique UIDs in the specified directories
# Output format: directory path -> UID
declare -A dir_uids

for dir in "${SCAN_DIRS[@]}"; do
    if [ ! -d "$dir" ]; then
        echo "Warning: $dir is not a directory, skipping" >&2
        continue
    fi

    # Get the UID of the directory itself and all files/subdirs
    uid=$(stat -c '%u' "$dir" 2>/dev/null || stat -f '%u' "$dir" 2>/dev/null)
    dir_uids["$dir"]=$uid

    echo "  $dir -> UID $uid" >&2
done

echo "" >&2
echo "Found ${#dir_uids[@]} directories" >&2
echo "" >&2

# Output as JSON for the resolver
echo "{"
first=true
for dir in "${!dir_uids[@]}"; do
    if [ "$first" = false ]; then
        echo ","
    fi
    first=false
    uid="${dir_uids[$dir]}"
    echo -n "  \"$dir\": $uid"
done
echo ""
echo "}"
