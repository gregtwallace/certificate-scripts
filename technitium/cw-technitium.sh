#!/usr/bin/env bash
#
#.   CAUTION: This Script is delivered on an as-is basis!
#    Author: Nodework Automation (by Justin Ritter)
#    Website: https://nodework.de
#    For questions or help please create an issue or ask via website!
#
# Cert Warden -> Technitium DNS Server certificate rollout
#
# This script is intended for periodic cron execution. It downloads the current
# valid certificate and private key from Cert Warden, validates both, builds a
# PKCS#12/PFX bundle for Technitium, deploys it atomically when changed, checks
# the Technitium API configuration, and restarts the service only when needed.
#
# Official references:
# - Cert Warden API downloads:
#   https://www.certwarden.com/docs/using_certificates/api_calls/
# - Technitium DNS Server settings API / PFX certificate settings:
#   https://github.com/TechnitiumSoftware/DnsServer/blob/master/APIDOCS.md
#
# Recommended installation:
#   install -o root -g root -m 0750 cw-technitium.sh /opt/certwarden/cw-technitium.sh
#   install -o root -g root -m 0600 technitium.env /etc/certwarden/technitium.env
#
# Recommended cron:
#   @reboot sleep 60 && /opt/certwarden/cw-technitium.sh
#   17 3 * * * /opt/certwarden/cw-technitium.sh
#
# PLEASE SEE THE REQUIRED ENV FILE!!!!!!!
#

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_NAME="$(basename "$0")"

CONFIG_FILE="${CONFIG_FILE:-/etc/certwarden/technitium.env}"

CERTWARDEN_BASE_URL="${CERTWARDEN_BASE_URL:-}"
CERTWARDEN_CERT_NAME="${CERTWARDEN_CERT_NAME:-}"
CERTWARDEN_CERT_API_KEY="${CERTWARDEN_CERT_API_KEY:-}"
CERTWARDEN_KEY_API_KEY="${CERTWARDEN_KEY_API_KEY:-}"
CERTWARDEN_ALLOW_INSECURE_TLS="${CERTWARDEN_ALLOW_INSECURE_TLS:-false}"

TECHNITIUM_API_URL="${TECHNITIUM_API_URL:-http://127.0.0.1:5380}"
TECHNITIUM_API_TOKEN="${TECHNITIUM_API_TOKEN:-}"
TECHNITIUM_API_ALLOW_INSECURE_TLS="${TECHNITIUM_API_ALLOW_INSECURE_TLS:-false}"
TECHNITIUM_AUTO_CONFIGURE="${TECHNITIUM_AUTO_CONFIGURE:-true}"
TECHNITIUM_REQUIRE_API="${TECHNITIUM_REQUIRE_API:-true}"
TECHNITIUM_SERVICE="${TECHNITIUM_SERVICE:-auto}"
TECHNITIUM_TLS_TARGETS="${TECHNITIUM_TLS_TARGETS:-web,dns}"
TECHNITIUM_PFX_PATH="${TECHNITIUM_PFX_PATH:-/etc/dns/certwarden/technitium.pfx}"
TECHNITIUM_PFX_PASSWORD="${TECHNITIUM_PFX_PASSWORD:-}"
TECHNITIUM_CERT_OWNER="${TECHNITIUM_CERT_OWNER:-dns-server:dns-server}"
TECHNITIUM_CERT_DIR_MODE="${TECHNITIUM_CERT_DIR_MODE:-0750}"
TECHNITIUM_PFX_MODE="${TECHNITIUM_PFX_MODE:-0640}"

CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-15}"
CURL_MAX_TIME="${CURL_MAX_TIME:-60}"
CURL_RETRIES="${CURL_RETRIES:-2}"
CURL_RETRY_DELAY="${CURL_RETRY_DELAY:-5}"

MIN_VALID_DAYS="${MIN_VALID_DAYS:-3}"
WARN_VALID_DAYS="${WARN_VALID_DAYS:-14}"
POST_RESTART_HEALTH_TIMEOUT="${POST_RESTART_HEALTH_TIMEOUT:-45}"

RUNTIME_DIR="${RUNTIME_DIR:-/run/certwarden-technitium}"
STATE_DIR="${STATE_DIR:-/var/lib/certwarden-technitium}"
LOG_FILE="${LOG_FILE:-/var/log/certwarden-technitium.log}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/state.env}"
LOCK_DIR="${LOCK_DIR:-$RUNTIME_DIR/lock}"

DRY_RUN=false
FORCE_RESTART=false

TMP_DIR=""
LOCK_HELD=false
BACKUP_PFX=""
STATE_WRITTEN=false
CERT_FINGERPRINT=""
CERT_SUBJECT=""
CERT_NOT_AFTER=""
CHANGE_REASON=""

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [--dry-run] [--force-restart] [--help]

Options:
  --dry-run        Download, validate and check config, but do not write files or restart.
  --force-restart  Restart Technitium even when the deployed certificate did not change.
  --help           Show this help text.

Configuration is loaded from CONFIG_FILE, default:
  /etc/certwarden/technitium.env
EOF
}

for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=true
            ;;
        --force-restart)
            FORCE_RESTART=true
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "UNKNOWN: unsupported argument: $arg" >&2
            usage >&2
            exit 10
            ;;
    esac
done

if [[ -r "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

log() {
    local level="$1"
    local message="$2"
    local ts

    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '[%s] %-7s %s\n' "$ts" "$level" "$message" | tee -a "$LOG_FILE" >&2

    if command -v logger >/dev/null 2>&1; then
        logger -t certwarden-technitium -- "$level: $message" || true
    fi
}

write_state() {
    local status="$1"
    local exit_code="$2"
    local message="$3"
    local changed="${4:-false}"
    local tmp_state

    mkdir -p "$STATE_DIR"
    tmp_state="$STATE_FILE.tmp.$$"

    {
        printf 'last_run_epoch=%s\n' "$(date '+%s')"
        printf 'last_run_iso=%q\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
        printf 'status=%q\n' "$status"
        printf 'exit_code=%q\n' "$exit_code"
        printf 'message=%q\n' "$message"
        printf 'changed=%q\n' "$changed"
        printf 'cert_name=%q\n' "${CERTWARDEN_CERT_NAME:-}"
        printf 'cert_fingerprint_sha256=%q\n' "$CERT_FINGERPRINT"
        printf 'cert_subject=%q\n' "$CERT_SUBJECT"
        printf 'cert_not_after=%q\n' "$CERT_NOT_AFTER"
        printf 'technitium_service=%q\n' "${TECHNITIUM_SERVICE:-}"
        printf 'technitium_pfx_path=%q\n' "${TECHNITIUM_PFX_PATH:-}"
        printf 'change_reason=%q\n' "$CHANGE_REASON"
    } > "$tmp_state"

    chmod 0640 "$tmp_state" || true
    mv -f "$tmp_state" "$STATE_FILE"
    STATE_WRITTEN=true
}

finish_ok() {
    local message="$1"
    local changed="${2:-false}"

    log "OK" "$message"
    write_state "OK" 0 "$message" "$changed"
    printf 'OK: %s\n' "$message"
    exit 0
}

die() {
    local exit_code="$1"
    local message="$2"

    set +e
    log "ERROR" "$message"
    write_state "CRITICAL" "$exit_code" "$message" "false"
    printf 'CRITICAL: %s\n' "$message"
    exit "$exit_code"
}

cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi

    if [[ "$LOCK_HELD" == true && -d "$LOCK_DIR" ]]; then
        rm -rf "$LOCK_DIR"
    fi
}

on_exit() {
    local rc=$?

    set +e
    cleanup

    if [[ "$rc" != "0" && "$STATE_WRITTEN" != true ]]; then
        log "ERROR" "Unexpected script exit with code $rc"
        write_state "CRITICAL" "$rc" "Unexpected script exit with code $rc" "false"
        printf 'CRITICAL: Unexpected script exit with code %s\n' "$rc"
    fi

    trap - EXIT
    exit "$rc"
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

bool_true() {
    local value

    value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

    case "$value" in
        true|yes|y|1|on)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

require_var() {
    local name="$1"
    local value="${!name:-}"

    if [[ -z "$value" || "$value" == "replace-me" || "$value" == "replace-with-a-local-pfx-password" ]]; then
        die 10 "Required configuration variable $name is missing or still a placeholder"
    fi
}

require_command() {
    local cmd="$1"

    command -v "$cmd" >/dev/null 2>&1 || die 20 "Required command not found: $cmd"
}

group_exists() {
    local group="$1"

    if command -v getent >/dev/null 2>&1; then
        getent group "$group" >/dev/null 2>&1
        return $?
    fi

    if command -v dscl >/dev/null 2>&1; then
        dscl . -read "/Groups/$group" >/dev/null 2>&1
        return $?
    fi

    grep -q "^${group}:" /etc/group 2>/dev/null
}

urlencode() {
    local input="$1"
    local length="${#input}"
    local encoded=""
    local pos char

    LC_ALL=C
    for ((pos = 0; pos < length; pos++)); do
        char="${input:pos:1}"
        case "$char" in
            [a-zA-Z0-9.~_-])
                encoded+="$char"
                ;;
            *)
                printf -v char '%%%02X' "'$char"
                encoded+="$char"
                ;;
        esac
    done

    printf '%s' "$encoded"
}

init_paths() {
    mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR" "$RUNTIME_DIR"
    touch "$LOG_FILE"
    chmod 0640 "$LOG_FILE" || true
}

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        LOCK_HELD=true
        printf '%s\n' "$$" > "$LOCK_DIR/pid"
        return 0
    fi

    if [[ -r "$LOCK_DIR/pid" ]]; then
        die 75 "Another instance is already running with PID $(<"$LOCK_DIR/pid")"
    fi

    die 75 "Another instance is already running"
}

validate_config() {
    require_var CERTWARDEN_BASE_URL
    require_var CERTWARDEN_CERT_NAME
    require_var CERTWARDEN_CERT_API_KEY
    require_var CERTWARDEN_KEY_API_KEY
    require_var TECHNITIUM_PFX_PATH
    require_var TECHNITIUM_PFX_PASSWORD

    if bool_true "$TECHNITIUM_REQUIRE_API"; then
        require_var TECHNITIUM_API_URL
        require_var TECHNITIUM_API_TOKEN
    fi

    if [[ "$(id -u)" != "0" && "$DRY_RUN" != true ]]; then
        die 10 "This script must run as root unless --dry-run is used"
    fi

    case ",$TECHNITIUM_TLS_TARGETS," in
        *,web,*|*,dns,*)
            ;;
        *)
            die 10 "TECHNITIUM_TLS_TARGETS must contain web, dns, or both"
            ;;
    esac
}

check_dependencies() {
    require_command awk
    require_command basename
    require_command chmod
    require_command chown
    require_command cp
    require_command curl
    require_command date
    require_command dirname
    require_command grep
    require_command head
    require_command id
    require_command install
    require_command mkdir
    require_command mktemp
    require_command mv
    require_command openssl
    require_command rm
    require_command sed
    require_command sleep
    require_command tee
    require_command tr

    if [[ "$TECHNITIUM_SERVICE" != "none" ]]; then
        require_command systemctl
    fi
}

download_from_certwarden() {
    local kind="$1"
    local api_key="$2"
    local output="$3"
    local encoded_name url http_code curl_rc
    local -a curl_args=()

    encoded_name="$(urlencode "$CERTWARDEN_CERT_NAME")"
    url="${CERTWARDEN_BASE_URL%/}/certwarden/api/v1/download/${kind}/${encoded_name}"

    curl_args=(
        --silent
        --show-error
        --location
        --retry "$CURL_RETRIES"
        --retry-delay "$CURL_RETRY_DELAY"
        --connect-timeout "$CURL_CONNECT_TIMEOUT"
        --max-time "$CURL_MAX_TIME"
    )

    if bool_true "$CERTWARDEN_ALLOW_INSECURE_TLS"; then
        curl_args+=("--insecure")
    fi

    set +e
    http_code="$(
        curl "${curl_args[@]}" \
            --header "X-API-Key: ${api_key}" \
            --output "$output" \
            --write-out '%{http_code}' \
            "$url"
    )"
    curl_rc=$?
    set -e

    if ((curl_rc != 0)); then
        die 30 "Failed to download $kind from Cert Warden"
    fi

    if [[ "$http_code" != "200" ]]; then
        die 30 "Cert Warden returned HTTP $http_code for $kind"
    fi

    if [[ ! -s "$output" ]]; then
        die 30 "Cert Warden returned an empty $kind file"
    fi
}

cert_fingerprint() {
    local cert_file="$1"

    openssl x509 -in "$cert_file" -noout -fingerprint -sha256 \
        | sed 's/^sha256 Fingerprint=//;s/^SHA256 Fingerprint=//;s/://g' \
        | tr '[:upper:]' '[:lower:]'
}

pfx_fingerprint() {
    local pfx_file="$1"

    openssl pkcs12 \
        -in "$pfx_file" \
        -nokeys \
        -clcerts \
        -passin "pass:${TECHNITIUM_PFX_PASSWORD}" \
        2>/dev/null \
        | openssl x509 -noout -fingerprint -sha256 2>/dev/null \
        | sed 's/^sha256 Fingerprint=//;s/^SHA256 Fingerprint=//;s/://g' \
        | tr '[:upper:]' '[:lower:]'
}

validate_certificate_material() {
    local cert_file="$1"
    local key_file="$2"
    local cert_pubkey_hash key_pubkey_hash
    local min_valid_seconds warn_valid_seconds

    openssl x509 -in "$cert_file" -noout >/dev/null 2>&1 \
        || die 40 "Downloaded certificate is not a valid X.509 PEM certificate"

    openssl pkey -in "$key_file" -noout >/dev/null 2>&1 \
        || die 40 "Downloaded private key is not a valid PEM private key"

    cert_pubkey_hash="$(
        openssl x509 -in "$cert_file" -pubkey -noout \
            | openssl pkey -pubin -outform DER 2>/dev/null \
            | openssl dgst -sha256 -r \
            | awk '{print $1}'
    )"

    key_pubkey_hash="$(
        openssl pkey -in "$key_file" -pubout -outform DER 2>/dev/null \
            | openssl dgst -sha256 -r \
            | awk '{print $1}'
    )"

    if [[ -z "$cert_pubkey_hash" || -z "$key_pubkey_hash" || "$cert_pubkey_hash" != "$key_pubkey_hash" ]]; then
        die 40 "Downloaded certificate and private key do not match"
    fi

    min_valid_seconds=$((MIN_VALID_DAYS * 86400))
    warn_valid_seconds=$((WARN_VALID_DAYS * 86400))

    if ! openssl x509 -checkend "$min_valid_seconds" -noout -in "$cert_file" >/dev/null 2>&1; then
        die 40 "Downloaded certificate expires within $MIN_VALID_DAYS day(s); refusing deployment"
    fi

    if ! openssl x509 -checkend "$warn_valid_seconds" -noout -in "$cert_file" >/dev/null 2>&1; then
        log "WARNING" "Downloaded certificate expires within $WARN_VALID_DAYS day(s)"
    fi

    CERT_FINGERPRINT="$(cert_fingerprint "$cert_file")"
    CERT_SUBJECT="$(openssl x509 -noout -subject -in "$cert_file" | sed 's/^subject=//')"
    CERT_NOT_AFTER="$(openssl x509 -noout -enddate -in "$cert_file" | sed 's/^notAfter=//')"
}

build_pfx() {
    local cert_file="$1"
    local key_file="$2"
    local pfx_file="$3"

    openssl pkcs12 \
        -export \
        -name "$CERTWARDEN_CERT_NAME" \
        -in "$cert_file" \
        -inkey "$key_file" \
        -out "$pfx_file" \
        -passout "pass:${TECHNITIUM_PFX_PASSWORD}" \
        >/dev/null 2>&1 \
        || die 40 "Failed to build PKCS#12/PFX bundle"

    openssl pkcs12 \
        -in "$pfx_file" \
        -nokeys \
        -clcerts \
        -passin "pass:${TECHNITIUM_PFX_PASSWORD}" \
        >/dev/null 2>&1 \
        || die 40 "Generated PFX cannot be read with TECHNITIUM_PFX_PASSWORD"
}

detect_technitium_service() {
    local svc

    if [[ "$TECHNITIUM_SERVICE" != "auto" ]]; then
        return 0
    fi

    for svc in dns.service technitium.service technitium-dns-server.service; do
        if systemctl list-unit-files "$svc" --no-legend 2>/dev/null | grep -q "^$svc"; then
            TECHNITIUM_SERVICE="$svc"
            return 0
        fi

        if systemctl status "$svc" >/dev/null 2>&1; then
            TECHNITIUM_SERVICE="$svc"
            return 0
        fi
    done

    die 20 "Could not auto-detect Technitium systemd service; set TECHNITIUM_SERVICE"
}

preflight_technitium_service() {
    if [[ "$TECHNITIUM_SERVICE" == "none" ]]; then
        return 0
    fi

    detect_technitium_service

    systemctl cat "$TECHNITIUM_SERVICE" >/dev/null 2>&1 \
        || die 20 "Technitium systemd service was not found: $TECHNITIUM_SERVICE"

    if ! systemctl is-active --quiet "$TECHNITIUM_SERVICE"; then
        log "WARNING" "$TECHNITIUM_SERVICE is not active before rollout; restart will attempt to start it if a change is needed"
    fi
}

prepare_deploy_directory() {
    local cert_dir owner_user owner_group

    cert_dir="$(dirname "$TECHNITIUM_PFX_PATH")"
    owner_user="${TECHNITIUM_CERT_OWNER%%:*}"
    owner_group="${TECHNITIUM_CERT_OWNER#*:}"

    if [[ "$owner_user" == "$TECHNITIUM_CERT_OWNER" || -z "$owner_user" || -z "$owner_group" ]]; then
        die 10 "TECHNITIUM_CERT_OWNER must be in user:group format"
    fi

    if ! id "$owner_user" >/dev/null 2>&1; then
        die 50 "Certificate owner user does not exist: $owner_user"
    fi

    if ! group_exists "$owner_group"; then
        die 50 "Certificate owner group does not exist: $owner_group"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "Dry-run: would prepare $cert_dir for $TECHNITIUM_CERT_OWNER"
        return 0
    fi

    install -d -o "$owner_user" -g "$owner_group" -m "$TECHNITIUM_CERT_DIR_MODE" "$cert_dir" \
        || die 50 "Failed to create certificate directory $cert_dir"
}

deploy_pfx_if_changed() {
    local new_pfx="$1"
    local current_fp=""
    local cert_dir deployed_tmp

    if [[ -s "$TECHNITIUM_PFX_PATH" ]]; then
        set +e
        current_fp="$(pfx_fingerprint "$TECHNITIUM_PFX_PATH")"
        set -e
    fi

    if [[ -n "$current_fp" && "$current_fp" == "$CERT_FINGERPRINT" ]]; then
        if [[ "$FORCE_RESTART" == true ]]; then
            CHANGE_REASON="force restart requested"
            return 2
        fi

        CHANGE_REASON="certificate already deployed"
        return 1
    fi

    if [[ -z "$current_fp" && -e "$TECHNITIUM_PFX_PATH" ]]; then
        CHANGE_REASON="existing PFX could not be read or fingerprinted"
    elif [[ -z "$current_fp" ]]; then
        CHANGE_REASON="no existing PFX deployed"
    else
        CHANGE_REASON="certificate fingerprint changed"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "Dry-run: would deploy PFX to $TECHNITIUM_PFX_PATH ($CHANGE_REASON)"
        return 2
    fi

    cert_dir="$(dirname "$TECHNITIUM_PFX_PATH")"
    deployed_tmp="$cert_dir/.technitium.pfx.$$"

    if [[ -s "$TECHNITIUM_PFX_PATH" ]]; then
        BACKUP_PFX="$TMP_DIR/previous-technitium.pfx"
        cp -p "$TECHNITIUM_PFX_PATH" "$BACKUP_PFX" \
            || die 50 "Failed to create rollback copy of $TECHNITIUM_PFX_PATH"
    fi

    install -o "${TECHNITIUM_CERT_OWNER%%:*}" \
        -g "${TECHNITIUM_CERT_OWNER#*:}" \
        -m "$TECHNITIUM_PFX_MODE" \
        "$new_pfx" \
        "$deployed_tmp" \
        || die 50 "Failed to stage PFX at $deployed_tmp"

    mv -f "$deployed_tmp" "$TECHNITIUM_PFX_PATH" \
        || die 50 "Failed to move PFX into place at $TECHNITIUM_PFX_PATH"

    chown "$TECHNITIUM_CERT_OWNER" "$TECHNITIUM_PFX_PATH" \
        || die 50 "Failed to set owner on $TECHNITIUM_PFX_PATH"

    chmod "$TECHNITIUM_PFX_MODE" "$TECHNITIUM_PFX_PATH" \
        || die 50 "Failed to set permissions on $TECHNITIUM_PFX_PATH"

    return 2
}

technitium_api_get_settings() {
    local output="$1"
    local http_code curl_rc
    local -a curl_args=()

    if [[ -z "$TECHNITIUM_API_TOKEN" ]]; then
        die 60 "TECHNITIUM_API_TOKEN is required for Technitium config checks"
    fi

    curl_args=(
        --silent
        --show-error
        --location
        --connect-timeout "$CURL_CONNECT_TIMEOUT"
        --max-time "$CURL_MAX_TIME"
    )

    if bool_true "$TECHNITIUM_API_ALLOW_INSECURE_TLS"; then
        curl_args+=("--insecure")
    fi

    set +e
    http_code="$(
        curl "${curl_args[@]}" \
            --header "Authorization: Bearer ${TECHNITIUM_API_TOKEN}" \
            --output "$output" \
            --write-out '%{http_code}' \
            "${TECHNITIUM_API_URL%/}/api/settings/get"
    )"
    curl_rc=$?
    set -e

    if ((curl_rc != 0)); then
        die 60 "Failed to query Technitium settings API"
    fi

    if [[ "$http_code" != "200" ]]; then
        die 60 "Technitium settings API returned HTTP $http_code"
    fi

    grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"' "$output" \
        || die 60 "Technitium settings API did not return status=ok"
}

technitium_api_set_cert_config() {
    local output="$1"
    local http_code curl_rc
    local -a curl_args=()
    local -a form_args=()

    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "Dry-run: would update Technitium API certificate settings"
        return 0
    fi

    curl_args=(
        --silent
        --show-error
        --location
        --connect-timeout "$CURL_CONNECT_TIMEOUT"
        --max-time "$CURL_MAX_TIME"
    )

    if bool_true "$TECHNITIUM_API_ALLOW_INSECURE_TLS"; then
        curl_args+=("--insecure")
    fi

    case ",$TECHNITIUM_TLS_TARGETS," in
        *,web,*)
            form_args+=(
                --data-urlencode "webServiceEnableTls=true"
                --data-urlencode "webServiceTlsCertificatePath=${TECHNITIUM_PFX_PATH}"
                --data-urlencode "webServiceTlsCertificatePassword=${TECHNITIUM_PFX_PASSWORD}"
            )
            ;;
    esac

    case ",$TECHNITIUM_TLS_TARGETS," in
        *,dns,*)
            form_args+=(
                --data-urlencode "dnsTlsCertificatePath=${TECHNITIUM_PFX_PATH}"
                --data-urlencode "dnsTlsCertificatePassword=${TECHNITIUM_PFX_PASSWORD}"
            )
            ;;
    esac

    set +e
    http_code="$(
        curl "${curl_args[@]}" \
            --request POST \
            --header "Authorization: Bearer ${TECHNITIUM_API_TOKEN}" \
            --header "Content-Type: application/x-www-form-urlencoded" \
            "${form_args[@]}" \
            --output "$output" \
            --write-out '%{http_code}' \
            "${TECHNITIUM_API_URL%/}/api/settings/set"
    )"
    curl_rc=$?
    set -e

    if ((curl_rc != 0)); then
        die 60 "Failed to update Technitium certificate settings"
    fi

    if [[ "$http_code" != "200" ]]; then
        die 60 "Technitium settings update returned HTTP $http_code"
    fi

    grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"' "$output" \
        || die 60 "Technitium settings update did not return status=ok"
}

json_string_field() {
    local file="$1"
    local field="$2"

    if command -v jq >/dev/null 2>&1; then
        jq -r --arg field "$field" '.response[$field] // ""' "$file"
        return 0
    fi

    sed -nE "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$file" | head -n 1
}

json_bool_field() {
    local file="$1"
    local field="$2"

    if command -v jq >/dev/null 2>&1; then
        jq -r --arg field "$field" '.response[$field] // empty' "$file"
        return 0
    fi

    sed -nE "s/.*\"$field\"[[:space:]]*:[[:space:]]*(true|false).*/\1/p" "$file" | head -n 1
}

technitium_config_needs_update() {
    local settings_file="$1"
    local needs_update=false
    local web_path web_enabled dns_path

    case ",$TECHNITIUM_TLS_TARGETS," in
        *,web,*)
            web_path="$(json_string_field "$settings_file" "webServiceTlsCertificatePath")"
            web_enabled="$(json_bool_field "$settings_file" "webServiceEnableTls")"

            if [[ "$web_path" != "$TECHNITIUM_PFX_PATH" || "$web_enabled" != "true" ]]; then
                needs_update=true
            fi
            ;;
    esac

    case ",$TECHNITIUM_TLS_TARGETS," in
        *,dns,*)
            dns_path="$(json_string_field "$settings_file" "dnsTlsCertificatePath")"

            if [[ "$dns_path" != "$TECHNITIUM_PFX_PATH" ]]; then
                needs_update=true
            fi
            ;;
    esac

    [[ "$needs_update" == true ]]
}

ensure_technitium_config() {
    local cert_changed="$1"
    local settings_file="$TMP_DIR/technitium-settings.json"
    local set_response="$TMP_DIR/technitium-settings-set.json"

    if [[ -z "$TECHNITIUM_API_TOKEN" ]]; then
        if bool_true "$TECHNITIUM_REQUIRE_API"; then
            die 60 "TECHNITIUM_API_TOKEN is required for Technitium config checks"
        fi

        log "WARNING" "Skipping Technitium API config check because TECHNITIUM_API_TOKEN is empty"
        return 1
    fi

    technitium_api_get_settings "$settings_file"

    if technitium_config_needs_update "$settings_file"; then
        if ! bool_true "$TECHNITIUM_AUTO_CONFIGURE"; then
            die 60 "Technitium certificate config does not match $TECHNITIUM_PFX_PATH and TECHNITIUM_AUTO_CONFIGURE=false"
        fi

        log "INFO" "Updating Technitium certificate settings via API"
        technitium_api_set_cert_config "$set_response"
        CHANGE_REASON="${CHANGE_REASON:+$CHANGE_REASON; }Technitium API config updated"
        return 2
    fi

    if [[ "$cert_changed" == true ]] && bool_true "$TECHNITIUM_AUTO_CONFIGURE"; then
        log "INFO" "Refreshing Technitium certificate password/path settings via API"
        technitium_api_set_cert_config "$set_response"
    fi

    log "INFO" "Technitium certificate settings already point to $TECHNITIUM_PFX_PATH"
    return 1
}

restart_technitium() {
    if [[ "$TECHNITIUM_SERVICE" == "none" ]]; then
        log "WARNING" "Skipping service restart because TECHNITIUM_SERVICE=none"
        return 0
    fi

    detect_technitium_service

    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "Dry-run: would restart $TECHNITIUM_SERVICE"
        return 0
    fi

    if systemctl restart "$TECHNITIUM_SERVICE"; then
        return 0
    fi

    if [[ -n "$BACKUP_PFX" && -s "$BACKUP_PFX" ]]; then
        log "ERROR" "Restart failed after deploying new PFX; restoring previous PFX"

        install -o "${TECHNITIUM_CERT_OWNER%%:*}" \
            -g "${TECHNITIUM_CERT_OWNER#*:}" \
            -m "$TECHNITIUM_PFX_MODE" \
            "$BACKUP_PFX" \
            "$TECHNITIUM_PFX_PATH" \
            || die 70 "Failed to restart $TECHNITIUM_SERVICE and failed to restore previous PFX"

        if systemctl restart "$TECHNITIUM_SERVICE"; then
            die 70 "Failed to restart $TECHNITIUM_SERVICE with new certificate; previous PFX was restored"
        fi

        die 70 "Failed to restart $TECHNITIUM_SERVICE and rollback restart also failed"
    fi

    die 70 "Failed to restart $TECHNITIUM_SERVICE"
}

wait_for_technitium_health() {
    local deadline now health_file

    if [[ "$TECHNITIUM_SERVICE" == "none" || "$DRY_RUN" == true ]]; then
        return 0
    fi

    deadline=$(($(date '+%s') + POST_RESTART_HEALTH_TIMEOUT))
    health_file="$TMP_DIR/technitium-health.json"

    while true; do
        if systemctl is-active --quiet "$TECHNITIUM_SERVICE"; then
            if [[ -n "$TECHNITIUM_API_TOKEN" ]]; then
                if technitium_api_get_settings "$health_file" >/dev/null 2>&1; then
                    return 0
                fi
            else
                return 0
            fi
        fi

        now="$(date '+%s')"
        if ((now >= deadline)); then
            die 70 "Technitium did not become healthy within ${POST_RESTART_HEALTH_TIMEOUT}s after restart"
        fi

        sleep 2
    done
}

main() {
    local cert_file key_file pfx_file
    local cert_changed=false
    local config_changed=false

    init_paths
    acquire_lock
    validate_config
    check_dependencies
    preflight_technitium_service

    TMP_DIR="$(mktemp -d "${RUNTIME_DIR%/}/tmp.XXXXXXXX")"

    log "INFO" "Starting Cert Warden -> Technitium certificate check for $CERTWARDEN_CERT_NAME"

    cert_file="$TMP_DIR/cert.pem"
    key_file="$TMP_DIR/key.pem"
    pfx_file="$TMP_DIR/technitium.pfx"

    download_from_certwarden "certificates" "$CERTWARDEN_CERT_API_KEY" "$cert_file"
    download_from_certwarden "privatekeys" "$CERTWARDEN_KEY_API_KEY" "$key_file"
    validate_certificate_material "$cert_file" "$key_file"
    build_pfx "$cert_file" "$key_file" "$pfx_file"

    prepare_deploy_directory

    if deploy_pfx_if_changed "$pfx_file"; then
        :
    else
        case "$?" in
            1)
                cert_changed=false
                ;;
            2)
                cert_changed=true
                ;;
        esac
    fi

    if ensure_technitium_config "$cert_changed"; then
        :
    else
        case "$?" in
            1)
                config_changed=false
                ;;
            2)
                config_changed=true
                ;;
        esac
    fi

    if [[ "$cert_changed" == true || "$config_changed" == true || "$FORCE_RESTART" == true ]]; then
        log "INFO" "Restarting Technitium because ${CHANGE_REASON:-a certificate/config change was detected}"
        restart_technitium
        wait_for_technitium_health

        if [[ "$DRY_RUN" == true ]]; then
            finish_ok "Dry-run completed; rollout would change Technitium certificate; expires: $CERT_NOT_AFTER" "true"
        fi

        if [[ "$TECHNITIUM_SERVICE" == "none" ]]; then
            finish_ok "Technitium certificate deployed; service restart skipped because TECHNITIUM_SERVICE=none; expires: $CERT_NOT_AFTER" "true"
        fi

        finish_ok "Technitium certificate deployed and service restarted; expires: $CERT_NOT_AFTER" "true"
    fi

    finish_ok "Technitium certificate is already up to date; expires: $CERT_NOT_AFTER" "false"
}

main "$@"