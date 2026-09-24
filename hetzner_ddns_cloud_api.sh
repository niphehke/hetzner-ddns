#!/bin/bash

# Shared environment variables
HETZNER_CLOUD_API_TOKEN=${HETZNER_CLOUD_API_TOKEN}
CHECK_INTERVAL_SECONDS=${CHECK_INTERVAL_SECONDS:-300}

# Highest domain slot number the script will look for (HETZNER_DNS_ZONE_NAME_1 .. _MAX_DOMAIN_SLOTS).
# Raise this only if you ever need more than 20 domains.
MAX_DOMAIN_SLOTS=${MAX_DOMAIN_SLOTS:-20}

# Logging
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

if [ -z "$HETZNER_CLOUD_API_TOKEN" ]; then
  log "ERROR: HETZNER_CLOUD_API_TOKEN is missing! Please set it."
  exit 1
fi

# Check Zone ID
get_zone_id() {
  local ZONE_NAME=$1
  local ZONE_INFO
  ZONE_INFO=$(curl -s -X GET \
    -H "Authorization: Bearer $HETZNER_CLOUD_API_TOKEN" \
    "https://api.hetzner.cloud/v1/zones?name=$ZONE_NAME")

  local ZONE_ID
  ZONE_ID=$(echo "$ZONE_INFO" | jq -r '.zones[] | select(.name == "'"$ZONE_NAME"'") | .id')

  if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" == "null" ]; then
    log "ERROR: DNS zone '$ZONE_NAME' could not be found or API request failed: $ZONE_INFO"
    return 1
  fi
  echo "$ZONE_ID"
}

# Get Record ID
get_record_id() {
  local ZONE_ID=$1
  local ZONE_NAME=$2
  local RECORD_NAME=$3
  local RECORD_INFO
  RECORD_INFO=$(curl -s -X GET \
    -H "Authorization: Bearer $HETZNER_CLOUD_API_TOKEN" \
    "https://api.hetzner.cloud/v1/zones/$ZONE_ID/rrsets")

  local RECORD_ID
  RECORD_ID=$(echo "$RECORD_INFO" | jq -r '.rrsets[] | select(.name == "'"$RECORD_NAME"'") | select(.type == "A") | .id')

  if [ -z "$RECORD_ID" ] || [ "$RECORD_ID" == "null" ]; then
    log "ERROR: DNS record '$RECORD_NAME' (A-Record) in zone '$ZONE_NAME' could not be found or API request failed: $RECORD_INFO"
    return 1
  fi
  echo "$RECORD_ID"
}

# Update record
update_record() {
  local ZONE_ID=$1
  local RECORD_ID=$2
  local ZONE_NAME=$3
  local RECORD_NAME=$4
  local IP_ADDRESS=$5

  log "INFO: Attempting to update record '$RECORD_NAME' to $IP_ADDRESS in zone '$ZONE_NAME'."

  local RR_NAME RR_TYPE RESPONSE
  RR_NAME=$(echo "$RECORD_ID" | cut -d'/' -f1)
  RR_TYPE=$(echo "$RECORD_ID" | cut -d'/' -f2)

  RESPONSE=$(curl -s -X POST \
    -H "Authorization: Bearer $HETZNER_CLOUD_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
          "records": [
            { "value": "'"$IP_ADDRESS"'" }
          ]
        }' \
    "https://api.hetzner.cloud/v1/zones/$ZONE_ID/rrsets/$RR_NAME/$RR_TYPE/actions/set_records")

  if echo "$RESPONSE" | grep -q '"action"'; then
    local ACTION_STATUS
    ACTION_STATUS=$(echo "$RESPONSE" | jq -r '.action.status')
    if [ "$ACTION_STATUS" == "running" ] || [ "$ACTION_STATUS" == "success" ]; then
      log "INFO: DNS entry for $RECORD_NAME successfully updated to $IP_ADDRESS. Action Status: $ACTION_STATUS"
      return 0
    else
      log "ERROR: DNS update action failed for '$RECORD_NAME'. Response: $RESPONSE"
      return 1
    fi
  else
    log "ERROR: Failed to update DNS record '$RECORD_NAME'. Unexpected API response: $RESPONSE"
    return 1
  fi
}

# Collect configured domains from numbered environment variables
DOMAIN_ZONE_NAMES=()
DOMAIN_RECORD_NAMES=()
DOMAIN_ZONE_IDS=()
DOMAIN_RECORD_IDS=()
DOMAIN_LAST_IPS=()

for ((i = 1; i <= MAX_DOMAIN_SLOTS; i++)); do
  ZONE_VAR="HETZNER_DNS_ZONE_NAME_$i"
  RECORD_VAR="HETZNER_DNS_RECORD_NAME_$i"
  ZONE_NAME="${!ZONE_VAR}"
  RECORD_NAME="${!RECORD_VAR}"

  # Skip empty slots
  if [ -z "$ZONE_NAME" ] && [ -z "$RECORD_NAME" ]; then
    continue
  fi

  if [ -z "$ZONE_NAME" ] || [ -z "$RECORD_NAME" ]; then
    log "ERROR: Slot $i is incomplete (needs both $ZONE_VAR and $RECORD_VAR). Skipping."
    continue
  fi

  ZONE_ID=$(get_zone_id "$ZONE_NAME")
  if [ $? -ne 0 ]; then
    log "ERROR: Skipping domain '$RECORD_NAME.$ZONE_NAME' (slot $i) due to zone lookup failure."
    continue
  fi

  RECORD_ID=$(get_record_id "$ZONE_ID" "$ZONE_NAME" "$RECORD_NAME")
  if [ $? -ne 0 ]; then
    log "ERROR: Skipping domain '$RECORD_NAME.$ZONE_NAME' (slot $i) due to record lookup failure."
    continue
  fi

  DOMAIN_ZONE_NAMES+=("$ZONE_NAME")
  DOMAIN_RECORD_NAMES+=("$RECORD_NAME")
  DOMAIN_ZONE_IDS+=("$ZONE_ID")
  DOMAIN_RECORD_IDS+=("$RECORD_ID")
  DOMAIN_LAST_IPS+=("")

  log "INFO: Configured domain '$RECORD_NAME.$ZONE_NAME' (slot $i, zone id $ZONE_ID)."
done

if [ ${#DOMAIN_ZONE_NAMES[@]} -eq 0 ]; then
  log "ERROR: No usable domains configured. Please set HETZNER_DNS_ZONE_NAME_1 / HETZNER_DNS_RECORD_NAME_1 (and _2, _3, ... as needed)."
  exit 1
fi

log "Hetzner Dynamic DNS Updater started."
log "Check interval: $CHECK_INTERVAL_SECONDS Seconds."
log "Managing ${#DOMAIN_ZONE_NAMES[@]} domain(s)."

while true; do
  PUBLIC_IP=$(curl -s https://ipv4.icanhazip.com)

  if [ -z "$PUBLIC_IP" ]; then
    log "WARNING: Could not determine public IP address. Retrying."
  else
    for i in "${!DOMAIN_ZONE_NAMES[@]}"; do
      if [ "$PUBLIC_IP" != "${DOMAIN_LAST_IPS[$i]}" ]; then
        log "INFO: Public IP for '${DOMAIN_RECORD_NAMES[$i]}.${DOMAIN_ZONE_NAMES[$i]}' has changed from '${DOMAIN_LAST_IPS[$i]}' to $PUBLIC_IP."
        if update_record "${DOMAIN_ZONE_IDS[$i]}" "${DOMAIN_RECORD_IDS[$i]}" "${DOMAIN_ZONE_NAMES[$i]}" "${DOMAIN_RECORD_NAMES[$i]}" "$PUBLIC_IP"; then
          DOMAIN_LAST_IPS[$i]="$PUBLIC_IP"
        else
          log "ERROR: Failed to update '${DOMAIN_RECORD_NAMES[$i]}.${DOMAIN_ZONE_NAMES[$i]}'. Will retry at the next interval."
        fi
      fi
    done
  fi

  sleep "$CHECK_INTERVAL_SECONDS"
done
