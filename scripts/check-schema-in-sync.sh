#!/bin/bash
# scripts/check-schema-in-sync.sh
#
# Fail-closed check that SyncTray/Resources/Schemas/profile.schema.json's
# `properties` keys are a superset of SyncProfile.CodingKeys
# (SyncTray/Models/SyncProfile.swift). A CodingKey missing from the schema
# means an external agent/human hand-editing a `.profile.json` file has no
# validation for that field — this check makes that drift a hard failure,
# both locally and in CI (.github/workflows/ci.yml).
#
# Usage:
#   check-schema-in-sync.sh
#       Real check against the committed schema. Exits 0 if in sync, non-zero
#       (with the missing keys on stderr) if the schema has drifted.
#
#   check-schema-in-sync.sh --self-verify-faildetect
#       Meta-check: builds a temp copy of the schema with one real CodingKey
#       property removed and confirms `check_in_sync` correctly returns
#       non-zero against it (i.e. the check is fail-closed, not just
#       trivially passing). Exits 0 if the fail-detection worked, non-zero if
#       it did not (the check would wrongly pass on a desynced schema).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_SWIFT="$REPO_ROOT/SyncTray/Models/SyncProfile.swift"
PROFILE_SCHEMA="$REPO_ROOT/SyncTray/Resources/Schemas/profile.schema.json"

# Extract the key names from `enum CodingKeys: String, CodingKey { ... }`.
extract_coding_keys() {
    local swift_file="$1"
    awk '/enum CodingKeys: String, CodingKey \{/{flag=1; next} flag && /\}/{flag=0} flag' "$swift_file" \
        | grep -o 'case [a-zA-Z0-9_, ]*' \
        | sed 's/case //' \
        | tr ',' '\n' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | grep -v '^$'
}

# Extract the top-level `properties` keys from a JSON Schema file.
extract_schema_properties() {
    local schema_file="$1"
    python3 -c "
import json
with open('$schema_file') as f:
    schema = json.load(f)
for key in schema.get('properties', {}).keys():
    print(key)
"
}

# Returns 0 if every CodingKey is present in the schema's properties, 1
# otherwise. Prints any missing keys to stderr.
check_in_sync() {
    local swift_file="$1"
    local schema_file="$2"

    local coding_keys
    coding_keys="$(extract_coding_keys "$swift_file")"
    if [[ -z "$coding_keys" ]]; then
        echo "check-schema-in-sync: found no CodingKeys in $swift_file — treating as a failure (fail-closed)" >&2
        return 1
    fi

    local schema_keys
    schema_keys="$(extract_schema_properties "$schema_file")"

    local missing=0
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        if ! grep -qx "$key" <<< "$schema_keys"; then
            echo "check-schema-in-sync: CodingKey '$key' is missing from $schema_file properties" >&2
            missing=1
        fi
    done <<< "$coding_keys"

    return "$missing"
}

if [[ "${1:-}" == "--self-verify-faildetect" ]]; then
    TMP_DIR="$(mktemp -d -t synctray-schema-desync)"
    trap 'rm -rf "$TMP_DIR"' EXIT
    TMP_SCHEMA="$TMP_DIR/profile.schema.json"

    # Drop one real, stable CodingKey property to simulate schema drift.
    python3 -c "
import json
with open('$PROFILE_SCHEMA') as f:
    schema = json.load(f)
schema['properties'].pop('mountAtStartup', None)
with open('$TMP_SCHEMA', 'w') as f:
    json.dump(schema, f)
"

    if check_in_sync "$PROFILE_SWIFT" "$TMP_SCHEMA" >/dev/null 2>&1; then
        echo "check-schema-in-sync: FAIL-CLOSED VERIFICATION FAILED — the check passed against an intentionally desynced schema" >&2
        exit 1
    fi

    echo "check-schema-in-sync: fail-closed verification OK — a desynced schema was correctly rejected"
    exit 0
fi

if check_in_sync "$PROFILE_SWIFT" "$PROFILE_SCHEMA"; then
    echo "check-schema-in-sync: OK — profile.schema.json is in sync with SyncProfile.CodingKeys"
    exit 0
else
    exit 1
fi
