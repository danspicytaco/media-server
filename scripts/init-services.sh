#!/usr/bin/env bash
# One-shot service initialisation for the media server stack.
# Idempotent: safe to re-run; skips steps that are already configured.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INIT_DIR="${ROOT_DIR}/config/init"
STATE_FILE="${ROOT_DIR}/config/.init-state"

# Parsed as plain KEY=VALUE data rather than sourced as a script — VPN
# secrets and other values can contain shell-special characters ($, `, ",
# etc.), and `source`-ing the file would let them be interpreted as bash
# syntax instead of literal text.
load_env() {
  local env_file="$1"
  [[ -f "${env_file}" ]] || return 0

  while IFS='=' read -r key value || [[ -n "${key}" ]]; do
    [[ -z "${key}" || "${key}" == \#* ]] && continue
    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
      value="${value:1:${#value}-2}"
      value="${value//\\\'/\'}"
      value="${value//\\\\/\\}"
    fi
    export "${key}=${value}"
  done < "${env_file}"
}

dotenv_quote() {
  local value="$1"
  value="${value//'/\'}"
  printf "'%s'" "${value}"
}

set_env_key() {
  local key="$1" value="$2"
  python3 - "${ROOT_DIR}/.env" "${key}" "${value}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
quoted = "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"
lines = path.read_text().splitlines() if path.exists() else []
updated = False
for idx, line in enumerate(lines):
    if line.startswith(key + "="):
        lines[idx] = f"{key}={quoted}"
        updated = True
        break
if not updated:
    lines.append(f"{key}={quoted}")
path.write_text("\n".join(lines) + "\n")
PY
}

load_env "${ROOT_DIR}/.env"

log() { echo "[init] $*" >&2; }
die() { echo "[init] ERROR: $*" >&2; exit 1; }

command -v jq >/dev/null || die "jq is required (installed by the playbook's prerequisites task)"

mark_done() { echo "$1" >> "${STATE_FILE}"; }
is_done() { [[ -f "${STATE_FILE}" ]] && grep -qxF "$1" "${STATE_FILE}"; }

wait_for_http() {
  local url="$1" label="$2" retries="${3:-60}" delay="${4:-5}"
  log "Waiting for ${label} at ${url}..."
  for ((i = 1; i <= retries; i++)); do
    if curl -sf "${url}" >/dev/null 2>&1; then
      log "${label} is ready"
      return 0
    fi
    sleep "${delay}"
  done
  die "${label} did not become ready (${url})"
}

# --- Jellyfin -----------------------------------------------------------------

setup_jellyfin() {
  if is_done "jellyfin"; then
    log "Jellyfin already initialised, skipping"
    return
  fi

  local base="http://127.0.0.1:${JELLYFIN_PORT}"

  # Wait for Jellyfin to serve valid JSON
  log "Waiting for Jellyfin at ${base}/System/Info/Public..."
  local info_json=""
  for ((i = 1; i <= 60; i++)); do
    info_json="$(curl -sf "${base}/System/Info/Public" 2>/dev/null || true)"
    if echo "${info_json}" | jq -e . >/dev/null 2>&1; then
      log "Jellyfin is ready"
      break
    fi
    info_json=""
    sleep 5
  done
  [[ -n "${info_json}" ]] || die "Jellyfin did not become ready"

  local wizard_done
  wizard_done="$(echo "${info_json}" | jq -r '.StartupWizardCompleted')"

  if [[ "${wizard_done}" != "true" ]]; then
    log "Running Jellyfin startup wizard"
    curl -sf "${base}/Startup/FirstUser" >/dev/null
    local startup_user_payload
    startup_user_payload="$(jq -cn --arg name "${JELLYFIN_USERNAME}" --arg password "${JELLYFIN_PASSWORD}" '{Name: $name, Password: $password}')"
    curl -sf -X POST "${base}/Startup/User" \
      -H "Content-Type: application/json" \
      -d "${startup_user_payload}" >/dev/null
    curl -sf -X POST "${base}/Startup/Complete" \
      -H "Content-Type: application/json" \
      -d "{}" >/dev/null
    log "Jellyfin wizard complete"
  fi

  local token=""
  local auth_response
  local auth_payload
  auth_payload="$(jq -cn --arg username "${JELLYFIN_USERNAME}" --arg password "${JELLYFIN_PASSWORD}" '{Username: $username, Pw: $password}')"
  auth_response="$(curl -sf -X POST "${base}/Users/AuthenticateByName" \
    -H "Content-Type: application/json" \
    -H "Authorization: MediaBrowser Client=\"init\", Device=\"init\", DeviceId=\"init-script\", Version=\"1.0.0\"" \
    -d "${auth_payload}" 2>/dev/null || true)"
  token="$(echo "${auth_response}" | jq -r '.AccessToken // empty' || true)"

  [[ -n "${token}" ]] || die "Failed to obtain Jellyfin access token"

  local auth_header="Authorization: MediaBrowser Token=\"${token}\""

  local existing_libs
  existing_libs="$(curl -sf "${base}/Library/VirtualFolders" -H "${auth_header}" || echo "[]")"

  if ! echo "${existing_libs}" | jq -e 'any(.[]; .Name == "Movies")' >/dev/null 2>&1; then
    log "Creating Jellyfin Movies library"
    curl -sf -X POST "${base}/Library/VirtualFolders?name=Movies&collectionType=movies&refreshLibrary=false" \
      -H "${auth_header}" \
      -H "Content-Type: application/json" \
      -d '{"LibraryOptions":{"PathInfos":[{"Path":"/data/media/movies"}],"EnableRealtimeMonitor":true}}' >/dev/null
  fi

  if ! echo "${existing_libs}" | jq -e 'any(.[]; .Name == "TV Shows")' >/dev/null 2>&1; then
    log "Creating Jellyfin TV Shows library"
    curl -sf -X POST "${base}/Library/VirtualFolders?name=TV%20Shows&collectionType=tvshows&refreshLibrary=false" \
      -H "${auth_header}" \
      -H "Content-Type: application/json" \
      -d '{"LibraryOptions":{"PathInfos":[{"Path":"/data/media/tv"}],"EnableRealtimeMonitor":true}}' >/dev/null
  fi

  if [[ -z "${JELLYFIN_API_KEY:-}" ]]; then
    log "Generating Jellyfin API key for Seerr"
    curl -sf -X POST "${base}/Auth/Keys?app=Seerr" \
      -H "${auth_header}" >/dev/null
    local keys_response
    keys_response="$(curl -sf "${base}/Auth/Keys" -H "Authorization: MediaBrowser Token=\"${token}\"" || true)"
    JELLYFIN_API_KEY="$(echo "${keys_response}" | jq -r '[.Items[] | select(.AppName == "Seerr")] | last.AccessToken // empty' || true)"
    [[ -n "${JELLYFIN_API_KEY}" ]] || die "Failed to generate Jellyfin API key"
    set_env_key JELLYFIN_API_KEY "${JELLYFIN_API_KEY}"
  fi

  mark_done "jellyfin"
}

# --- *arr apps ----------------------------------------------------------------

setup_radarr() {
  if is_done "radarr"; then
    log "Radarr already initialised, skipping"
    return
  fi

  local base="http://127.0.0.1:${RADARR_PORT}"
  local config="${INIT_DIR}/radarr.json"
  wait_for_http "${base}/ping" "Radarr"

  curl -sf -X POST "${base}/api/v3/downloadclient" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${RADARR_API_KEY}" \
    -d "$(jq -c '.downloadClient' "${config}")" >/dev/null || true

  curl -sf -X PUT "${base}/api/v3/config/naming/1" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${RADARR_API_KEY}" \
    -d "$(jq -c '.namingConfig' "${config}")" >/dev/null || true

  local existing_roots
  existing_roots="$(curl -sf "${base}/api/v3/rootfolder" -H "X-Api-Key: ${RADARR_API_KEY}" || echo "[]")"
  if ! echo "${existing_roots}" | jq -e 'any(.[]; .path == "/data/media/movies")' >/dev/null 2>&1; then
    curl -sf -X POST "${base}/api/v3/rootfolder" \
      -H "Content-Type: application/json" \
      -H "X-Api-Key: ${RADARR_API_KEY}" \
      -d "$(jq -c '.rootFolder' "${config}")" >/dev/null
  fi

  mark_done "radarr"
}

setup_sonarr() {
  if is_done "sonarr"; then
    log "Sonarr already initialised, skipping"
    return
  fi

  local base="http://127.0.0.1:${SONARR_PORT}"
  local config="${INIT_DIR}/sonarr.json"
  wait_for_http "${base}/ping" "Sonarr"

  curl -sf -X POST "${base}/api/v3/downloadclient" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${SONARR_API_KEY}" \
    -d "$(jq -c '.downloadClient' "${config}")" >/dev/null || true

  curl -sf -X PUT "${base}/api/v3/config/naming/1" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${SONARR_API_KEY}" \
    -d "$(jq -c '.namingConfig' "${config}")" >/dev/null || true

  local existing_roots
  existing_roots="$(curl -sf "${base}/api/v3/rootfolder" -H "X-Api-Key: ${SONARR_API_KEY}" || echo "[]")"
  if ! echo "${existing_roots}" | jq -e 'any(.[]; .path == "/data/media/tv")' >/dev/null 2>&1; then
    curl -sf -X POST "${base}/api/v3/rootfolder" \
      -H "Content-Type: application/json" \
      -H "X-Api-Key: ${SONARR_API_KEY}" \
      -d "$(jq -c '.rootFolder' "${config}")" >/dev/null
  fi

  mark_done "sonarr"
}

setup_prowlarr() {
  if is_done "prowlarr"; then
    log "Prowlarr already initialised, skipping"
    return
  fi

  local base="http://127.0.0.1:${PROWLARR_PORT}"
  local config="${INIT_DIR}/prowlarr.json"
  wait_for_http "${base}/ping" "Prowlarr"

  curl -sf -X POST "${base}/api/v1/applications" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${PROWLARR_API_KEY}" \
    -d "$(jq -c '.radarrApplicationConfig' "${config}")" >/dev/null || true

  curl -sf -X POST "${base}/api/v1/applications" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${PROWLARR_API_KEY}" \
    -d "$(jq -c '.sonarrApplicationConfig' "${config}")" >/dev/null || true

  mark_done "prowlarr"
}

apply_prowlarr_sync_profile() {
  python3 - "${INIT_DIR}/prowlarr.json" <<'PY'
import json
import os
import sys
import urllib.request

with open(sys.argv[1]) as config:
    desired = json.load(config)["syncProfile"]
minimum = desired["minimumSeeders"]
if type(minimum) is not int or minimum < 0:
    raise ValueError("minimumSeeders must be a non-negative integer")

base = f"http://127.0.0.1:{os.environ['PROWLARR_PORT']}/api/v1/"
headers = {"X-Api-Key": os.environ["PROWLARR_API_KEY"], "Content-Type": "application/json"}

def request(path, method="GET", payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=30) as response:
        body = response.read()
        return json.loads(body) if body else None

profiles = [p for p in request("appprofile") if p["name"] == desired["name"]]
if len(profiles) != 1:
    raise ValueError(f"Expected one Prowlarr sync profile named {desired['name']!r}")
profile = profiles[0]
path = f"appprofile/{profile['id']}"
if profile["minimumSeeders"] != minimum:
    profile["minimumSeeders"] = minimum
    request(path, "PUT", profile)
if request(path)["minimumSeeders"] != minimum:
    raise RuntimeError("Prowlarr minimum seeders update did not persist")
sync = request("command", "POST", {"name": "ApplicationIndexerSync", "forceSync": True})
print(f"[init] Prowlarr {profile['name']} minimum seeders: {minimum}; app sync command {sync['id']}")
PY
}

# --- Bazarr (subtitles) -------------------------------------------------------
# Bazarr generates its own API key in config.yaml on first boot, so we boot it,
# read the key back (same pattern as Jellyfin), persist it to .env, then push
# Sonarr/Radarr connections, providers and an English language profile via the
# settings API. Config is applied over the API (not by seeding config.yaml)
# because Bazarr normalises/rewrites config.yaml on every start.

setup_bazarr() {
  if is_done "bazarr"; then
    log "Bazarr already initialised, skipping"
    return
  fi

  local base="http://127.0.0.1:${BAZARR_PORT}"
  local config="${INIT_DIR}/bazarr.json"
  local config_yaml="${ROOT_DIR}/media-management/bazarr/config/config.yaml"

  # Bazarr serves its UI at / without auth by default; API needs the key.
  wait_for_http "${base}/" "Bazarr"

  # Read back the API key Bazarr wrote under the `auth:` block of config.yaml.
  log "Reading Bazarr API key from ${config_yaml}"
  local bazarr_key=""
  for ((i = 1; i <= 30; i++)); do
    if [[ -f "${config_yaml}" ]]; then
      bazarr_key="$(awk '/^auth:/{f=1;next} f&&/^[A-Za-z]/{f=0} f&&/apikey:/{gsub(/["\x27[:space:]]/,"",$2); print $2; exit}' "${config_yaml}")"
      [[ -n "${bazarr_key}" ]] && break
    fi
    sleep 3
  done
  [[ -n "${bazarr_key}" ]] || die "Failed to read Bazarr API key from ${config_yaml}"
  log "Got Bazarr API key"

  # Persist to .env (mirrors JELLYFIN_API_KEY) for visibility / re-use.
  set_env_key BAZARR_API_KEY "${bazarr_key}"

  local hdr="X-API-KEY: ${bazarr_key}"

  # 0. Enable form authentication. Bazarr 1.6.2+ is required: form auth on
  #    <=1.6.1-beta.15 is bypassable on failed logins (GHSA-jcpg-cp8q-738f).
  #    The API-key path used below keeps working with auth enabled.
  log "Enabling Bazarr form authentication"
  local auth_result
  auth_result="$(curl -s -X POST "${base}/api/system/settings" -H "${hdr}" \
    --data-urlencode "settings-auth-authentication_type=form" \
    --data-urlencode "settings-auth-username=${BAZARR_USERNAME}" \
    --data-urlencode "settings-auth-password=${BAZARR_PASSWORD}" \
    2>&1 || true)"
  log "Bazarr authentication enabled"

  # Purge existing backup archives: they contain the cleartext API key, and
  # an unauthenticated reader (or SSRF route) turning one into postprocessing
  # command execution is the documented RCE chain. Bazarr regenerates them on
  # a weekly schedule with auth now enabled, but stale pre-auth zips are purged
  # here so none survive from the no-auth era.
  if [[ -d "${ROOT_DIR}/media-management/bazarr/backup" ]]; then
    find "${ROOT_DIR}/media-management/bazarr/backup" -name "*.zip" -delete
    log "Purged existing Bazarr backup archives"
  fi

  # 1. Sonarr + Radarr connections and enabled providers. The settings endpoint
  #    is form-encoded (settings-<section>-<key>); list fields are repeated.
  log "Configuring Bazarr connections + providers"
  local conn_result
  conn_result="$(curl -s -X POST "${base}/api/system/settings" -H "${hdr}" \
    --data-urlencode "settings-general-use_sonarr=true" \
    --data-urlencode "settings-general-use_radarr=true" \
    --data-urlencode "settings-general-enabled_providers=$(jq -r '.enabledProviders[0]' "${config}")" \
    --data-urlencode "settings-general-enabled_providers=$(jq -r '.enabledProviders[1]' "${config}")" \
    --data-urlencode "settings-sonarr-ip=$(jq -r '.sonarr.ip' "${config}")" \
    --data-urlencode "settings-sonarr-port=$(jq -r '.sonarr.port' "${config}")" \
    --data-urlencode "settings-sonarr-base_url=$(jq -r '.sonarr.base_url' "${config}")" \
    --data-urlencode "settings-sonarr-ssl=$(jq -r '.sonarr.ssl' "${config}")" \
    --data-urlencode "settings-sonarr-apikey=${SONARR_API_KEY}" \
    --data-urlencode "settings-radarr-ip=$(jq -r '.radarr.ip' "${config}")" \
    --data-urlencode "settings-radarr-port=$(jq -r '.radarr.port' "${config}")" \
    --data-urlencode "settings-radarr-base_url=$(jq -r '.radarr.base_url' "${config}")" \
    --data-urlencode "settings-radarr-ssl=$(jq -r '.radarr.ssl' "${config}")" \
    --data-urlencode "settings-radarr-apikey=${RADARR_API_KEY}" \
    2>&1 || true)"
  log "Connections configured"

  # 2. Enable English, create the English language profile, set it as the
  #    series + movie default. Profiles are one JSON-string field.
  log "Configuring Bazarr English language profile"
  local prof_result
  prof_result="$(curl -s -X POST "${base}/api/system/settings" -H "${hdr}" \
    --data-urlencode "languages-enabled=$(jq -r '.languagesEnabled[0]' "${config}")" \
    --data-urlencode "languages-profiles=$(jq -c '[.languageProfile]' "${config}")" \
    --data-urlencode "settings-general-serie_default_enabled=true" \
    --data-urlencode "settings-general-serie_default_profile=$(jq -r '.languageProfile.profileId' "${config}")" \
    --data-urlencode "settings-general-movie_default_enabled=true" \
    --data-urlencode "settings-general-movie_default_profile=$(jq -r '.languageProfile.profileId' "${config}")" \
    2>&1 || true)"
  log "Profile configured"

  # 3. Kick an immediate library sync + missing-subtitle search so subtitles
  #    start downloading on first deploy instead of waiting for the scheduled
  #    tasks (task ids from GET /api/system/tasks).
  log "Triggering Bazarr sync + subtitle search"
  local task
  for task in update_series update_movies \
              wanted_search_missing_subtitles_series wanted_search_missing_subtitles_movies; do
    curl -s -X POST "${base}/api/system/tasks" -H "${hdr}" \
      --data-urlencode "taskid=${task}" >/dev/null 2>&1 || true
  done

  mark_done "bazarr"
  log "Bazarr initialisation complete"
}

# --- Quality profiles (codec/streaming policy) --------------------------------
# Creates named, Seerr-selectable quality profiles that bake in a set of
# "blocked" custom formats (scored -10000 with minFormatScore=0, so matching
# releases are never grabbed). e.g. "Chromecast 2018" blocks HEVC, DTS/TrueHD,
# 4K and interlaced/raw captures, so picking it in Seerr keeps a grab H.264
# <=1080p and direct-playable without transcoding. Other profiles (including the
# Seerr default) are left unrestricted — you opt in by selecting a managed
# profile per request.
#
# Runs every time (no is_done guard) as a reconciler: each managed profile is
# created by cloning its `cloneFrom` base if missing, its block formats scored
# -10000; managed custom formats are reset to 0 in every non-managed profile so
# a previous policy leaves no residue. Emptying `qualityProfiles` disables it.

apply_quality_profiles() {
  local app="$1" base="$2" api_key="$3" config_file="$4"

  wait_for_http "${base}/ping" "${app}"

  local managed_cfs managed_cf_names profiles_cfg managed_profile_names
  managed_cfs="$(jq -c '.customFormats' "${config_file}")"
  managed_cf_names="$(echo "${managed_cfs}" | jq -c '[.[].name]')"
  profiles_cfg="$(jq -c '.qualityProfiles' "${config_file}")"
  managed_profile_names="$(echo "${profiles_cfg}" | jq -r 'map(.name) | join(", ")')"
  log "${app}: ensuring quality profiles [${managed_profile_names}]"

  # 1. Ensure every managed custom format exists.
  local existing_cfs cf name id
  existing_cfs="$(curl -sf "${base}/api/v3/customformat" -H "X-Api-Key: ${api_key}" || echo "[]")"
  while IFS= read -r cf; do
    [[ -n "${cf}" ]] || continue
    name="$(echo "${cf}" | jq -r '.name')"
    id="$(echo "${existing_cfs}" | jq -r --arg n "${name}" '[.[] | select(.name == $n)] | first.id // empty')"
    if [[ -z "${id}" ]]; then
      log "${app}: creating custom format '${name}'"
      curl -sf -X POST "${base}/api/v3/customformat" \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: ${api_key}" \
        -d "${cf}" >/dev/null || die "Failed to create ${app} custom format '${name}'"
    fi
  done < <(echo "${managed_cfs}" | jq -c '.[]')

  # Resolve managed custom-format ids: a name->id map and a flat id list.
  existing_cfs="$(curl -sf "${base}/api/v3/customformat" -H "X-Api-Key: ${api_key}" || echo "[]")"
  local cf_id_by_name managed_cf_ids
  cf_id_by_name="$(echo "${existing_cfs}" | jq -c 'map({key: .name, value: .id}) | from_entries')"
  managed_cf_ids="$(echo "${existing_cfs}" | jq -c --argjson names "${managed_cf_names}" '[.[] | select(.name as $n | $names | index($n)) | .id]')"

  # 2. Ensure each managed quality profile exists, cloning its base if missing.
  #    Scores are set in step 3, so creation just clones + renames.
  local all_profiles prof pname clone_from base_profile new_profile
  while IFS= read -r prof; do
    [[ -n "${prof}" ]] || continue
    pname="$(echo "${prof}" | jq -r '.name')"
    all_profiles="$(curl -sf "${base}/api/v3/qualityprofile" -H "X-Api-Key: ${api_key}" || echo "[]")"
    if echo "${all_profiles}" | jq -e --arg n "${pname}" 'any(.[]; .name == $n)' >/dev/null; then
      continue
    fi
    clone_from="$(echo "${prof}" | jq -r '.cloneFrom')"
    base_profile="$(echo "${all_profiles}" | jq -c --arg n "${clone_from}" 'map(select(.name == $n)) | first // empty')"
    [[ -n "${base_profile}" ]] || die "${app}: cannot create '${pname}' — base profile '${clone_from}' not found"
    log "${app}: creating quality profile '${pname}' (cloned from '${clone_from}')"
    new_profile="$(echo "${base_profile}" | jq -c --arg n "${pname}" 'del(.id) | .name = $n')"
    curl -sf -X POST "${base}/api/v3/qualityprofile" \
      -H "Content-Type: application/json" \
      -H "X-Api-Key: ${api_key}" \
      -d "${new_profile}" >/dev/null || die "Failed to create ${app} quality profile '${pname}'"
  done < <(echo "${profiles_cfg}" | jq -c '.[]')

  # 3. Reconcile scores everywhere. A managed profile scores its own block set
  #    -10000 (other managed formats 0); every other profile resets all managed
  #    formats to 0, so an earlier policy leaves no residue.
  local block_map updated_profiles profile profile_id
  block_map="$(jq -c --argjson ids "${cf_id_by_name}" \
    '.qualityProfiles | map({key: .name, value: [.blockFormats[] | $ids[.] // empty]}) | from_entries' "${config_file}")"

  updated_profiles="$(curl -sf "${base}/api/v3/qualityprofile" -H "X-Api-Key: ${api_key}" \
    | jq -c --argjson blockMap "${block_map}" --argjson managed "${managed_cf_ids}" \
        '.[]
         | ($blockMap[.name] // []) as $block
         | .formatItems |= map(
             if   (.format as $f | $block   | index($f)) then .score = -10000
             elif (.format as $f | $managed | index($f)) then .score = 0
             else . end)
         | .minFormatScore = 0')"

  while IFS= read -r profile; do
    [[ -n "${profile}" ]] || continue
    profile_id="$(echo "${profile}" | jq -r '.id')"
    curl -sf -X PUT "${base}/api/v3/qualityprofile/${profile_id}" \
      -H "Content-Type: application/json" \
      -H "X-Api-Key: ${api_key}" \
      -d "${profile}" >/dev/null
  done <<< "${updated_profiles}"

  log "${app}: quality profiles applied"
}

# --- Seerr --------------------------------------------------------------------

setup_seerr() {
  if is_done "seerr"; then
    log "Seerr already initialised, skipping"
    return
  fi

  # Reload .env in case Jellyfin step appended JELLYFIN_API_KEY.
  load_env "${ROOT_DIR}/.env"

  # Recover a missing JELLYFIN_API_KEY: the config-tag re-template of .env can
  # render it empty (the playbook fact is only set during the init-tag run of
  # setup_jellyfin), so authenticate and generate one the same way that step
  # does instead of failing.
  if [[ -z "${JELLYFIN_API_KEY:-}" ]]; then
    log "JELLYFIN_API_KEY empty — regenerating via Jellyfin"
    local jf_base="http://127.0.0.1:${JELLYFIN_PORT}"
    local jf_token jf_auth_response jf_keys_response
    jf_auth_response="$(curl -sf -X POST "${jf_base}/Users/AuthenticateByName" \
      -H "Content-Type: application/json" \
      -H "Authorization: MediaBrowser Client=\"init\", Device=\"init\", DeviceId=\"init-script\", Version=\"1.0.0\"" \
      -d "$(jq -cn --arg username "${JELLYFIN_USERNAME}" --arg password "${JELLYFIN_PASSWORD}" '{Username: $username, Pw: $password}')" \
      2>/dev/null || true)"
    jf_token="$(echo "${jf_auth_response}" | jq -r '.AccessToken // empty' || true)"
    [[ -n "${jf_token}" ]] || die "Failed to obtain Jellyfin access token for API key recovery"
    curl -sf -X POST "${jf_base}/Auth/Keys?app=Seerr" -H "Authorization: MediaBrowser Token=\"${jf_token}\"" >/dev/null || true
    jf_keys_response="$(curl -sf "${jf_base}/Auth/Keys" -H "Authorization: MediaBrowser Token=\"${jf_token}\"" || true)"
    JELLYFIN_API_KEY="$(echo "${jf_keys_response}" | jq -r '[.Items[] | select(.AppName == "Seerr")] | last.AccessToken // empty' || true)"
    [[ -n "${JELLYFIN_API_KEY}" ]] || die "Failed to regenerate Jellyfin API key"
    set_env_key JELLYFIN_API_KEY "${JELLYFIN_API_KEY}"
    log "Jellyfin API key regenerated"
  fi

  local base="http://127.0.0.1:${SEERR_PORT}"
  local settings_file="${ROOT_DIR}/seerr/settings.json"
  local init_config="${INIT_DIR}/seerr.json"

  [[ -f "${settings_file}" ]] || die "Seerr settings.json not found at ${settings_file}"

  # Step 1: Stop Seerr, write a bootstrap settings.json with csrfProtection
  # disabled and initialized=false so Seerr runs its DB migrations on next
  # start without overwriting our Jellyfin config.
  #
  # Jellyfin config is cleared so the auth endpoint runs its full first-run
  # path, which both authenticates AND stores connection details in one step.
  # If we pre-set these, Seerr's guard logic returns 500 "Jellyfin login is
  # disabled". mediaServerType 4 = NOT_CONFIGURED, letting the auth endpoint
  # handle first-run setup.
  log "Stopping Seerr to write bootstrap settings"
  docker stop seerr >/dev/null

  local bootstrap_tmp
  bootstrap_tmp="$(mktemp)"
  jq '.jellyfin.ip = ""
      | .jellyfin.apiKey = ""
      | .main.mediaServerType = 4
      | .main.mediaServerLogin = true
      | .network.csrfProtection = false
      | .public.initialized = false' "${settings_file}" > "${bootstrap_tmp}"
  # Overwrite in place (cat, not mv) to preserve the file's owner — Seerr
  # runs as UID 1000 and must be able to write its own settings.
  cat "${bootstrap_tmp}" > "${settings_file}"
  rm -f "${bootstrap_tmp}"
  log "Bootstrap settings written"

  log "Starting Seerr to run DB migrations"
  docker start seerr >/dev/null
  wait_for_http "${base}/api/v1/status" "Seerr"

  # Wait for DB migrations to complete — the status endpoint returns 200 before
  # migrations finish, so hitting auth/jellyfin too early gives a 500.
  log "Waiting for Seerr DB migrations to complete"
  sleep 15

  # Step 2: Authenticate via Jellyfin to create the first admin user record.
  # The endpoint expects "hostname" (not "ip") as the connection field.
  # serverType: 2 = Jellyfin (1=Plex, 2=Jellyfin, 3=Emby, 4=NotConfigured)
  log "Authenticating with Seerr via Jellyfin"
  local auth_response session_cookie
  local seerr_auth_payload
  seerr_auth_payload="$(jq -cn \
    --arg username "${JELLYFIN_USERNAME}" \
    --arg password "${JELLYFIN_PASSWORD}" \
    --arg hostname "jellyfin" \
    --argjson port "${JELLYFIN_PORT}" \
    '{username: $username, password: $password, hostname: $hostname, port: $port, useSsl: false, urlBase: "", serverType: 2}')"
  auth_response="$(curl -si -X POST "${base}/api/v1/auth/jellyfin" \
    -H "Content-Type: application/json" \
    -d "${seerr_auth_payload}" \
    2>/dev/null || true)"
  log "Seerr auth status: $(echo "${auth_response}" | head -1)"
  session_cookie="$(echo "${auth_response}" | tr -d '\r' | grep -i '^set-cookie:' | head -1 | sed 's/[Ss]et-[Cc]ookie: //;s/;.*//' || true)"
  [[ -n "${session_cookie}" ]] || die "Failed to authenticate with Seerr — check Jellyfin credentials and connectivity"

  log "Got Seerr session cookie"

  # Step 3: Push full config via the API now that we have a valid session
  log "Configuring Seerr Jellyfin settings"
  local jellyfin_result
  jellyfin_result="$(curl -s -X POST "${base}/api/v1/settings/jellyfin" \
    -H "Content-Type: application/json" \
    -H "Cookie: ${session_cookie}" \
    -d "$(jq -c --arg key "${JELLYFIN_API_KEY}" \
          '.jellyfinSettings | .apiKey = $key | .hostname //= "jellyfin"' "${init_config}")")"
  log "Jellyfin settings configured"

  log "Configuring Seerr main settings"
  local main_result
  main_result="$(curl -s -X POST "${base}/api/v1/settings/main" \
    -H "Content-Type: application/json" \
    -H "Cookie: ${session_cookie}" \
    -d "$(jq -c '.applicationSettings' "${init_config}")")"
  # The response body includes the global API key — never log it.
  log "Main settings configured"

  log "Configuring Seerr network settings"
  local network_result
  network_result="$(curl -s -X POST "${base}/api/v1/settings/network" \
    -H "Content-Type: application/json" \
    -H "Cookie: ${session_cookie}" \
    -d "$(jq -c '.networkSettings' "${init_config}")")"
  # Same response shape as main settings — never log it.
  log "Network settings configured"

  log "Configuring Seerr Radarr server"
  local radarr_result
  radarr_result="$(curl -s -X POST "${base}/api/v1/settings/radarr" \
    -H "Content-Type: application/json" \
    -H "Cookie: ${session_cookie}" \
    -d "$(jq -c '.radarrServer' "${init_config}")" || true)"
  log "Radarr settings configured"

  log "Configuring Seerr Sonarr server"
  local sonarr_result
  sonarr_result="$(curl -s -X POST "${base}/api/v1/settings/sonarr" \
    -H "Content-Type: application/json" \
    -H "Cookie: ${session_cookie}" \
    -d "$(jq -c '.sonarrServer' "${init_config}")" || true)"
  log "Sonarr settings configured"

  log "Marking Seerr as initialized"
  local init_result
  init_result="$(curl -s -X POST "${base}/api/v1/settings/initialize" \
    -H "Cookie: ${session_cookie}")"
  # The response echoes the settings object including the API key — never log it.
  log "Seerr initialized"

  mark_done "seerr"
  log "Seerr initialisation complete"
}

main() {
  mkdir -p "$(dirname "${STATE_FILE}")"
  touch "${STATE_FILE}"

  setup_jellyfin
  setup_radarr
  setup_sonarr
  setup_prowlarr
  apply_prowlarr_sync_profile
  apply_quality_profiles "radarr" "http://127.0.0.1:${RADARR_PORT}" "${RADARR_API_KEY}" "${INIT_DIR}/radarr.json"
  apply_quality_profiles "sonarr" "http://127.0.0.1:${SONARR_PORT}" "${SONARR_API_KEY}" "${INIT_DIR}/sonarr.json"
  setup_bazarr
  setup_seerr

  log "All services initialised"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
