#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# KI:connect CLI End-to-End Test Suite
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
KI_BIN="$WORKSPACE_DIR/ki.sh"
TEST_TMP_DIR="$SCRIPT_DIR/tmp_test_env"

cd "$WORKSPACE_DIR"

PASSED_COUNT=0
FAILED_COUNT=0

# Colors for test output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

cleanup() {
  rm -rf "$TEST_TMP_DIR"
}
trap cleanup EXIT

rm -rf "$TEST_TMP_DIR"
mkdir -p "$TEST_TMP_DIR/bin"

CURL_LOG="$TEST_TMP_DIR/curl_invocations.log"
MOCK_CURL="$TEST_TMP_DIR/bin/curl"

cat << 'EOF' > "$MOCK_CURL"
#!/usr/bin/env bash
LOG_FILE="${TEST_CURL_LOG:-/tmp/curl_invocations.log}"
echo "$*" | tr '\n' ' ' >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

TARGET_URL=""
for arg in "$@"; do
  if [[ "$arg" =~ ^https?:// ]]; then
    TARGET_URL="$arg"
    break
  fi
done

if [[ "$TARGET_URL" == */models ]]; then
  echo '{"object":"list","data":[{"id":"qwen3.8-27b","owned_by":"tu-dortmund.de","created":1790340713},{"id":"GPT5-Mitarbeitende","owned_by":"tu-dortmund.de","created":1790340713},{"id":"GPT5-mini-Mitarbeitende","owned_by":"tu-dortmund.de","created":1790340713},{"id":"OpenAI GPT OSS 120B","owned_by":"tu-dortmund.de","created":1790340713}]}'
  exit 0
fi

if [[ "$TARGET_URL" == */chat/completions ]]; then
  # Check if prompt triggers error simulation
  if echo "$*" | grep -q "error_trigger"; then
    echo '{"error":{"message":"Invalid prompt parameter","type":"invalid_request_error"}}'
    if echo "$*" | grep -q "%{http_code}"; then printf "\n400\t0.050\n"; fi
    exit 0
  fi
  if echo "$*" | grep -q "empty_response"; then
    echo ""
    exit 0
  fi
  printf '{"id":"mock-1","model":"mock-upstream-model","system_fingerprint":"vllm-0.29.0-mock","choices":[{"message":{"content":"Mock response from KI:connect"}}]}'
  if echo "$*" | grep -q "%{http_code}"; then
    printf "\n200\t0.050\n"
  else
    printf "\n"
  fi
  exit 0
fi

if [[ "$TARGET_URL" == */responses ]]; then
  if echo "$*" | grep -q "error_trigger"; then
    echo '{"error":{"message":"Invalid response parameter","type":"invalid_request_error"}}'
    exit 0
  fi
  echo '{"id":"resp-1","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Mock response from KI:connect responses API"}]}]}'
  exit 0
fi

if [[ "$TARGET_URL" == */embeddings ]]; then
  if echo "$*" | grep -q "error_trigger"; then
    echo '{"error":{"message":"unsupported_model","type":"invalid_request_error"}}'
    exit 0
  fi
  echo '{"object":"list","data":[{"object":"embedding","embedding":[0.0123,-0.0456,0.0789],"index":0}],"model":"qwen3.8-27b","usage":{"prompt_tokens":4,"total_tokens":4}}'
  exit 0
fi

echo '{"error":{"message":"Unrecognized mock endpoint"}}'
exit 1
EOF
chmod +x "$MOCK_CURL"

export PATH="$TEST_TMP_DIR/bin:$PATH"
export TEST_CURL_LOG="$CURL_LOG"

assert_equals() {
  local expected="$1"
  local actual="$2"
  local msg="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "  [PASS] $msg"
    PASSED_COUNT=$((PASSED_COUNT + 1))
  else
    echo -e "  [FAIL] $msg"
    echo -e "    Expected: '$expected'"
    echo -e "    Actual:   '$actual'"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  local msg="$3"
  if echo "$haystack" | grep -qF -e "$needle"; then
    echo -e "  [PASS] $msg"
    PASSED_COUNT=$((PASSED_COUNT + 1))
  else
    echo -e "  [FAIL] $msg"
    echo -e "    Looking for: '$needle'"
    echo -e "    In output:   '$(echo "$haystack" | head -n 5)'"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
}

assert_exit_code() {
  local expected="$1"
  local actual="$2"
  local msg="$3"
  if [ "$expected" -eq "$actual" ]; then
    echo -e "  [PASS] $msg"
    PASSED_COUNT=$((PASSED_COUNT + 1))
  else
    echo -e "  [FAIL] $msg (Expected exit $expected, got $actual)"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
}

# ==============================================================================
# GROUP 1: Help and CLI Option Parsing
# ==============================================================================
echo -e "${BLUE}=== Group 1: CLI Options & Help ===${NC}"

HELP_OUT=$("$KI_BIN" --help)
assert_contains "KI:connect CLI Client" "$HELP_OUT" "--help shows usage title"
assert_contains "models" "$HELP_OUT" "--help lists models command"
assert_contains "chat" "$HELP_OUT" "--help lists chat command"
assert_contains "response" "$HELP_OUT" "--help lists response command"
assert_contains "embed" "$HELP_OUT" "--help lists embed command"
assert_contains "-p, --probe" "$HELP_OUT" "--help lists -p/--probe option"

# Test unknown option
set +e
ERR_OUT=$("$KI_BIN" --unknown-flag 2>&1)
ERR_CODE=$?
set -e
assert_exit_code 1 $ERR_CODE "Unknown option exits with code 1"
assert_contains "Unknown option: --unknown-flag" "$ERR_OUT" "Unknown option error message"

# ==============================================================================
# GROUP 2: Authentication Resolution
# ==============================================================================
echo -e "${BLUE}=== Group 2: Authentication Discovery ===${NC}"

# Test with explicit env var
rm -f "$CURL_LOG"
KICONNECT_API_KEY="test_secret_key" "$KI_BIN" models --short > /dev/null
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "Authorization: Bearer test_secret_key" "$LAST_CURL" "KICONNECT_API_KEY env used in auth header"

# ==============================================================================
# GROUP 3: Models Command Formatting
# ==============================================================================
echo -e "${BLUE}=== Group 3: Models Command Formatting ===${NC}"

# Test interactive table (pure live data)
TABLE_OUT=$(KICONNECT_API_KEY=test "$KI_BIN" models 2>/dev/null)
assert_contains "MODEL" "$TABLE_OUT" "Table header has MODEL"
assert_contains "OWNED BY" "$TABLE_OUT" "Table header has OWNED BY"
assert_contains "CREATED" "$TABLE_OUT" "Table header has CREATED"
assert_contains "qwen3.8-27b" "$TABLE_OUT" "Table includes qwen3.8-27b"
assert_contains "GPT5-Mitarbeitende" "$TABLE_OUT" "Table includes GPT5-Mitarbeitende"
assert_contains "tu-dortmund.de" "$TABLE_OUT" "Table includes live owner from API"

# Test --short format
SHORT_OUT=$(KICONNECT_API_KEY=test "$KI_BIN" models --short 2>/dev/null)
assert_contains "qwen3.8-27b" "$SHORT_OUT" "--short contains qwen3.8-27b"
assert_equals "4" "$(echo "$SHORT_OUT" | wc -l | tr -d ' ')" "--short outputs exactly 4 models"

# Test --json format
JSON_OUT=$(KICONNECT_API_KEY=test "$KI_BIN" models --json 2>/dev/null)
assert_contains '"id": "qwen3.8-27b"' "$JSON_OUT" "--json contains valid json array"

# Test live probe: --probe flag
PROBE_OUT=$(KICONNECT_API_KEY=test "$KI_BIN" models --probe 2>/dev/null)
assert_contains "UPSTREAM SNAPSHOT" "$PROBE_OUT" "--probe table has UPSTREAM SNAPSHOT"
assert_contains "RUNTIME / ENGINE" "$PROBE_OUT" "--probe table has RUNTIME / ENGINE"
assert_contains "mock-upstream-model" "$PROBE_OUT" "--probe table includes mock upstream model"

# Test single model probe: models <model>
SINGLE_OUT=$(KICONNECT_API_KEY=test "$KI_BIN" models qwen3.8-27b 2>/dev/null)
assert_contains "qwen3.8-27b" "$SINGLE_OUT" "Targeted probe outputs qwen3.8-27b"
assert_contains "mock-upstream-model" "$SINGLE_OUT" "Targeted probe outputs upstream model"

# Test --probe --json format
PROBE_JSON=$(KICONNECT_API_KEY=test "$KI_BIN" models --probe --json 2>/dev/null)
assert_contains '"upstream": "mock-upstream-model"' "$PROBE_JSON" "--probe --json has upstream field"

# ==============================================================================
# GROUP 4: Chat Completion
# ==============================================================================
echo -e "${BLUE}=== Group 4: Chat Completion ===${NC}"

rm -f "$CURL_LOG"
CHAT_OUT=$(KICONNECT_API_KEY=test "$KI_BIN" chat "Tell me a joke")
assert_equals "Mock response from KI:connect" "$CHAT_OUT" "Chat returns completion content"
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "chat/completions" "$LAST_CURL" "Chat invokes chat/completions endpoint"

# Test stdin prompt
rm -f "$CURL_LOG"
CHAT_STDIN=$(echo "Piped input" | KICONNECT_API_KEY=test "$KI_BIN" chat -)
assert_equals "Mock response from KI:connect" "$CHAT_STDIN" "Chat reads prompt from stdin"

# ==============================================================================
# GROUP 5: Response Completion (/v1/responses)
# ==============================================================================
echo -e "${BLUE}=== Group 5: Response Completion ===${NC}"

rm -f "$CURL_LOG"
RESP_OUT=$(KICONNECT_API_KEY=test "$KI_BIN" response "Hello responses API")
assert_equals "Mock response from KI:connect responses API" "$RESP_OUT" "Response command returns text content"
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "responses" "$LAST_CURL" "Response command invokes /responses endpoint"

# Test stdin prompt
rm -f "$CURL_LOG"
RESP_STDIN=$(echo "Piped to response" | KICONNECT_API_KEY=test "$KI_BIN" response -)
assert_equals "Mock response from KI:connect responses API" "$RESP_STDIN" "Response reads prompt from stdin"

# Test --json flag
RESP_JSON=$(KICONNECT_API_KEY=test "$KI_BIN" --json response "Test JSON")
assert_contains '"id": "resp-1"' "$RESP_JSON" "Response --json returns raw JSON payload"

# ==============================================================================
# GROUP 6: Embeddings (/v1/embeddings)
# ==============================================================================
echo -e "${BLUE}=== Group 6: Embeddings ===${NC}"

rm -f "$CURL_LOG"
EMBED_OUT=$(KICONNECT_API_KEY=test "$KI_BIN" embed "Vectorize this string")
assert_contains "0.0123" "$EMBED_OUT" "Embed command outputs embedding array"
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "embeddings" "$LAST_CURL" "Embed command invokes /embeddings endpoint"

# Test stdin input
rm -f "$CURL_LOG"
EMBED_STDIN=$(echo "Piped vector text" | KICONNECT_API_KEY=test "$KI_BIN" embed -)
assert_contains "0.0123" "$EMBED_STDIN" "Embed reads input from stdin"

# Test --json flag
EMBED_JSON=$(KICONNECT_API_KEY=test "$KI_BIN" --json embed "Test vector json")
assert_contains '"object": "embedding"' "$EMBED_JSON" "Embed --json returns raw JSON payload"

# ==============================================================================
# GROUP 7: Error Handling
# ==============================================================================
echo -e "${BLUE}=== Group 7: Error Handling & Diagnostics ===${NC}"

set +e
ERR_API=$(KICONNECT_API_KEY=test "$KI_BIN" chat "error_trigger" 2>&1)
assert_exit_code 1 $? "API error triggers exit code 1"
assert_contains "Invalid prompt parameter" "$ERR_API" "API error message forwarded"

ERR_RESP=$(KICONNECT_API_KEY=test "$KI_BIN" response "error_trigger" 2>&1)
assert_exit_code 1 $? "Response error triggers exit code 1"
assert_contains "Invalid response parameter" "$ERR_RESP" "Response error message forwarded"

ERR_EMBED=$(KICONNECT_API_KEY=test "$KI_BIN" embed "error_trigger" 2>&1)
assert_exit_code 1 $? "Embed error triggers exit code 1"
assert_contains "unsupported_model" "$ERR_EMBED" "Embed error message forwarded"

ERR_EMPTY=$(KICONNECT_API_KEY=test "$KI_BIN" chat "empty_response" 2>&1)
assert_exit_code 1 $? "Empty API response triggers exit code 1"
assert_contains "Empty response from API" "$ERR_EMPTY" "Empty response reported"
set -e

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}                         TEST SUMMARY                                 ${NC}"
echo -e "${BLUE}======================================================================${NC}"
echo -e "Total Passed: ${GREEN}$PASSED_COUNT${NC}"
echo -e "Total Failed: ${RED}$FAILED_COUNT${NC}"

if [ "$FAILED_COUNT" -gt 0 ]; then
  echo -e "${RED}Test suite FAILED!${NC}"
  exit 1
else
  echo -e "${GREEN}All tests passed successfully!${NC}"
  exit 0
fi
