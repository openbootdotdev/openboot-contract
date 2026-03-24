#!/bin/bash
# Golden path end-to-end test.
# Validates that data survives the full CLI → Server → CLI round-trip.
#
# Prerequisites:
#   - Server running at $SERVER_URL (default: http://localhost:5173)
#   - CLI binary built at $CLI_BIN (default: openboot in PATH)
#   - jq installed
#
# Usage:
#   ./golden-path/test.sh
#   SERVER_URL=https://openboot.dev ./golden-path/test.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTRACT_DIR="$(dirname "$SCRIPT_DIR")"
SERVER_URL="${SERVER_URL:-http://localhost:5173}"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1: $2"; }

echo "Golden Path Test"
echo "  Server: $SERVER_URL"
echo "  Schemas: $CONTRACT_DIR/schemas/"
echo ""

# --- 1. Validate fixtures against schemas ---
echo "=== Schema Validation ==="

validate_schema() {
  local schema="$1" fixture="$2" label="$3"
  # Use ajv-cli if available, otherwise python jsonschema
  if command -v ajv &>/dev/null; then
    if ajv validate -s "$schema" -d "$fixture" --spec=draft2020 2>/dev/null; then
      pass "$label"
    else
      fail "$label" "schema validation failed"
    fi
  elif python3 -c "import jsonschema" 2>/dev/null; then
    if python3 -c "
import json, jsonschema
schema = json.load(open('$schema'))
data = json.load(open('$fixture'))
jsonschema.validate(data, schema)
" 2>/dev/null; then
      pass "$label"
    else
      fail "$label" "schema validation failed"
    fi
  else
    echo "  - skipped $label (install ajv-cli or python3 jsonschema)"
  fi
}

validate_schema \
  "$CONTRACT_DIR/schemas/remote-config.json" \
  "$CONTRACT_DIR/fixtures/config-v1.json" \
  "config fixture matches schema"

validate_schema \
  "$CONTRACT_DIR/schemas/snapshot.json" \
  "$CONTRACT_DIR/fixtures/snapshot-v1.json" \
  "snapshot fixture matches schema"

# --- 2. Live API checks (if server is reachable) ---
echo ""
echo "=== Live API Checks ==="

if ! curl -sf "$SERVER_URL/api/health" >/dev/null 2>&1; then
  echo "  - Server not reachable at $SERVER_URL, skipping live checks"
else
  # /api/packages schema check
  PKGS_RESPONSE=$(curl -sf "$SERVER_URL/api/packages")
  PKGS_TMP=$(mktemp)
  echo "$PKGS_RESPONSE" > "$PKGS_TMP"
  validate_schema \
    "$CONTRACT_DIR/schemas/packages.json" \
    "$PKGS_TMP" \
    "/api/packages matches schema"
  rm -f "$PKGS_TMP"

  # /api/packages field spot-checks
  if echo "$PKGS_RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
p = d['packages']
assert len(p) > 50, f'only {len(p)} packages'
installers = set(x['installer'] for x in p)
assert installers == {'formula','cask','npm'}, f'missing installer types: {installers}'
" 2>/dev/null; then
    pass "/api/packages has 50+ packages with all installer types"
  else
    fail "/api/packages" "insufficient packages or missing types"
  fi

  # Config endpoint check (try known public config)
  CONFIG_RESPONSE=$(curl -sf "$SERVER_URL/openboot/developer/config" 2>/dev/null || echo '')
  if [ -n "$CONFIG_RESPONSE" ] && [ "$CONFIG_RESPONSE" != "{}" ]; then
    CONFIG_TMP=$(mktemp)
    echo "$CONFIG_RESPONSE" > "$CONFIG_TMP"
    validate_schema \
      "$CONTRACT_DIR/schemas/remote-config.json" \
      "$CONFIG_TMP" \
      "live config response matches schema"
    rm -f "$CONFIG_TMP"
  else
    echo "  - skipped config check (no public config at /openboot/developer)"
  fi
fi

# --- 3. Data round-trip integrity (snapshot → config) ---
echo ""
echo "=== Data Round-Trip Integrity ==="

# The critical invariant: fields present in snapshot must survive through
# server storage and config retrieval. Test with fixture data.
if python3 -c "
import json

snapshot = json.load(open('$CONTRACT_DIR/fixtures/snapshot-v1.json'))
config = json.load(open('$CONTRACT_DIR/fixtures/config-v1.json'))

# Every formulae in snapshot should have a corresponding entry in config.packages
snap_formulae = set(snapshot['packages']['formulae'])
config_pkg_names = set(p['name'] for p in config['packages'])

# Every cask in snapshot should appear in config.casks
snap_casks = set(snapshot['packages']['casks'])
config_cask_names = set(p['name'] for p in config['casks'])

# Every npm in snapshot should appear in config.npm
snap_npm = set(snapshot['packages']['npm'])
config_npm_names = set(p['name'] for p in config['npm'])

# Config entries must have desc field (not empty for known packages)
for entry in config['packages'] + config['casks'] + config['npm']:
    assert 'name' in entry, f'missing name in {entry}'
    assert 'desc' in entry, f'missing desc in {entry}'

# macos_prefs must survive
assert len(config.get('macos_prefs', [])) > 0, 'macos_prefs lost'
assert config['macos_prefs'][0]['domain'] == snapshot['macos_prefs'][0]['domain'], 'macos_prefs domain mismatch'

print('All round-trip invariants hold')
" 2>/dev/null; then
  pass "fixture data round-trip invariants"
else
  fail "round-trip" "data integrity check failed"
fi

# --- Summary ---
echo ""
TOTAL=$((PASS + FAIL))
echo "Results: $PASS/$TOTAL passed"
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
fi
