#!/usr/bin/env bashio
# =============================================================================
# run.sh — EVCC Token Renewal Add-On
# Runs continuously; wakes once per day at the configured check_time to renew
# the EVCC trial sponsor token if it is within the renewal threshold.
# =============================================================================

set -euo pipefail

# ── Read add-on configuration ─────────────────────────────────────────────────
EVCC_YAML="$(bashio::config 'evcc_yaml_path')"
ADDON_SLUG="$(bashio::config 'evcc_addon_slug')"
RENEWAL_THRESHOLD_DAYS="$(bashio::config 'renewal_threshold_days')"
CHECK_TIME="$(bashio::config 'check_time')"   # HH:MM format

RENEWAL_THRESHOLD_SECS=$(( RENEWAL_THRESHOLD_DAYS * 86400 ))
SUPERVISOR_API="http://supervisor"
HA_TOKEN="${SUPERVISOR_TOKEN}"
DOCS_URL="https://docs.evcc.io/docs/sponsorship"

# ── Logging helpers ────────────────────────────────────────────────────────────
log_info()  { bashio::log.info  "$*"; }
log_warn()  { bashio::log.warning "$*"; }
log_error() { bashio::log.error "$*"; }

# ── Seconds until next occurrence of HH:MM ────────────────────────────────────
seconds_until_next() {
    local target="$1"   # "HH:MM"
    local th tm now_secs target_secs diff
    th="${target%%:*}"
    tm="${target##*:}"
    now_secs=$(( $(date +%H) * 3600 + $(date +%M) * 60 + $(date +%S) ))
    target_secs=$(( 10#$th * 3600 + 10#$tm * 60 ))
    diff=$(( target_secs - now_secs ))
    if (( diff <= 0 )); then
        diff=$(( diff + 86400 ))
    fi
    printf '%d' "$diff"
}

# ── Read current sponsortoken from evcc.yaml ──────────────────────────────────
read_current_token() {
    grep -E '^\s*sponsortoken:' "$EVCC_YAML" 2>/dev/null | head -1 \
        | sed 's/^\s*sponsortoken:\s*//' \
        | tr -d '"'"'"'[:space:]'
}

# ── Decode the exp field from a JWT ───────────────────────────────────────────
decode_jwt_exp() {
    local token="$1"
    local payload
    payload="$(printf '%s' "$token" | cut -d'.' -f2)"
    payload="$(printf '%s' "$payload" | tr -- '-_' '+/')"
    local pad=$(( (4 - ${#payload} % 4) % 4 ))
    payload="${payload}$(printf '%0.s=' $(seq 1 $pad))"
    printf '%s' "$payload" | base64 -d 2>/dev/null \
        | python3 -c "import sys, json; print(json.load(sys.stdin).get('exp', ''))"
}

# ── Check if renewal is needed ────────────────────────────────────────────────
check_needs_renewal() {
    local exp="$1"
    local now remaining
    now="$(date +%s)"
    remaining=$(( exp - now ))
    log_info "Token expires in ${remaining}s (threshold: ${RENEWAL_THRESHOLD_SECS}s)"
    (( remaining <= RENEWAL_THRESHOLD_SECS ))
}

# ── Fetch new token from EVCC docs page ───────────────────────────────────────
fetch_new_token() {
    local html token
    html="$(curl -sSL --max-time 30 "$DOCS_URL")" || {
        log_error "Failed to fetch docs page: $DOCS_URL"
        return 1
    }
    token="$(printf '%s' "$html" \
        | grep -oE 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' \
        | head -1)"
    if [[ -z "$token" ]]; then
        log_error "Could not find a JWT token on the docs page"
        return 1
    fi
    printf '%s' "$token"
}

# ── Validate the fetched token has a future expiry ────────────────────────────
validate_token() {
    local token="$1"
    local exp now exp_human
    exp="$(decode_jwt_exp "$token")" || { log_error "Failed to decode fetched token"; return 1; }
    if [[ -z "$exp" ]]; then
        log_error "Fetched token has no exp field"
        return 1
    fi
    now="$(date +%s)"
    if (( exp <= now )); then
        log_error "Fetched token is already expired (exp=$exp)"
        return 1
    fi
    exp_human="$(date -d "@${exp}" -Iseconds 2>/dev/null || date -r "$exp" -Iseconds 2>/dev/null || echo "$exp")"
    log_info "New token valid until ${exp_human}"
}

# ── Write new token to evcc.yaml ──────────────────────────────────────────────
update_evcc_yaml() {
    local new_token="$1"
    if [[ ! -f "$EVCC_YAML" ]]; then
        log_error "evcc.yaml not found at ${EVCC_YAML} — check the evcc_yaml_path option"
        return 1
    fi
    cp "$EVCC_YAML" "${EVCC_YAML}.bak"
    if grep -qE '^\s*sponsortoken:' "$EVCC_YAML"; then
        sed -i "s|^\(\s*sponsortoken:\s*\).*|\1${new_token}|" "$EVCC_YAML"
    else
        printf '\nsponsortoken: %s\n' "$new_token" >> "$EVCC_YAML"
    fi
    local written
    written="$(read_current_token)"
    if [[ "$written" != "$new_token" ]]; then
        log_error "Write verification failed — restoring backup"
        cp "${EVCC_YAML}.bak" "$EVCC_YAML"
        return 1
    fi
    log_info "evcc.yaml updated and verified"
}

# ── Restart the EVCC add-on via Supervisor API ────────────────────────────────
restart_evcc_addon() {
    local resp result
    resp="$(curl -sSL \
        -X POST \
        -H "Authorization: Bearer ${HA_TOKEN}" \
        -H "Content-Type: application/json" \
        "${SUPERVISOR_API}/addons/${ADDON_SLUG}/restart")"
    result="$(printf '%s' "$resp" \
        | python3 -c "import sys, json; print(json.load(sys.stdin).get('result', 'unknown'))" \
        2>/dev/null || echo 'parse_error')"
    if [[ "$result" != "ok" ]]; then
        log_warn "Add-on restart returned unexpected response: ${resp}"
        return 1
    fi
    log_info "EVCC add-on '${ADDON_SLUG}' restarted successfully"
}

# ── Single renewal check ──────────────────────────────────────────────────────
run_check() {
    log_info "=== EVCC token renewal check started ==="

    local current_token
    current_token="$(read_current_token)" || true

    if [[ -n "$current_token" ]]; then
        local exp
        exp="$(decode_jwt_exp "$current_token")" || {
            log_error "Could not decode current token's expiry"
            return 1
        }
        if ! check_needs_renewal "$exp"; then
            log_info "Token is not near expiry — nothing to do"
            return 0
        fi
        log_info "Token is within the renewal window — fetching a new token"
    else
        log_warn "No sponsortoken found in ${EVCC_YAML} — will attempt first-time fetch"
    fi

    local new_token
    new_token="$(fetch_new_token)" || return 1
    validate_token "$new_token" || return 1

    if [[ "$new_token" == "$current_token" ]]; then
        log_info "Fetched token is identical to current token — docs page not yet updated, nothing to do"
        return 0
    fi

    update_evcc_yaml "$new_token" || return 1

    restart_evcc_addon || {
        log_warn "evcc.yaml was updated but the add-on restart failed — please restart EVCC manually"
        return 1
    }

    log_info "=== Renewal complete ==="
}

# ── Main loop ─────────────────────────────────────────────────────────────────
log_info "EVCC Token Renewal add-on started"
log_info "Daily check scheduled at ${CHECK_TIME} | threshold: ${RENEWAL_THRESHOLD_DAYS}d | slug: ${ADDON_SLUG}"
log_info "EVCC config: ${EVCC_YAML}"

while true; do
    secs="$(seconds_until_next "$CHECK_TIME")"
    next="$(date -d "+${secs} seconds" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
           || date -v "+${secs}S" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
           || echo "in ${secs}s")"
    log_info "Next check at ${next} (sleeping ${secs}s)"
    sleep "$secs"
    run_check || log_error "Renewal check failed — will retry at next scheduled time"
done
