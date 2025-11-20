# JSON Output Format

The data-owner-resolver outputs JSON in a standardized format for easy parsing by external scripts.

## Format Specification

```json
{
  "<absolute-path>": {
    "uid": <numeric-uid>,
    "email": "<email-address>"
  }
}
```

## Example Output

```json
{
  "/mnt/data/project1": {
    "uid": 30001,
    "email": "alice.johnson@example.com"
  },
  "/mnt/data/project2": {
    "uid": 30002,
    "email": "bob.smith@example.com"
  },
  "/mnt/data/shared-data": {
    "uid": 30005,
    "email": "teamlead@example.com"
  }
}
```

## Parsing Examples

### Using `jq`

```bash
# Get all results
./resolve-owners.sh /mnt/data/* > results.json

# Extract email for specific path
jq '."/mnt/data/project1".email' results.json
# Output: "alice.johnson@example.com"

# Extract UID for specific path
jq '."/mnt/data/project1".uid' results.json
# Output: 30001

# List all paths
jq 'keys[]' results.json

# List all emails
jq '.[] | .email' results.json

# Filter entries with specific UID
jq 'to_entries | map(select(.value.uid == 30001))' results.json

# Create CSV format
jq -r 'to_entries[] | [.key, .value.uid, .value.email] | @csv' results.json
```

### Using Python

```python
import json

# Read results
with open('results.json') as f:
    results = json.load(f)

# Access specific path
email = results['/mnt/data/project1']['email']
uid = results['/mnt/data/project1']['uid']

print(f"Path: /mnt/data/project1")
print(f"UID: {uid}")
print(f"Email: {email}")

# Iterate all results
for path, data in results.items():
    print(f"{path} (UID {data['uid']}): {data['email']}")

# Filter by UID
for path, data in results.items():
    if data['uid'] == 30001:
        print(f"Found UID 30001 at: {path}")
```

### Using JavaScript

```javascript
const fs = require('fs');

// Read results
const results = JSON.parse(fs.readFileSync('results.json', 'utf8'));

// Access specific path
const data = results['/mnt/data/project1'];
console.log(`Email: ${data.email}, UID: ${data.uid}`);

// Iterate all results
Object.entries(results).forEach(([path, data]) => {
  console.log(`${path}: ${data.email} (UID ${data.uid})`);
});

// Filter by email domain
const exampleUsers = Object.entries(results)
  .filter(([_, data]) => data.email.endsWith('@example.com'))
  .map(([path, data]) => ({ path, ...data }));
```

### Using Shell Script

```bash
#!/bin/bash
# Parse JSON with jq in shell script

RESULTS="results.json"

# Get email for specific path
get_email() {
    local path="$1"
    jq -r ".\"$path\".email" "$RESULTS"
}

# Get UID for specific path
get_uid() {
    local path="$1"
    jq -r ".\"$path\".uid" "$RESULTS"
}

# Usage
EMAIL=$(get_email "/mnt/data/project1")
UID=$(get_uid "/mnt/data/project1")

echo "Path: /mnt/data/project1"
echo "UID: $UID"
echo "Email: $EMAIL"

# Send notification email
if [ -n "$EMAIL" ]; then
    echo "Disk quota warning" | mail -s "Storage Alert" "$EMAIL"
fi
```

## Edge Cases

### Missing LDAP Entry

When a UID has no LDAP entry, the email field is empty:

```json
{
  "/mnt/data/orphaned-data": {
    "uid": 99999,
    "email": ""
  }
}
```

You can detect this in your scripts:

```bash
# Check for missing emails
jq 'to_entries | map(select(.value.email == ""))' results.json

# Count missing emails
jq '[.[] | select(.email == "")] | length' results.json
```

### Multiple Directories, Same Owner

Multiple paths can have the same UID/email:

```json
{
  "/mnt/data/project1": {
    "uid": 30001,
    "email": "alice.johnson@example.com"
  },
  "/mnt/data/project2": {
    "uid": 30001,
    "email": "alice.johnson@example.com"
  }
}
```

Group by owner:

```bash
# Group paths by email
jq -r 'to_entries | group_by(.value.email) | 
       map({email: .[0].value.email, paths: map(.key)})' results.json
```

## Integration Examples

### Triggering Kubernetes Scan and Parsing Results

```bash
#!/bin/bash
# Trigger scan and parse results

# Run scan via Kubernetes
./k8s/trigger-scan.sh /mnt/data/project1 /mnt/data/project2 > results.json

# Parse and send alerts
jq -r 'to_entries[] | "\(.key)|\(.value.uid)|\(.value.email)"' results.json | \
while IFS='|' read -r path uid email; do
    if [ -z "$email" ]; then
        echo "WARNING: No owner found for $path (UID $uid)"
    else
        echo "Owner of $path: $email (UID $uid)"
    fi
done
```

### Generating Reports

```bash
#!/bin/bash
# Generate ownership report

echo "# Data Ownership Report"
echo "Generated: $(date)"
echo ""

jq -r 'to_entries[] | "## \(.key)\n- UID: \(.value.uid)\n- Email: \(.value.email)\n"' results.json

# Or as a table
echo "| Path | UID | Email |"
echo "|------|-----|-------|"
jq -r 'to_entries[] | "| \(.key) | \(.value.uid) | \(.value.email) |"' results.json
```

## Schema Validation

If you need to validate the JSON format:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "patternProperties": {
    "^/.*": {
      "type": "object",
      "required": ["uid", "email"],
      "properties": {
        "uid": {
          "type": "integer",
          "minimum": 0
        },
        "email": {
          "type": "string"
        }
      }
    }
  }
}
```

Save as `schema.json` and validate:

```bash
# Install ajv-cli
npm install -g ajv-cli

# Validate
ajv validate -s schema.json -d results.json
```
