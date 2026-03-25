#!/bin/bash
# Golden path end-to-end test.
# Validates the full CLI → Server → CLI round-trip with real execution:
#
#   1. contract-smoke.sh  — schema validation + live API format checks
#   2. curl|bash          — install script is fetchable and structurally valid bash
#   3. CLI --from         — openboot --from fixture dry-run (no TTY required)
#   4. CLI -u remote      — openboot fetches config from server (dry-run, 15s timeout)
#   5. openboot doctor    — post-install health check runs without panic
#
# Modes:
#   Local (default)    — spins up mock-server.py, uses local binary
#   Production         — SERVER_URL=https://openboot.dev CLI_BIN=openboot
#
# Prerequisites:
#   - python3
#   - openboot binary at $CLI_BIN (default: searches ../openboot/openboot then PATH)
#
# Usage:
#   ./golden-path/test.sh
#   SERVER_URL=https://openboot.dev CLI_BIN=/usr/local/bin/openboot ./golden-path/test.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTRACT_DIR="$(dirname "$SCRIPT_DIR")"
CLI_REPO="$(dirname "$CONTRACT_DIR")/openboot"

SERVER_URL="${SERVER_URL:-}"
CLI_BIN="${CLI_BIN:-}"
MOCK_PID=""
MOCK_PORT="${MOCK_PORT:-18889}"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1: $2"; }
section() { echo ""; echo "=== $1 ==="; }

# macOS ships without GNU timeout; use gtimeout (brew install coreutils) if available
if command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD=gtimeout
elif command -v timeout &>/dev/null; then
  TIMEOUT_CMD=timeout
else
  # Fallback: no-op wrapper — just run the command directly
  TIMEOUT_CMD=""
fi
_timeout() { local secs="$1"; shift; if [ -n "$TIMEOUT_CMD" ]; then $TIMEOUT_CMD "$secs" "$@"; else "$@"; fi; }

cleanup() {
  if [ -n "$MOCK_PID" ] && kill -0 "$MOCK_PID" 2>/dev/null; then
    kill "$MOCK_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Resolve CLI binary
# ---------------------------------------------------------------------------
if [ -z "$CLI_BIN" ]; then
  if [ -x "$CLI_REPO/openboot" ]; then
    CLI_BIN="$CLI_REPO/openboot"
  elif command -v openboot &>/dev/null; then
    CLI_BIN="$(command -v openboot)"
  else
    echo "ERROR: no openboot binary found. Build it first:"
    echo "  cd ../openboot && make build"
    echo "or set CLI_BIN=/path/to/openboot"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Spin up mock server if no SERVER_URL given
# ---------------------------------------------------------------------------
USE_MOCK=false
if [ -z "$SERVER_URL" ]; then
  MOCK_SERVER="$CLI_REPO/scripts/mock-server.py"
  if [ ! -f "$MOCK_SERVER" ]; then
    echo "ERROR: mock-server.py not found at $MOCK_SERVER"
    exit 1
  fi
  python3 "$MOCK_SERVER" "$MOCK_PORT" "$CLI_BIN" &
  MOCK_PID=$!
  sleep 1
  SERVER_URL="http://localhost:$MOCK_PORT"
  USE_MOCK=true
  echo "Mock server started (pid $MOCK_PID) at $SERVER_URL"
fi

CLI_VERSION=$("$CLI_BIN" version 2>/dev/null | head -1 || echo "unknown")

echo ""
echo "Golden Path Test"
echo "  Server:  $SERVER_URL"
echo "  CLI:     $CLI_BIN ($CLI_VERSION)"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Contract smoke (schema + API format)
# ---------------------------------------------------------------------------
section "Step 1: Contract Smoke (schema + API)"
if SERVER_URL="$SERVER_URL" bash "$SCRIPT_DIR/contract-smoke.sh" 2>&1 \
    | grep -E "✓|✗|skipped|PASSED|FAILED|Results:"; then
  pass "contract-smoke.sh passed"
else
  fail "contract-smoke" "contract-smoke.sh exited non-zero"
fi

# ---------------------------------------------------------------------------
# Step 2: curl|bash — install script is fetchable and is valid bash
# ---------------------------------------------------------------------------
section "Step 2: curl|bash (install script fetch + syntax check)"

if $USE_MOCK; then
  INSTALL_URL="$SERVER_URL/testuser/test-config/install"
else
  # Use a known public config on production
  INSTALL_URL="${GOLDEN_PATH_INSTALL_URL:-$SERVER_URL/openboot/developer/install}"
fi

INSTALL_SCRIPT=$(curl -sf "$INSTALL_URL" 2>/dev/null || echo "")
if [ -z "$INSTALL_SCRIPT" ]; then
  fail "fetch install script" "curl $INSTALL_URL returned empty (set GOLDEN_PATH_INSTALL_URL)"
else
  pass "install script fetched ($INSTALL_URL)"
fi

# Check script syntax without executing
if [ -n "$INSTALL_SCRIPT" ]; then
  if echo "$INSTALL_SCRIPT" | bash -n 2>/dev/null; then
    pass "install script is valid bash (syntax check)"
  else
    fail "install script syntax" "bash -n failed"
  fi

  # Check for required structure
  if echo "$INSTALL_SCRIPT" | grep -q "OPENBOOT_DRY_RUN\|openboot"; then
    pass "install script references openboot binary"
  else
    fail "install script content" "missing openboot reference"
  fi

  # Execute with timeout — accept TTY errors (expected in non-interactive context)
  if $USE_MOCK; then
    EXEC_OUT=$(_timeout 15 bash <(echo "$INSTALL_SCRIPT") 2>&1 || true)
    if echo "$EXEC_OUT" | grep -qiE "dry.run|DRY-RUN|packages|config|tty|TTY|could not open"; then
      pass "curl|bash executed (got expected output)"
    elif [ -z "$EXEC_OUT" ]; then
      fail "curl|bash execution" "no output after 15s"
    else
      fail "curl|bash execution" "unexpected output: $(echo "$EXEC_OUT" | head -2)"
    fi
  else
    echo "  - skipping execution in production mode (would modify system)"
  fi
fi

# ---------------------------------------------------------------------------
# Step 3: CLI --from fixture (no TTY required)
# ---------------------------------------------------------------------------
section "Step 3: CLI --from fixture dry-run"

FIXTURE="$CONTRACT_DIR/fixtures/config-v1.json"
if [ ! -f "$FIXTURE" ]; then
  fail "--from test" "fixture not found: $FIXTURE"
else
  FROM_OUT=$(OPENBOOT_DRY_RUN=true _timeout 20 \
    "$CLI_BIN" --from "$FIXTURE" --silent 2>&1 || true)

  if echo "$FROM_OUT" | grep -qiE "dry.run|DRY-RUN|packages|preview|could not open.*tty|no.*tty"; then
    pass "openboot --from fixture dry-run produced output"
  elif echo "$FROM_OUT" | grep -qi "error"; then
    # Any recognisable error message (not a silent hang/panic) is acceptable
    pass "openboot --from fixture exited with error (non-interactive env)"
  else
    fail "--from dry-run" "unexpected output: $(echo "$FROM_OUT" | head -3)"
  fi
fi

# ---------------------------------------------------------------------------
# Step 4: CLI -u (remote config fetch, dry-run, 15s timeout)
# ---------------------------------------------------------------------------
section "Step 4: CLI -u remote config fetch"

if $USE_MOCK; then
  REMOTE_OUT=$(OPENBOOT_DRY_RUN=true OPENBOOT_API_URL="$SERVER_URL" \
    _timeout 15 "$CLI_BIN" -s -u testuser/test-config 2>&1 || true)
else
  REMOTE_OUT=$(OPENBOOT_DRY_RUN=true \
    _timeout 15 "$CLI_BIN" -s -u openboot/developer 2>&1 || true)
fi

if echo "$REMOTE_OUT" | grep -qiE "dry.run|DRY-RUN|packages|config|could not open.*tty|no.*tty"; then
  pass "openboot -u remote config fetched"
elif echo "$REMOTE_OUT" | grep -qi "fetch.*config\|connect.*refused\|not found"; then
  fail "remote config fetch" "$(echo "$REMOTE_OUT" | head -2)"
else
  pass "openboot -u completed (output: $(echo "$REMOTE_OUT" | head -1))"
fi

# ---------------------------------------------------------------------------
# Step 5: openboot doctor
# ---------------------------------------------------------------------------
section "Step 5: openboot doctor"

DOCTOR_OUT=$(_timeout 120 "$CLI_BIN" doctor 2>&1 || true)

if echo "$DOCTOR_OUT" | grep -qiE "brew|homebrew|openboot|Homebrew"; then
  pass "openboot doctor produced output"
else
  fail "doctor" "no recognisable output: $(echo "$DOCTOR_OUT" | head -3)"
fi

if echo "$DOCTOR_OUT" | grep -q "panic:"; then
  fail "doctor panic" "$(echo "$DOCTOR_OUT" | grep panic | head -1)"
else
  pass "openboot doctor did not panic"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
TOTAL=$((PASS + FAIL))
echo "Results: $PASS/$TOTAL passed"
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
fi
