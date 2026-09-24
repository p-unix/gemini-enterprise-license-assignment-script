#!/bin/bash

# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# =============================================================================
# Gemini Enterprise License Helpers
# Discovery and verification utilities for Gemini Enterprise subscriptions
#
# Usage: ./gemini-helpers.sh <command>
#
# Commands:
#   check-prereqs       Verify gcloud and curl are installed and authenticated
#   get-project-number  Look up numeric project number from project ID
#   list-configs        List all license config IDs and edition info
#   list-licenses       List currently assigned user licenses
# =============================================================================

set -euo pipefail

# Load config from config.json if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.json"

if command -v jq &>/dev/null && [ -f "$CONFIG_FILE" ]; then
  PROJECT_ID=$(jq -r '.project_id // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
  LOCATION=$(jq -r '.location // "global"' "$CONFIG_FILE" 2>/dev/null || echo "global")
  ENDPOINT_LOCATION=$(jq -r '.endpoint_location // "global"' "$CONFIG_FILE" 2>/dev/null || echo "global")
else
  PROJECT_ID=""
  LOCATION="global"
  ENDPOINT_LOCATION="global"
fi

# --- Helpers ---

_header() {
  echo ""
  echo "=== $1 ==="
  echo ""
}

_require_gcloud() {
  if ! command -v gcloud &>/dev/null; then
    echo "ERROR: gcloud is not installed. Install the Google Cloud SDK first."
    echo "       https://cloud.google.com/sdk/docs/install"
    exit 1
  fi
}

_require_curl() {
  if ! command -v curl &>/dev/null; then
    echo "ERROR: curl is not installed."
    exit 1
  fi
}

_require_auth() {
  if ! gcloud auth print-access-token &>/dev/null; then
    echo "ERROR: gcloud is not authenticated. Run: gcloud auth login"
    exit 1
  fi
}

_require_config() {
  # Auto-discover PROJECT_ID if empty
  if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "your-project-id" ]; then
    PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")
    if [ -z "$PROJECT_ID" ]; then
      echo "  ERROR: Could not auto-discover PROJECT_ID."
      echo "         Please set it in config.json or run: gcloud config set project YOUR_PROJECT"
      exit 1
    else
      echo "  ℹ Auto-discovered Project ID: $PROJECT_ID"
    fi
  fi
}

# --- Commands ---

cmd_check_prereqs() {
  _header "Checking prerequisites"

  local ok=true

  printf "  gcloud CLI ........... "
  if command -v gcloud &>/dev/null; then
    echo "✓ $(gcloud version 2>/dev/null | head -1)"
  else
    echo "✗ NOT FOUND"
    ok=false
  fi

  printf "  curl ................. "
  if command -v curl &>/dev/null; then
    echo "✓ installed"
  else
    echo "✗ NOT FOUND"
    ok=false
  fi

  printf "  python3 .............. "
  if command -v python3 &>/dev/null; then
    echo "✓ installed (optional, for JSON formatting)"
  else
    echo "- not found (optional)"
  fi

  printf "  jq ................... "
  if command -v jq &>/dev/null; then
    echo "✓ installed"
  else
    echo "✗ NOT FOUND (required for formatting configs)"
    ok=false
  fi

  printf "  gcloud auth .......... "
  if gcloud auth print-access-token &>/dev/null 2>&1; then
    local account
    account=$(gcloud config get-value account 2>/dev/null)
    echo "✓ authenticated as ${account}"
  else
    echo "✗ NOT AUTHENTICATED — run: gcloud auth login"
    ok=false
  fi

  echo ""
  
  if [ "$ok" = true ] && [ -n "$PROJECT_ID" ]; then
    printf "  IAM Permissions ...... "
    local account
    account=$(gcloud config get-value account 2>/dev/null)
    local roles
    roles=$(gcloud projects get-iam-policy "$PROJECT_ID" \
      --flatten="bindings[].members" \
      --format="value(bindings.role)" \
      --filter="bindings.members:$account" 2>/dev/null)
    
    if echo "$roles" | grep -E 'roles/discoveryengine\.(admin|editor)' >/dev/null; then
      echo "✓ valid (Discovery Engine Admin/Editor)"
    else
      echo "⚠ WARNING: Could not verify 'roles/discoveryengine.admin' for $account."
      echo "             Assignments may fail if you lack permissions."
    fi
    echo ""
  fi

  if [ "$ok" = true ]; then
    echo "All prerequisites met ✓"
  else
    echo "Some prerequisites are missing — see above."
    exit 1
  fi
}

cmd_get_project_number() {
  _header "Looking up project number"
  _require_gcloud
  _require_auth

  local pid="${1:-$PROJECT_ID}"
  _require_config

  echo "  Project ID: ${pid}"
  local number
  number=$(gcloud projects describe "$pid" --format="value(projectNumber)" 2>/dev/null) || {
    echo "  ERROR: Could not retrieve project number. Check the project ID and your permissions."
    exit 1
  }
  echo "  Project Number: ${number}"
  echo ""
  echo "  Add this to your config.json file (optional if running in Cloud Shell):"
  echo "    \"project_number\": \"${number}\""
}

cmd_list_configs() {
  _header "Listing license configs (subscription IDs)"
  _require_gcloud
  _require_curl
  _require_auth
  _require_config

  if command -v jq &>/dev/null; then
    curl -s -X GET \
      -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      -H "Content-Type: application/json" \
      -H "X-Goog-User-Project: ${PROJECT_ID}" \
      "https://${ENDPOINT_LOCATION}-discoveryengine.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/userStores/default_user_store/licenseConfigsUsageStats" \
      | jq -r '.licenseConfigUsageStats[]? | .licenseConfig | split("/") | last'
    
    echo ""
    echo "  (Copy/paste the exact strings above into your config.json group_mappings)"
  else
    # Fallback to raw output if jq is somehow missing despite prereq checks
    curl -s -X GET \
      -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      -H "Content-Type: application/json" \
      -H "X-Goog-User-Project: ${PROJECT_ID}" \
      "https://${ENDPOINT_LOCATION}-discoveryengine.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/userStores/default_user_store/licenseConfigsUsageStats"
  fi
}

cmd_list_licenses() {
  _header "Listing currently assigned user licenses"
  _require_gcloud
  _require_curl
  _require_auth
  _require_config

  local formatter="cat"
  if command -v jq &>/dev/null; then
    formatter="jq ."
  elif command -v python3 &>/dev/null; then
    formatter="python3 -m json.tool"
  fi

  curl -s -X GET \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    -H "Content-Type: application/json" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    "https://${ENDPOINT_LOCATION}-discoveryengine.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/userStores/default_user_store/userLicenses" \
    | $formatter
}

# --- Dispatch ---

usage() {
  echo "Usage: $0 <command>"
  echo ""
  echo "Commands:"
  echo "  check-prereqs       Verify gcloud, curl, and authentication"
  echo "  get-project-number  Look up numeric project number from project ID"
  echo "  list-configs        List license config IDs and edition info"
  echo "  list-licenses       List currently assigned user licenses"
  echo ""
  echo "Configuration:"
  echo "  Create a config.json file (see config.json.example) or if running in Cloud Shell, you can skip configuring the project details."
}

case "${1:-}" in
  check-prereqs)      cmd_check_prereqs ;;
  get-project-number) shift; cmd_get_project_number "$@" ;;
  list-configs)       cmd_list_configs ;;
  list-licenses)      cmd_list_licenses ;;
  help|--help|-h)     usage ;;
  *)
    echo "Unknown command: ${1:-<none>}"
    echo ""
    usage
    exit 1
    ;;
esac
