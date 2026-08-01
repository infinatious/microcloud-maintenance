#!/usr/bin/env bash
set -uo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo 'Error: run this script with bash, do not source it.' >&2
  return 1
fi

fail() {
  echo "Error: $*" >&2
  exit 1
}

run() {
  "$@" || fail "command failed: $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command '$1' not found in PATH."
}

require_cmd lxc
require_cmd jq
require_cmd python3

mapfile -t PROJECT_OPTIONS < <(
  lxc project list --format csv -c n 2>/dev/null | while IFS= read -r PROJECT_NAME; do
    [[ -n "${PROJECT_NAME}" ]] || continue
    PROJECT_DESCRIPTION="$(lxc project show "${PROJECT_NAME}" 2>/dev/null | awk -F': ' '/^description:/{print $2; exit}')"
    if [[ "${PROJECT_DESCRIPTION}" =~ ^Project[[:space:]]ID:[[:space:]]([0-9]+)$ ]]; then
      printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${PROJECT_NAME}"
    fi
  done
)
(( ${#PROJECT_OPTIONS[@]} > 0 )) || fail 'no projects with project ID metadata were found.'

echo 'Available projects:'
for PROJECT_ENTRY in "${PROJECT_OPTIONS[@]}"; do
  IFS=$'\t' read -r PROJECT_ID PROJECT_NAME <<< "${PROJECT_ENTRY}"
  printf '%2s) %s\n' "${PROJECT_ID}" "${PROJECT_NAME}"
done
read -r -p 'Choose project ID: ' SELECTED_PROJECT_ID
[[ "${SELECTED_PROJECT_ID}" =~ ^[0-9]+$ ]] || fail 'project selection must be numeric.'
PROJECT_NAME="$(awk -F '\t' -v pid="${SELECTED_PROJECT_ID}" '$1 == pid {print $2}' <<< "$(printf '%s\n' "${PROJECT_OPTIONS[@]}")")"
[[ -n "${PROJECT_NAME}" ]] || fail "project ID '${SELECTED_PROJECT_ID}' is not available."
PROJECT_ID="${SELECTED_PROJECT_ID}"

read -r -p 'Environment (p=production, t=test, q=qa, d=dev): ' ENV_CODE
read -r -p 'Five-character service code: ' SERVICE_CODE

[[ -n "${PROJECT_NAME}" ]] || fail 'project name cannot be empty.'
[[ "${SERVICE_CODE}" =~ ^[A-Za-z0-9]{5}$ ]] || fail 'service code must be exactly 5 alphanumeric characters.'

PROFILE_TYPE=''
PROFILE_NAME=''
NETWORK_NAME="${PROJECT_NAME}"

read -r -p 'Profile type to use (linux or win): ' PROFILE_TYPE
case "${PROFILE_TYPE}" in
  linux|Linux|l)
    PROFILE_NAME="${PROJECT_NAME}-linux"
    ;;
  win|Windows|w)
    PROFILE_NAME="${PROJECT_NAME}-win"
    ;;
  *)
    fail 'profile type must be linux or win.'
    ;;
esac

lxc project show "${PROJECT_NAME}" >/dev/null 2>&1 || fail "project '${PROJECT_NAME}' does not exist."
lxc profile show "${PROFILE_NAME}" --project "${PROJECT_NAME}" >/dev/null 2>&1 || fail "profile '${PROFILE_NAME}' does not exist in project '${PROJECT_NAME}'."
PROFILE_SHOW_FILE="$(mktemp)"
cleanup() {
  rm -f "${PROFILE_SHOW_FILE}" "${DESC_FILE}"
}
trap cleanup EXIT
lxc profile show "${PROFILE_NAME}" --project "${PROJECT_NAME}" > "${PROFILE_SHOW_FILE}"

PROFILE_CPU_CORES="$(python3 - "${PROFILE_SHOW_FILE}" <<'PY'
import sys
from pathlib import Path
import yaml
profile_path = Path(sys.argv[1])
with profile_path.open() as f:
    data = yaml.safe_load(f) or {}
config = data.get('config', {}) or {}
print(config.get('limits.cpu', '2'))
PY
)"
PROFILE_RAM_GIB="$(python3 - "${PROFILE_SHOW_FILE}" <<'PY'
import sys
from pathlib import Path
import yaml
profile_path = Path(sys.argv[1])
with profile_path.open() as f:
    data = yaml.safe_load(f) or {}
config = data.get('config', {}) or {}
mem = str(config.get('limits.memory', '4GiB'))
print(mem.replace('GiB', '').replace('G', '').replace('i', '').replace('B', '').strip() or '4')
PY
)"
PROFILE_DISK_GIB="$(python3 - "${PROFILE_SHOW_FILE}" <<'PY'
import sys
from pathlib import Path
import yaml
profile_path = Path(sys.argv[1])
with profile_path.open() as f:
    data = yaml.safe_load(f) or {}
devices = data.get('devices', {}) or {}
root = devices.get('root', {}) or {}
size = str(root.get('size', '20GiB'))
print(size.replace('GiB', '').replace('G', '').replace('i', '').replace('B', '').strip() or '20')
PY
)"

read -r -p "CPU cores [${PROFILE_CPU_CORES}]: " CPU_CORES
CPU_CORES="${CPU_CORES:-${PROFILE_CPU_CORES}}"
read -r -p "RAM (GiB, number only) [${PROFILE_RAM_GIB}]: " RAM_GIB
RAM_GIB="${RAM_GIB:-${PROFILE_RAM_GIB}}"
read -r -p "Boot disk size (GiB, number only) [${PROFILE_DISK_GIB}]: " DISK_GIB
DISK_GIB="${DISK_GIB:-${PROFILE_DISK_GIB}}"

[[ "${CPU_CORES}" =~ ^[0-9]+$ ]] || fail 'CPU cores must be numeric.'
[[ "${RAM_GIB}" =~ ^[0-9]+$ ]] || fail 'RAM must be numeric GiB.'
[[ "${DISK_GIB}" =~ ^[0-9]+$ ]] || fail 'boot disk size must be numeric GiB.'

lxc network show "${NETWORK_NAME}" --project "${PROJECT_NAME}" >/dev/null 2>&1 || fail "network '${NETWORK_NAME}' does not exist in project '${PROJECT_NAME}'."

NETWORK_IPV4_CIDR="$(lxc network get "${NETWORK_NAME}" ipv4.address --project "${PROJECT_NAME}" 2>/dev/null || true)"
[[ -n "${NETWORK_IPV4_CIDR}" ]] || fail "network '${NETWORK_NAME}' does not have an ipv4.address configured."
PROJECT_ID="$(awk -F '[./]' '{print $3}' <<< "${NETWORK_IPV4_CIDR}")"
[[ "${PROJECT_ID}" =~ ^[0-9]+$ ]] || fail "unable to determine project ID from network subnet '${NETWORK_IPV4_CIDR}'."
(( PROJECT_ID >= 1 && PROJECT_ID <= 255 )) || fail 'derived project ID must be between 1 and 255.'

case "${ENV_CODE}" in
  p)
    if (( PROJECT_ID < 10 )); then ENV_PREFIX='prd'; elif (( PROJECT_ID < 100 )); then ENV_PREFIX='pd'; else ENV_PREFIX='p'; fi
    ;;
  t)
    if (( PROJECT_ID < 10 )); then ENV_PREFIX='tst'; elif (( PROJECT_ID < 100 )); then ENV_PREFIX='ts'; else ENV_PREFIX='t'; fi
    ;;
  q)
    if (( PROJECT_ID < 10 )); then ENV_PREFIX='qua'; elif (( PROJECT_ID < 100 )); then ENV_PREFIX='qa'; else ENV_PREFIX='q'; fi
    ;;
  d)
    if (( PROJECT_ID < 10 )); then ENV_PREFIX='dev'; elif (( PROJECT_ID < 100 )); then ENV_PREFIX='dv'; else ENV_PREFIX='d'; fi
    ;;
  *)
    fail 'environment must be p, t, q, or d.'
    ;;
esac

PROJECT_ID_STR="${PROJECT_ID}"

case "${PROFILE_TYPE}" in
  linux|Linux|l)
    mapfile -t IMAGE_ROWS < <(lxc image list --project default --format json | jq -r '.[] | select(((.aliases | map(.name // "") | join(" ")) | test("win"; "i")) | not) | [(.aliases[0].name // "-"), .fingerprint[0:12], .type, .architecture, (.description // "")] | @tsv')
    ;;
  win|Windows|w)
    mapfile -t IMAGE_ROWS < <(lxc image list --project default --format json | jq -r '.[] | select((.aliases | map(.name // "") | join(" ")) | test("win"; "i")) | [(.aliases[0].name // "-"), .fingerprint[0:12], .type, .architecture, (.description // "")] | @tsv')
    ;;
  *)
    fail 'profile type must be linux or win.'
    ;;
esac
(( ${#IMAGE_ROWS[@]} > 0 )) || fail "no matching images found for profile '${PROFILE_NAME}'."

echo 'Available images:'
for i in "${!IMAGE_ROWS[@]}"; do
  IFS=$'\t' read -r alias shortfp imgtype arch desc <<< "${IMAGE_ROWS[$i]}"
  printf '%2d) alias=%s  fp=%s  type=%s  arch=%s  desc=%s\n' "$((i + 1))" "$alias" "$shortfp" "$imgtype" "$arch" "$desc"
done

read -r -p 'Choose image number: ' IMAGE_INDEX
[[ "${IMAGE_INDEX}" =~ ^[0-9]+$ ]] || fail 'image selection must be numeric.'
(( IMAGE_INDEX >= 1 && IMAGE_INDEX <= ${#IMAGE_ROWS[@]} )) || fail 'image selection is out of range.'
SELECTED_ROW="${IMAGE_ROWS[$((IMAGE_INDEX - 1))]}"
SELECTED_ALIAS="$(awk -F '\t' '{print $1}' <<< "${SELECTED_ROW}")"
SELECTED_FP12="$(awk -F '\t' '{print $2}' <<< "${SELECTED_ROW}")"
SELECTED_TYPE="$(awk -F '\t' '{print $3}' <<< "${SELECTED_ROW}")"
SELECTED_FP_FULL="$(lxc image list --project default --format json | jq -r --arg fp "${SELECTED_FP12}" '.[] | select(.fingerprint | startswith($fp)) | .fingerprint' | head -n1)"
[[ -n "${SELECTED_FP_FULL}" ]] || fail 'unable to resolve selected image fingerprint.'

case "${SELECTED_TYPE}" in
  virtual-machine) INSTANCE_TYPE='vs' ;;
  container) INSTANCE_TYPE='ct' ;;
  *) fail "unsupported selected image type '${SELECTED_TYPE}'." ;;
esac

NAME_PREFIX="${ENV_PREFIX}${PROJECT_ID_STR}-${SERVICE_CODE}-${INSTANCE_TYPE}"
mapfile -t EXISTING_MATCHES < <(lxc list --project "${PROJECT_NAME}" --format csv -c n 2>/dev/null | grep -E "^${NAME_PREFIX}[0-9]{2}$" || true)
NEXT_SEQ=1
if (( ${#EXISTING_MATCHES[@]} > 0 )); then
  LAST_SEQ="$(printf '%s\n' "${EXISTING_MATCHES[@]}" | sed -E 's/.*([0-9]{2})$/\1/' | sort -n | tail -n1)"
  NEXT_SEQ=$((10#${LAST_SEQ} + 1))
fi
(( NEXT_SEQ <= 99 )) || fail 'next sequence would exceed 99.'
INSTANCE_NAME="$(printf '%s%02d' "${NAME_PREFIX}" "${NEXT_SEQ}")"

LAUNCH_ARGS=(launch --project "${PROJECT_NAME}" --profile "${PROFILE_NAME}" "${SELECTED_FP_FULL}" "${INSTANCE_NAME}" -c limits.cpu="${CPU_CORES}" -c limits.memory="${RAM_GIB}GiB")
if [[ "${SELECTED_TYPE}" == 'virtual-machine' ]]; then
  LAUNCH_ARGS+=(--vm)
fi
LAUNCH_ARGS+=(-d root,size="${DISK_GIB}GiB")

echo "Creating instance '${INSTANCE_NAME}' from image ${SELECTED_ALIAS} (${SELECTED_FP12})..."
run lxc "${LAUNCH_ARGS[@]}"

echo 'Waiting for IPv4 address...'
INSTANCE_IPV4=''
for _ in $(seq 1 60); do
  INSTANCE_IPV4="$(lxc list "${INSTANCE_NAME}" --project "${PROJECT_NAME}" --format json | jq -r '.[0].state.network.eth0.addresses[]? | select(.family=="inet" and .scope=="global") | .address' | head -n1)"
  if [[ -n "${INSTANCE_IPV4}" && "${INSTANCE_IPV4}" != 'null' ]]; then
    break
  fi
  sleep 2
done
[[ -n "${INSTANCE_IPV4}" && "${INSTANCE_IPV4}" != 'null' ]] || fail 'unable to determine instance IPv4 address after waiting.'

echo "Creating network forward on '${NETWORK_NAME}' to ${INSTANCE_IPV4}..."
run lxc network forward create "${NETWORK_NAME}" --project "${PROJECT_NAME}" --allocate=ipv4 target_address="${INSTANCE_IPV4}"
LISTEN_IPV4="$(lxc network forward list "${NETWORK_NAME}" --project "${PROJECT_NAME}" --format json | jq -r --arg target "${INSTANCE_IPV4}" '.[] | select(.config.target_address == $target) | .listen_address' | tail -n1)"
[[ -n "${LISTEN_IPV4}" && "${LISTEN_IPV4}" != 'null' ]] || fail 'unable to determine allocated forward listen IPv4 address.'

read -r -p 'Description suffix (optional): ' DESCRIPTION_SUFFIX
DESCRIPTION_TEXT="${LISTEN_IPV4} ${SELECTED_ALIAS}"
if [[ -n "${DESCRIPTION_SUFFIX}" ]]; then
  DESCRIPTION_TEXT="${DESCRIPTION_TEXT} ${DESCRIPTION_SUFFIX}"
fi
DESC_FILE="$(mktemp)"
lxc config show "${INSTANCE_NAME}" --project "${PROJECT_NAME}" > "${DESC_FILE}"
python3 - "${DESC_FILE}" "${DESCRIPTION_TEXT}" <<'PY'
import sys
import yaml
path = sys.argv[1]
desc = sys.argv[2]
with open(path) as f:
    data = yaml.safe_load(f) or {}
data['description'] = desc
with open(path, 'w') as f:
    yaml.safe_dump(data, f, sort_keys=False)
PY
bash -c 'lxc config edit "$1" --project "$2" < "$3"' _ "${INSTANCE_NAME}" "${PROJECT_NAME}" "${DESC_FILE}" || fail "unable to update description field for '${INSTANCE_NAME}'."
run lxc config set "${INSTANCE_NAME}" user.network_forward_ipv4="${LISTEN_IPV4}" --project "${PROJECT_NAME}"

echo
echo 'Instance creation complete.'
echo "Name        : ${INSTANCE_NAME}"
echo "Project     : ${PROJECT_NAME}"
echo "Profile     : ${PROFILE_NAME}"
echo "Image       : ${SELECTED_ALIAS} (${SELECTED_FP12})"
echo "Type        : ${INSTANCE_TYPE}"
echo "Subnet      : ${NETWORK_IPV4_CIDR}"
echo "Project ID  : ${PROJECT_ID}"
echo "CPU         : ${CPU_CORES}"
echo "RAM         : ${RAM_GIB}GiB"
echo "Boot disk   : ${DISK_GIB}GiB"
echo "Instance IP : ${INSTANCE_IPV4}"
echo "Forward IP  : ${LISTEN_IPV4}"
echo "Description : ${DESCRIPTION_TEXT}"
