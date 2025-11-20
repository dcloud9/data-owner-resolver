# Testing Guide

## Current Status

✅ **Working!** The resolver successfully maps UIDs to email addresses.

### Test Results

```json
{
  "/mnt/data/alice-data": {
    "30001": "alice.johnson@example.com"
  },
  "/mnt/data/bob-data": {
    "30002": "bob.smith@example.com"
  },
  "/mnt/data/charlie-data": {
    "30003": "charlie.brown@example.com"
  },
  "/mnt/data/diana-data": {
    "30004": "diana.prince@example.com"
  },
  "/mnt/data/shared-team": {
    "30005": "teamlead@example.com"
  }
}
```

## Quick Test Commands

### Run Complete Test
```bash
./test-resolver.sh
```

### Manual Test Steps
```bash
# 1. Verify LDAP is running
docker ps | grep ldap

# 2. Check LDAP has users
docker exec test-ldap ldapsearch -x -H ldap://localhost:389 \
  -b dc=example,dc=com -D 'cn=admin,dc=example,dc=com' -w admin \
  "(objectClass=posixAccount)" | grep "^dn:"

# 3. Run resolver
docker run --rm --network container:test-ldap \
  -v "$(pwd)/testdata:/mnt/data:ro" \
  -e LDAP_URL=ldap://localhost:389 \
  -e LDAP_BIND_DN=cn=admin,dc=example,dc=com \
  -e LDAP_BIND_PASS=admin \
  -e LDAP_BASE_DN=dc=example,dc=com \
  data-owner-resolver:latest
```

## Test Data

### Users in LDAP (users-updated.ldif)
| Username | UID   | Email |
|----------|-------|-------|
| alice    | 30001 | alice.johnson@example.com |
| bob      | 30002 | bob.smith@example.com |
| charlie  | 30003 | charlie.brown@example.com |
| diana    | 30004 | diana.prince@example.com |
| teamlead | 30005 | teamlead@example.com |

### Directories in testdata/
| Directory | UID | Owner |
|-----------|-----|-------|
| alice-data/ | 30001 | alice |
| bob-data/ | 30002 | bob |
| charlie-data/ | 30003 | charlie |
| diana-data/ | 30004 | diana |
| shared-team/ | 30005 | teamlead |

## Known Issues

### Stuck Containers (Cannot Stop)

If you get "permission denied" when trying to stop containers:

**Cause**: Docker with containerd runtime + cgroup v2 can cause permission issues

**Solutions**:
1. Restart Docker: `sudo systemctl restart docker`
2. Use cleanup script: `./force-cleanup.sh`
3. Work around it: Import users into running containers (see below)

**Workaround** (no container restart needed):
```bash
# Import new users into running LDAP
cat users-updated.ldif | docker exec -i test-ldap \
  ldapadd -x -D "cn=admin,dc=example,dc=com" -w admin

# Test immediately
./test-resolver.sh
```

## Verifying the Setup

### Check testdata directory ownership
```bash
ls -la testdata/
# Should show UIDs 30001-30005 for each directory
```

### Verify LDAP users
```bash
docker exec test-ldap ldapsearch -x -H ldap://localhost:389 \
  -b dc=example,dc=com -D 'cn=admin,dc=example,dc=com' -w admin \
  "(uidNumber=30001)" mail
```

Expected output:
```
dn: uid=alice,dc=example,dc=com
mail: alice.johnson@example.com
```

### Test specific UID lookup
```bash
# Create a test with single user
docker run --rm --network container:test-ldap \
  -v "$(pwd)/testdata/alice-data:/mnt/data/alice-data:ro" \
  -e LDAP_URL=ldap://localhost:389 \
  -e LDAP_BIND_DN=cn=admin,dc=example,dc=com \
  -e LDAP_BIND_PASS=admin \
  -e LDAP_BASE_DN=dc=example,dc=com \
  data-owner-resolver:latest
```

## Adding New Test Users

### 1. Create directory with specific UID
```bash
mkdir testdata/eve-data
docker run --rm -v "$(pwd)/testdata:/data" alpine \
  chown -R 30006:30006 /data/eve-data
```

### 2. Add LDAP entry
Create `eve.ldif`:
```ldif
dn: uid=eve,dc=example,dc=com
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: top
cn: Eve Davis
sn: Davis
uid: eve
uidNumber: 30006
gidNumber: 30006
homeDirectory: /home/eve
mail: eve.davis@example.com
```

Import:
```bash
docker exec -i test-ldap ldapadd -x -D "cn=admin,dc=example,dc=com" -w admin < eve.ldif
```

### 3. Test
```bash
./test-resolver.sh
```

## Debugging

### LDAP Connection Issues
```bash
# Test LDAP connectivity
docker exec test-ldap ldapsearch -x -H ldap://localhost:389 -b dc=example,dc=com

# Check LDAP logs
docker logs test-ldap
```

### UID Mismatch
```bash
# Check actual UID of directory
stat -c '%u %n' testdata/*/

# Compare with LDAP
docker exec test-ldap ldapsearch -x -H ldap://localhost:389 \
  -b dc=example,dc=com -D 'cn=admin,dc=example,dc=com' -w admin \
  "(objectClass=posixAccount)" uidNumber
```

### Resolver Issues
```bash
# Build with verbose output
docker build -t data-owner-resolver:latest . --no-cache

# Run with debug
docker run --rm --network container:test-ldap \
  -v "$(pwd)/testdata:/mnt/data:ro" \
  -e LDAP_URL=ldap://localhost:389 \
  -e LDAP_BIND_DN=cn=admin,dc=example,dc=com \
  -e LDAP_BIND_PASS=admin \
  -e LDAP_BASE_DN=dc=example,dc=com \
  data-owner-resolver:latest 2>&1 | tee resolver-debug.log
```

## Continuous Testing

### Automated Test Loop
```bash
# Test repeatedly (useful for debugging intermittent issues)
while true; do
  echo "=== Test Run $(date) ==="
  ./test-resolver.sh
  echo
  sleep 5
done
```

## Clean Slate Testing

To test from a completely clean state:

```bash
# 1. Stop everything (may need sudo systemctl restart docker if stuck)
docker-compose down -v

# 2. Remove testdata and recreate
rm -rf testdata
mkdir -p testdata/{alice-data,bob-data,charlie-data,diana-data,shared-team}
docker run --rm -v "$(pwd)/testdata:/data" alpine sh -c "
  chown -R 30001:30001 /data/alice-data &&
  chown -R 30002:30002 /data/bob-data &&
  chown -R 30003:30003 /data/charlie-data &&
  chown -R 30004:30004 /data/diana-data &&
  chown -R 30005:30005 /data/shared-team"

# 3. Start fresh
docker-compose up -d ldap ldap-admin
sleep 10

# 4. Import users
cat users-updated.ldif | docker exec -i test-ldap \
  ldapadd -x -D "cn=admin,dc=example,dc=com" -w admin

# 5. Test
./test-resolver.sh
```
