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

read -r -p 'Project name: ' PROJECT_NAME
[[ -n "${PROJECT_NAME}" ]] || fail 'project name cannot be empty.'

NETWORK_NAME="${PROJECT_NAME}"

lxc project show "${PROJECT_NAME}" >/dev/null 2>&1 || fail "project '${PROJECT_NAME}' does not exist."

mapfile -t INSTANCE_ROWS < <(lxc list --project "${PROJECT_NAME}" -c nds4 -f csv 2>/dev/null || true)
(( ${#INSTANCE_ROWS[@]} > 0 )) || fail "no instances found in project '${PROJECT_NAME}'."

echo 'Instances:'
for i in "${!INSTANCE_ROWS[@]}"; do
  IFS=',' read -r NAME DESCRIPTION STATE IPV4 <<< "${INSTANCE_ROWS[$i]}"
  printf '%2d) %-32s state=%-10s ipv4=%-15s desc=%s
' "$((i + 1))" "$NAME" "${STATE:-unknown}" "${IPV4:--}" "${DESCRIPTION:--}"
done

read -r -p 'Enter instance number to delete: ' INSTANCE_INDEX
[[ "${INSTANCE_INDEX}" =~ ^[0-9]+$ ]] || fail 'instance selection must be numeric.'
(( INSTANCE_INDEX >= 1 && INSTANCE_INDEX <= ${#INSTANCE_ROWS[@]} )) || fail 'instance selection is out of range.'

SELECTED_ROW="${INSTANCE_ROWS[$((INSTANCE_INDEX - 1))]}"
IFS=',' read -r INSTANCE_NAME INSTANCE_DESCRIPTION INSTANCE_STATE INSTANCE_IPV4 <<< "${SELECTED_ROW}"
FORWARD_IP="$(lxc config get "${INSTANCE_NAME}" user.network_forward_ipv4 --project "${PROJECT_NAME}" 2>/dev/null || true)"

echo
echo 'Selected instance:'
echo "Name        : ${INSTANCE_NAME}"
echo "State       : ${INSTANCE_STATE:--}"
echo "IPv4        : ${INSTANCE_IPV4:--}"
echo "Description : ${INSTANCE_DESCRIPTION:--}"
if [[ -n "${FORWARD_IP}" ]]; then
  echo "Forward IP  : ${FORWARD_IP}"
fi

read -r -p 'Are you sure you want to stop and delete this instance? Type yes to continue: ' CONFIRM
[[ "${CONFIRM}" == 'yes' ]] || fail 'deletion cancelled.'

echo "Stopping instance '${INSTANCE_NAME}'..."
lxc stop "${INSTANCE_NAME}" --project "${PROJECT_NAME}" >/dev/null 2>&1 || true

echo "Deleting instance '${INSTANCE_NAME}'..."
run lxc delete "${INSTANCE_NAME}" --project "${PROJECT_NAME}"

if [[ -n "${FORWARD_IP}" ]]; then
  echo "Deleting forward '${FORWARD_IP}' on network '${NETWORK_NAME}'..."
  run lxc network forward delete "${NETWORK_NAME}" "${FORWARD_IP}" --project "${PROJECT_NAME}"
else
  echo "No stored forward IP found on instance '${INSTANCE_NAME}', skipping forward deletion."
fi

echo
echo 'Deletion complete.'
echo "Project    : ${PROJECT_NAME}"
echo "Instance   : ${INSTANCE_NAME}"
if [[ -n "${FORWARD_IP}" ]]; then
  echo "Forward IP : ${FORWARD_IP}"
fi
