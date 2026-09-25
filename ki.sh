#!/usr/bin/env bash

set -euo pipefail

# Configuration
DEFAULT_ENDPOINT="https://chat.kiconnect.nrw/api/v1"
DEFAULT_CHAT_MODEL="qwen3.8-27b"

# Colors for UX
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Capture inherited environment variables before loading .env
INHERITED_KICONNECT_ENDPOINT="${KICONNECT_ENDPOINT:-}"
INHERITED_BASE_URL="${BASE_URL:-}"
DOTENV_KICONNECT_ENDPOINT=""
DOTENV_BASE_URL=""

trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# Load .env if it exists in the current directory without overwriting inherited environment variables
if [ -f .env ]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//$'\r'/}"
    line="$(trim_whitespace "$line")"
    if [[ -n "$line" && ! "$line" =~ ^# && "$line" == *=* ]]; then
      key="${line%%=*}"
      val="${line#*=}"
      key="$(trim_whitespace "$key")"
      val="$(trim_whitespace "$val")"
      if [[ "$key" == export[[:space:]]* ]]; then
        key="$(trim_whitespace "${key#export}")"
      fi
      if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo -e "${RED}Error:${NC} Invalid variable name in .env: '$key'" >&2
        exit 1
      fi
      if [[ "$val" =~ ^\"(.*)\"$ ]]; then
        val="${BASH_REMATCH[1]}"
      elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
        val="${BASH_REMATCH[1]}"
      fi
      if [ "$key" = "KICONNECT_ENDPOINT" ] && [ -z "$INHERITED_KICONNECT_ENDPOINT" ] && [ -z "$DOTENV_KICONNECT_ENDPOINT" ]; then
        DOTENV_KICONNECT_ENDPOINT="$val"
      fi
      if [ "$key" = "BASE_URL" ] && [ -z "$INHERITED_BASE_URL" ] && [ -z "$DOTENV_BASE_URL" ]; then
        DOTENV_BASE_URL="$val"
      fi
      if [ -z "${!key+x}" ]; then
        export "$key=$val"
      fi
    fi
  done < .env
fi

# Endpoint Resolution State
BASE_URL=""
ENDPOINT_ID=""
ENDPOINT_LABEL=""
ENDPOINT_SOURCE=""

resolve_endpoint() {
  local raw_target=""

  if [ -n "$CLI_ENDPOINT" ]; then
    raw_target="$CLI_ENDPOINT"
    ENDPOINT_SOURCE="cli"
  elif [ -n "$INHERITED_KICONNECT_ENDPOINT" ]; then
    raw_target="$INHERITED_KICONNECT_ENDPOINT"
    ENDPOINT_SOURCE="environment"
  elif [ -n "$DOTENV_KICONNECT_ENDPOINT" ]; then
    raw_target="$DOTENV_KICONNECT_ENDPOINT"
    ENDPOINT_SOURCE="dotenv"
  elif [ -n "$INHERITED_BASE_URL" ]; then
    raw_target="$INHERITED_BASE_URL"
    ENDPOINT_SOURCE="legacy"
  elif [ -n "$DOTENV_BASE_URL" ]; then
    raw_target="$DOTENV_BASE_URL"
    ENDPOINT_SOURCE="legacy"
  else
    raw_target="$DEFAULT_ENDPOINT"
    ENDPOINT_SOURCE="default"
  fi

  raw_target="$(trim_whitespace "$raw_target")"

  case "$raw_target" in
    kiconnect|default)
      ENDPOINT_ID="kiconnect"
      BASE_URL="$DEFAULT_ENDPOINT"
      ;;
    http://*|https://*)
      if [[ ! "$raw_target" =~ ^https?://[^[:space:]/]+(/[^[:space:]]*)?$ ]]; then
        echo -e "${RED}Error:${NC} Invalid endpoint URL: '$raw_target'" >&2
        echo "Accepted endpoints are 'kiconnect', or an absolute HTTP(S) URL (e.g. 'https://.../v1')." >&2
        exit 1
      fi
      ENDPOINT_ID="custom"
      local normalized="$raw_target"
      while [[ "$normalized" == */ ]]; do
        normalized="${normalized%/}"
      done
      BASE_URL="$normalized"
      ;;
    *)
      echo -e "${RED}Error:${NC} Unknown endpoint '$raw_target'." >&2
      echo "Accepted endpoints are 'kiconnect', or an absolute HTTP(S) URL (e.g. 'https://.../v1')." >&2
      exit 1
      ;;
  esac

  local source_desc=""
  case "$ENDPOINT_SOURCE" in
    cli) source_desc="selected by CLI option" ;;
    environment) source_desc="selected by KICONNECT_ENDPOINT environment variable" ;;
    dotenv) source_desc="selected by .env file" ;;
    legacy) source_desc="selected by legacy BASE_URL" ;;
    default) source_desc="default" ;;
  esac

  ENDPOINT_LABEL="${ENDPOINT_ID} (${BASE_URL}; ${source_desc})"
}

# Dependency Check
check_deps() {
  for dep in curl jq; do
    if ! command -v "$dep" &> /dev/null; then
      echo -e "${RED}Error:${NC} $dep is not installed. Please install it to use this script." >&2
      exit 1
    fi
  done
}

# API Key Check
check_api_key() {
  if [ -z "${KICONNECT_API_KEY:-}" ]; then
    # Try fetching from macOS Keychain if on macOS
    if [[ "$OSTYPE" == "darwin"* ]] && command -v security &> /dev/null; then
      KICONNECT_API_KEY=$(security find-generic-password -s kiconnect_api_key -w 2>/dev/null || security find-generic-password -a "$USER" -s kiconnect_api_key -w 2>/dev/null || true)
      export KICONNECT_API_KEY
    fi
  fi

  if [ -z "${KICONNECT_API_KEY:-}" ]; then
    echo -e "${RED}Error:${NC} KICONNECT_API_KEY is not set." >&2
    echo "Please set it in your environment or add it to a .env file as KICONNECT_API_KEY=your_key_here" >&2
    echo "On macOS, it can also be stored in Keychain under 'kiconnect_api_key'." >&2
    exit 1
  fi
}

# Error Handling Helper
handle_api_response() {
  local response="$1"
  if [ -z "$response" ]; then
    echo -e "${RED}Error:${NC} Empty response from API (${BASE_URL})." >&2
    exit 1
  fi
  if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    echo -e "${RED}API Error (${BASE_URL}):${NC}" >&2
    echo "$response" | jq -r '.error.message // .error' >&2
    exit 1
  fi
}

# --- Service Commands ---

list_models() {
  local target_model="${1:-}"

  if [ -n "$target_model" ]; then
    DO_PROBE=1
  fi

  echo -e "${BLUE}Fetching available models from KI:connect...${NC}" >&2
  local response
  response=$(curl -s -X GET "$BASE_URL/models" \
    -H "Authorization: Bearer $KICONNECT_API_KEY" \
    -H "Accept: application/json")

  handle_api_response "$response"

  if [ "$LIST_SHORT" = "1" ]; then
    echo "$response" | jq -r '.data[].id' | sort
    return
  fi

  if [ "$DO_PROBE" = "1" ]; then
    local models_to_probe=()
    if [ -n "$target_model" ]; then
      models_to_probe=("$target_model")
    else
      while IFS= read -r m_id; do
        [ -n "$m_id" ] && models_to_probe+=("$m_id")
      done < <(echo "$response" | jq -r '.data[].id' | sort)
    fi

    echo -e "${BLUE}Probing ${#models_to_probe[@]} model(s) via /v1/chat/completions...${NC}" >&2
    local probe_results="[]"

    for m in "${models_to_probe[@]}"; do
      local token_param="max_tokens"
      if [[ "$m" =~ (GPT5|[Mm]ini) ]]; then
        token_param="max_completion_tokens"
      fi
      local probe_payload
      probe_payload=$(jq -n --arg m "$m" --arg p "$token_param" '{model: $m, messages: [{role: "user", content: "hi"}], ($p): 16}')

      local curl_out
      curl_out=$(curl -s --max-time 15 -w "\n%{http_code}\t%{time_total}" -X POST "$BASE_URL/chat/completions" \
        -H "Authorization: Bearer $KICONNECT_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$probe_payload")

      local meta_line
      meta_line=$(echo "$curl_out" | tail -n 1)
      local body
      body=$(echo "$curl_out" | sed '$d')
      local http_code
      http_code=$(echo "$meta_line" | cut -f1)
      local time_total
      time_total=$(echo "$meta_line" | cut -f2)
      local latency="${time_total}s"

      if [ "$http_code" = "200" ]; then
        probe_results=$(echo "$probe_results" | jq \
          --arg id "$m" \
          --arg lat "$latency" \
          --argjson body "$body" \
          '. + [{
            id: $id,
            upstream: ($body.model // "-"),
            runtime: ($body.system_fingerprint // (if $body.routing then "Azure OpenAI" else "-" end)),
            latency: $lat,
            status: "ok"
          }]')
      else
        local err_msg
        err_msg=$(echo "$body" | jq -r '.error.message // empty' 2>/dev/null)
        [ -z "$err_msg" ] && err_msg="HTTP $http_code"
        probe_results=$(echo "$probe_results" | jq \
          --arg id "$m" \
          --arg lat "$latency" \
          --arg err "$err_msg" \
          '. + [{
            id: $id,
            upstream: "-",
            runtime: "-",
            latency: $lat,
            status: ("error: " + $err)
          }]')
      fi
    done

    if [ "$LIST_JSON" = "1" ]; then
      echo "$probe_results" | jq .
      return
    fi

    echo "$probe_results" | jq -r '
      ( ([ (.[].id | length), 5 ] | max) ) as $w_id
      | ( ([ (.[].upstream | length), 17 ] | max) ) as $w_up
      | ( ([ (.[].runtime | length), 16 ] | max) ) as $w_rt
      | ( ([ (.[].latency | length), 7 ] | max) ) as $w_lat
      | ( "MODEL" + (" " * ($w_id - 5)) + "  "
          + "UPSTREAM SNAPSHOT" + (" " * ($w_up - 17)) + "  "
          + "RUNTIME / ENGINE" + (" " * ($w_rt - 16)) + "  "
          + "LATENCY" + (" " * ($w_lat - 7)) + "  STATUS" ),
        ( .[]
          | ( .id + (" " * ($w_id - (.id | length))) ) + "  "
            + ( .upstream + (" " * ($w_up - (.upstream | length))) ) + "  "
            + ( .runtime + (" " * ($w_rt - (.runtime | length))) ) + "  "
            + ( .latency + (" " * ($w_lat - (.latency | length))) ) + "  "
            + .status
        )'
    return
  fi

  if [ "$LIST_JSON" = "1" ]; then
    echo "$response" | jq '.data | sort_by(.id)'
    return
  fi

  # Pure live table directly from /v1/models (zero hardcoding)
  echo "$response" | jq -r '
    ( ([ (.data[].id | length), 5 ] | max) ) as $w_id
    | ( ([ (.data[].owned_by // "" | length), 8 ] | max) ) as $w_own
    | ( "MODEL" + (" " * ($w_id - 5)) + "  " + "OWNED BY" + (" " * ($w_own - 8)) + "  CREATED" ),
      ( .data
        | sort_by(.id)
        | .[]
        | ( .id + (" " * ($w_id - (.id | length))) )
          + "  " + ( (.owned_by // "-") + (" " * ($w_own - ((.owned_by // "-") | length))) )
          + "  " + ( (.created // 0) | todateiso8601 )
      )'
}

chat_completion() {
  local system_prompt="$1"
  local user_prompt="$2"
  local model="${3:-$DEFAULT_CHAT_MODEL}"

  if [ "$user_prompt" = "-" ]; then
    user_prompt=$(cat)
  fi

  local payload
  payload=$(jq -n \
    --arg sys "$system_prompt" \
    --arg user "$user_prompt" \
    --arg model "$model" \
    '{
      model: $model,
      messages: [
        {role: "system", content: $sys},
        {role: "user", content: $user}
      ]
    }')

  local response
  response=$(curl -s -X POST "$BASE_URL/chat/completions" \
    -H "Authorization: Bearer $KICONNECT_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload")

  handle_api_response "$response"
  echo "$response" | jq -r '.choices[0].message.content // empty'
}

response_completion() {
  local user_prompt="$1"
  local model="${2:-$DEFAULT_CHAT_MODEL}"

  if [ "$user_prompt" = "-" ]; then
    user_prompt=$(cat)
  fi

  local payload
  payload=$(jq -n \
    --arg user "$user_prompt" \
    --arg model "$model" \
    '{
      model: $model,
      input: $user
    }')

  local response
  response=$(curl -s -X POST "$BASE_URL/responses" \
    -H "Authorization: Bearer $KICONNECT_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload")

  handle_api_response "$response"

  if [ "$LIST_JSON" = "1" ]; then
    echo "$response" | jq .
    return
  fi

  local text
  text=$(echo "$response" | jq -r '
    [ .output[]? | select(.type == "message") | .content[]? | select(.type == "output_text") | .text ] | join("")
  ')
  if [ -n "$text" ]; then
    echo "$text"
  else
    echo "$response" | jq -r '.text // .output[0].content[0].text // empty'
  fi
}

create_embedding() {
  local input_text="$1"
  local model="${2:-qwen3.8-27b}"

  if [ "$input_text" = "-" ]; then
    input_text=$(cat)
  fi

  local payload
  payload=$(jq -n \
    --arg input "$input_text" \
    --arg model "$model" \
    '{
      model: $model,
      input: $input
    }')

  local response
  response=$(curl -s -X POST "$BASE_URL/embeddings" \
    -H "Authorization: Bearer $KICONNECT_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload")

  handle_api_response "$response"

  if [ "$LIST_JSON" = "1" ]; then
    echo "$response" | jq .
    return
  fi

  echo "$response" | jq -r '.data[0].embedding // empty'
}

show_help() {
  local script_name="${0##*/}"
  echo -e "${BOLD}KI:connect CLI Client (${script_name})${NC}"
  echo "A lightweight Bash client for the KI:connect AI service API."
  echo ""
  echo "Usage: $script_name [options] <command> [arguments...]"
  echo ""
  echo -e "${BLUE}Options:${NC}"
  echo "  -e, --endpoint <ep>  Select endpoint: 'kiconnect' (default) or custom URL"
  echo "  -s, --short, --ids   Print model IDs only (one per line, for pipelines)"
  echo "  -p, --probe          Live probe backend model snapshot and runtime (models command)"
  echo "  --json               Output raw JSON responses"
  echo "  -h, --help           Show this help message"
  echo ""
  echo -e "${BLUE}Authentication:${NC}"
  echo "  Provide your API key in one of three ways:"
  echo "  1. Export it:        export KICONNECT_API_KEY='your_key'"
  echo "  2. .env file:        echo \"KICONNECT_API_KEY=your_key\" > .env"
  echo "  3. macOS Keychain:   automatically reads 'kiconnect_api_key' if present"
  echo ""
  echo -e "${BLUE}Commands:${NC}"
  echo "  models [model]       List models from /v1/models (pure live data, no hardcoding)."
  echo "                       If [model] or -p/--probe is specified, performs a live completion"
  echo "                       probe to discover exact upstream snapshot and runtime engine."
  echo "                       Warning: probing consumes 1 token request per probed model."
  echo "                       (-s/--short for plain IDs, -p/--probe to probe all, --json)"
  echo "  chat [sys] <user>    Chat completion via /v1/chat/completions (use '-' for stdin)"
  echo "  response <user> [m]  Model response via /v1/responses (use '-' for stdin prompt)"
  echo "  embed <text> [m]     Create embeddings via /v1/embeddings (use '-' for stdin text)"
  echo "  help                 Show this help message"
  echo ""
  echo -e "${BLUE}Examples:${NC}"
  echo "  $script_name models"
  echo "  $script_name models --probe"
  echo "  $script_name models qwen3.8-27b"
  echo "  $script_name models --short"
  echo "  $script_name chat \"Hello from terminal\""
  echo "  $script_name response \"Explain quantum computing briefly\""
  echo "  cat report.txt | $script_name response - GPT5-Mitarbeitende"
  echo "  $script_name chat \"You are a poet\" \"Write a haiku about servers\""
  echo "  cat report.txt | $script_name chat \"Summarize this\" -"
  echo "  $script_name -e https://gateway.example.org/v1 models"
}

# --- CLI Option Parsing ---

CLI_ENDPOINT=""
LIST_SHORT=0
LIST_JSON=0
DO_PROBE=0
REMAINING_ARGS=()

check_deps

while [ $# -gt 0 ]; do
  case "$1" in
    -e|--endpoint)
      if [ -n "${2:-}" ]; then
        CLI_ENDPOINT="$2"
        shift 2
      else
        echo -e "${RED}Error:${NC} Missing argument for $1" >&2
        exit 1
      fi
      ;;
    -s|--short|--ids)
      LIST_SHORT=1
      shift 1
      ;;
    -p|--probe)
      DO_PROBE=1
      shift 1
      ;;
    --json)
      LIST_JSON=1
      shift 1
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    -*)
      if [ "$1" = "-" ]; then
        REMAINING_ARGS+=("$1")
        shift 1
      else
        echo -e "${RED}Error:${NC} Unknown option: $1" >&2
        show_help >&2
        exit 1
      fi
      ;;
    *)
      REMAINING_ARGS+=("$1")
      shift 1
      ;;
  esac
done

if [ ${#REMAINING_ARGS[@]} -gt 0 ]; then
  set -- "${REMAINING_ARGS[@]}"
else
  set --
fi

resolve_endpoint

case "${1:-help}" in
  models)
    check_api_key
    list_models "${2:-}"
    ;;
  chat)
    check_api_key
    if [ -z "${2:-}" ]; then
      echo -e "${RED}Error:${NC} Missing prompt" >&2; exit 1
    fi
    if [ -z "${3:-}" ]; then
      chat_completion "You are a helpful assistant." "$2"
    else
      chat_completion "$2" "$3" "${4:-}"
    fi
    ;;
  response|res)
    check_api_key
    if [ -z "${2:-}" ]; then
      echo -e "${RED}Error:${NC} Missing prompt" >&2; exit 1
    fi
    response_completion "$2" "${3:-}"
    ;;
  embed)
    check_api_key
    if [ -z "${2:-}" ]; then
      echo -e "${RED}Error:${NC} Missing input text" >&2; exit 1
    fi
    create_embedding "$2" "${3:-}"
    ;;
  help)
    show_help
    exit 0
    ;;
  *)
    echo -e "${RED}Error:${NC} Unknown command: '$1'" >&2
    show_help >&2
    exit 1
    ;;
esac
