#!/usr/bin/env bash
# =============================================================================
# renew_evcc_token.sh
# Checks the EVCC trial sponsor token expiry and renews it from the docs page
# if it expires within 2 days. Restarts the EVCC Home Assistant add-on after
# a successful update.
#
# Deploy to: /config/scripts/renew_evcc_token.sh  (chmod +x)
# Trigger  : Home Assistant shell_command + time automation (see README below)
#
# PRE-REQUISITES (do once on your HA machine):
#   1. Find your EVCC add-on slug:
#        ha addons list | grep -i evcc
#      Then set EVCC_ADDON_SLUG below (or export it before calling the script).
#   2. Create a long-lived HA access token:
#        HA UI → Profile (bottom-left) → Long-Lived Access Tokens → Create Token
#      Save it:
#        echo "YOUR_TOKEN_HERE" > /config/.evcc_ha_token
#        chmod 600 /config/.evcc_ha_token
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
EVCC_YAML="/etc/evcc.yaml"
LOG_FILE="/config/scripts/evcc_token_renewal.log"
DOCS_URL="https://docs.evcc.io/docs/sponsorship"

# EVCC add-on slug — run `ha addons list | grep -i evcc` to find yours.
# Common values: local_evcc  |  c52fd6_evcc  |  a0d7b954_evcc  |  49686a9f_evcc
ADDON_SLUG="${EVCC_ADDON_SLUG:-49686a9f_evcc}"

# Long-lived HA access token (read from file; override with env var if needed)
HA_TOKEN="${HA_TOKEN:-$(cat /config/.evcc_ha_token 2>/dev/null || echo '')}"

# Supervisor API base — the internal proxy available on HA OS / Supervised
SUPERVISOR_API="http://supervisor"

# Renew when less than 2 days remain (172800 seconds)
RENEWAL_THRESHOLD_SECS=172800

# ── Log rotation ──────────────────────────────────────────────────────────────
# Rotate log if it exceeds 100 KB to prevent unbounded growth
if [[ -f "$LOG_FILE" ]] && (( $(wc -c < "$LOG_FILE") > 102400 )); then
    mv "$LOG_FILE" "${LOG_FILE}.old"
fi

# ── Logging helper ─────────────────────────────────────────────────────────────
log() {
    local level="$1"; shift
    printf '%s [%s] %s\n' "$(date -Iseconds)" "$level" "$*" | tee -a "$LOG_FILE"
}

# ── Read current sponsortoken from evcc.yaml ──────────────────────────────────
# Handles both quoted and unquoted YAML values, with any indentation.
read_current_token() {
    grep -E '^\s*sponsortoken:' "$EVCC_YAML" 2>/dev/null | head -1 \
        | sed 's/^\s*sponsortoken:\s*//' \
        | tr -d '"'"'"'[:space:]'
}

# ── Decode the exp field from a JWT (no external libraries needed) ─────────────
# A JWT is: header.payload.signature  (base64url-encoded, dots as separators)
decode_jwt_exp() {
    local token="$1"
    local payload
    # Take the second segment (payload)
    payload="$(printf '%s' "$token" | cut -d'.' -f2)"
    # base64url → base64: replace - with + and _ with /
    payload="$(printf '%s' "$payload" | tr -- '-_' '+/')"
    # Add padding to make the length a multiple of 4
    local pad=$(( (4 - ${#payload} % 4) % 4 ))
    payload="${payload}$(printf '%0.s=' $(seq 1 $pad))"
    # Decode and extract the exp field
    printf '%s' "$payload" | base64 -d 2>/dev/null \
        | python3 -c "import sys, json; print(json.load(sys.stdin).get('exp', ''))"
}

# ── Check if the token is within the renewal window ──────────────────────────
# Returns 0 (true) if renewal is needed, 1 (false) otherwise.
check_needs_renewal() {
    local exp="$1"
    local now; now="$(date +%s)"
    local remaining=$(( exp - now ))
    log "INFO" "Token expires in ${remaining}s (threshold: ${RENEWAL_THRESHOLD_SECS}s)"
    if (( remaining <= RENEWAL_THRESHOLD_SECS )); then
        return 0
    else
        return 1
    fi
}

# ── Fetch new trial token from the EVCC docs page ────────────────────────────
# The token is a JWT (starts with eyJ) embedded in the docs page HTML.
# We match by JWT shape rather than HTML tags for resilience to markup changes.
fetch_new_token() {
    local html
    html="$(curl -sSL --max-time 30 "$DOCS_URL")" || {
        log "ERROR" "Failed to fetch docs page: $DOCS_URL"
        return 1
    }
    local token
    token="$(printf '%s' "$html" \
        | grep -oE 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' \
        | head -1)"
    if [[ -z "$token" ]]; then
        log "ERROR" "Could not find a JWT token on the docs page"
        return 1
    fi
    printf '%s' "$token"
}

# ── Validate the fetched token has a future expiry ────────────────────────────
validate_token() {
    local token="$1"
    local exp
    exp="$(decode_jwt_exp "$token")" || {
        log "ERROR" "Failed to decode fetched token"
        return 1
    }
    if [[ -z "$exp" ]]; then
        log "ERROR" "Fetched token has no exp field"
        return 1
    fi
    local now; now="$(date +%s)"
    if (( exp <= now )); then
        log "ERROR" "Fetched token is already expired (exp=$exp)"
        return 1
    fi
    # Print human-readable expiry (Linux: date -d @N; macOS/BSD: date -r N)
    local exp_human
    exp_human="$(date -d "@${exp}" -Iseconds 2>/dev/null || date -r "$exp" -Iseconds 2>/dev/null || echo "$exp")"
    log "INFO" "New token valid until ${exp_human}"
    return 0
}

# ── Write new token to evcc.yaml ──────────────────────────────────────────────
# Creates a backup first; restores it if the write verification fails.
# If sponsortoken: does not yet exist in the file, it is appended.
update_evcc_yaml() {
    local new_token="$1"
    if [[ ! -f "$EVCC_YAML" ]]; then
        log "ERROR" "evcc.yaml not found at ${EVCC_YAML} — check the EVCC_YAML path in this script"
        return 1
    fi
    cp "$EVCC_YAML" "${EVCC_YAML}.bak"
    if grep -qE '^\s*sponsortoken:' "$EVCC_YAML"; then
        # Line exists — replace it, preserving indentation/whitespace
        sed -i "s|^\(\s*sponsortoken:\s*\).*|\1${new_token}|" "$EVCC_YAML"
    else
        # Line absent — append it at the end of the file
        printf '\nsponsortoken: %s\n' "$new_token" >> "$EVCC_YAML"
    fi
    # Verify the token was written correctly
    local written
    written="$(read_current_token)"
    if [[ "$written" != "$new_token" ]]; then
        log "ERROR" "Write verification failed — restoring backup"
        cp "${EVCC_YAML}.bak" "$EVCC_YAML"
        return 1
    fi
    log "INFO" "evcc.yaml updated and verified"
}

# ── Restart the EVCC add-on via the HA Supervisor API ────────────────────────
restart_evcc_addon() {
    if [[ -z "$HA_TOKEN" ]]; then
        log "ERROR" "HA_TOKEN is empty — cannot call Supervisor API. Check /config/.evcc_ha_token"
        return 1
    fi
    local resp
    resp="$(curl -sSL \
        -X POST \
        -H "Authorization: Bearer ${HA_TOKEN}" \
        -H "Content-Type: application/json" \
        "${SUPERVISOR_API}/addons/${ADDON_SLUG}/restart")"
    local result
    result="$(printf '%s' "$resp" \
        | python3 -c "import sys, json; print(json.load(sys.stdin).get('result', 'unknown'))" \
        2>/dev/null || echo 'parse_error')"
    if [[ "$result" != "ok" ]]; then
        log "WARN" "Add-on restart returned unexpected response: ${resp}"
        return 1
    fi
    log "INFO" "EVCC add-on '${ADDON_SLUG}' restarted successfully"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    log "INFO" "=== EVCC token renewal check started ==="

    # 1. Read the current token from evcc.yaml
    local current_token
    current_token="$(read_current_token)" || true   # empty string is valid (first run)

    if [[ -n "$current_token" ]]; then
        # 2. Decode its expiry
        local exp
        exp="$(decode_jwt_exp "$current_token")" || {
            log "ERROR" "Could not decode current token's expiry"
            exit 1
        }

        # 3. Check if renewal is needed
        if ! check_needs_renewal "$exp"; then
            log "INFO" "Token is not near expiry — nothing to do"
            exit 0
        fi
        log "INFO" "Token is within the renewal window — fetching a new token"
    else
        log "WARN" "No sponsortoken found in ${EVCC_YAML} — will attempt first-time fetch"
    fi

    # 4. Fetch a new token from the docs page
    local new_token
    new_token="$(fetch_new_token)" || exit 1

    # 5. Validate the fetched token
    validate_token "$new_token" || exit 1

    # 6. Idempotency: skip if the docs page still has the same token
    if [[ "$new_token" == "$current_token" ]]; then
        log "INFO" "Fetched token is identical to current token — docs page not yet updated, nothing to do"
        exit 0
    fi

    # 7. Update evcc.yaml
    update_evcc_yaml "$new_token" || exit 1

    # 8. Restart the EVCC add-on
    restart_evcc_addon || {
        log "WARN" "evcc.yaml was updated but the add-on restart failed — please restart EVCC manually"
        exit 1
    }

    log "INFO" "=== Renewal complete ==="
}

main "$@"

# =============================================================================
# DEPLOYMENT README
# =============================================================================
#
# 1. Copy this file to your HA machine:
#      /config/scripts/renew_evcc_token.sh
#    Make it executable:
#      chmod +x /config/scripts/renew_evcc_token.sh
#
# 2. Store your HA long-lived access token:
#      echo "YOUR_LONG_LIVED_TOKEN" > /config/.evcc_ha_token
#      chmod 600 /config/.evcc_ha_token
#    (Generate it in HA: Profile → Long-Lived Access Tokens → Create Token)
#
# 3. Find your EVCC add-on slug and update ADDON_SLUG above:
#      ha addons list | grep -i evcc
#
# 4. Add to /config/configuration.yaml:
#      shell_command:
#        renew_evcc_token: "/bin/bash /config/scripts/renew_evcc_token.sh"
#
# 5. Add to /config/automations.yaml (or import via HA UI):
#      See evcc_renewal_automation.yaml
#
# 6. Test manually from HA terminal:
#      bash /config/scripts/renew_evcc_token.sh
#      cat /config/scripts/evcc_token_renewal.log
# =============================================================================
