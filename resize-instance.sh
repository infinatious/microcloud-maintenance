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
require_cmd python3

mapfile -t PROJECT_OPTIONS < <(
  lxc project list --format csv 2>/dev/null | while IFS=',' read -r PROJECT_NAME _ _ _ _ _ _ PROJECT_DESCRIPTION _; do
    [[ -n "${PROJECT_NAME}" ]] || continue
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

lxc project show "${PROJECT_NAME}" >/dev/null 2>&1 || fail "project '${PROJECT_NAME}' does not exist."

mapfile -t INSTANCE_ROWS < <(lxc list --project "${PROJECT_NAME}" -c nds4t -f csv 2>/dev/null || true)
(( ${#INSTANCE_ROWS[@]} > 0 )) || fail "no instances found in project '${PROJECT_NAME}'."

echo 'Instances:'
for i in "${!INSTANCE_ROWS[@]}"; do
  IFS=',' read -r NAME DESCRIPTION STATE IPV4 TYPE <<< "${INSTANCE_ROWS[$i]}"
  printf '%2d) %-32s type=%-4s state=%-10s ipv4=%-15s desc=%s\n' "$((i + 1))" "$NAME" "${TYPE:--}" "${STATE:-unknown}" "${IPV4:--}" "${DESCRIPTION:--}"
done

read -r -p 'Enter instance number to resize: ' INSTANCE_INDEX
[[ "${INSTANCE_INDEX}" =~ ^[0-9]+$ ]] || fail 'instance selection must be numeric.'
(( INSTANCE_INDEX >= 1 && INSTANCE_INDEX <= ${#INSTANCE_ROWS[@]} )) || fail 'instance selection is out of range.'

SELECTED_ROW="${INSTANCE_ROWS[$((INSTANCE_INDEX - 1))]}"
IFS=',' read -r INSTANCE_NAME INSTANCE_DESCRIPTION INSTANCE_STATE INSTANCE_IPV4 INSTANCE_TYPE_DISPLAY <<< "${SELECTED_ROW}"

CURRENT_CPU="$(lxc config get "${INSTANCE_NAME}" limits.cpu --project "${PROJECT_NAME}" 2>/dev/null || true)"
CURRENT_RAM="$(lxc config get "${INSTANCE_NAME}" limits.memory --project "${PROJECT_NAME}" 2>/dev/null || true)"
CURRENT_BOOT="$(lxc config device get "${INSTANCE_NAME}" root size --project "${PROJECT_NAME}" 2>/dev/null || true)"
FORWARD_IP="$(lxc config get "${INSTANCE_NAME}" user.network_forward_ipv4 --project "${PROJECT_NAME}" 2>/dev/null || true)"

[[ -n "${CURRENT_CPU}" ]] || CURRENT_CPU='inherited'
[[ -n "${CURRENT_RAM}" ]] || CURRENT_RAM='inherited'
[[ -n "${CURRENT_BOOT}" ]] || CURRENT_BOOT='inherited'

INSTANCE_TYPE='ct'
if [[ "${INSTANCE_TYPE_DISPLAY}" == 'VIRTUAL-MACHINE' || "${INSTANCE_TYPE_DISPLAY}" == 'virtual-machine' ]]; then
  INSTANCE_TYPE='vs'
fi
if [[ "${INSTANCE_TYPE_DISPLAY}" == 'CONTAINER' || "${INSTANCE_TYPE_DISPLAY}" == 'container' ]]; then
  INSTANCE_TYPE='ct'
fi

IMAGE_TEXT='unknown'
if [[ -n "${INSTANCE_DESCRIPTION}" && "${INSTANCE_DESCRIPTION}" == image=* ]]; then
  IMAGE_TEXT="$(printf '%s\n' "${INSTANCE_DESCRIPTION}" | sed -n 's/^image=\([^;]*\).*/\1/p')"
fi

echo
echo 'Selected instance:'
echo "Name          : ${INSTANCE_NAME}"
echo "Type          : ${INSTANCE_TYPE}"
echo "State         : ${INSTANCE_STATE:--}"
echo "Current CPU   : ${CURRENT_CPU}"
echo "Current RAM   : ${CURRENT_RAM}"
echo "Current Boot  : ${CURRENT_BOOT}"
echo "Instance IP   : ${INSTANCE_IPV4:--}"
echo "Forward IP    : ${FORWARD_IP:--}"
echo "Description   : ${INSTANCE_DESCRIPTION:--}"
echo

echo 'Enter new values.'
read -r -p "CPU cores [${CURRENT_CPU}]: " NEW_CPU
read -r -p "RAM in GiB [${CURRENT_RAM}]: " NEW_RAM
read -r -p "Boot disk in GiB [${CURRENT_BOOT}]: " NEW_BOOT

[[ -n "${NEW_CPU}" ]] || NEW_CPU="${CURRENT_CPU}"
[[ -n "${NEW_RAM}" ]] || NEW_RAM="${CURRENT_RAM}"
[[ -n "${NEW_BOOT}" ]] || NEW_BOOT="${CURRENT_BOOT}"

[[ "${NEW_CPU}" =~ ^[0-9]+$ ]] || fail 'CPU cores must be numeric.'
if [[ "${NEW_RAM}" =~ ^[0-9]+$ ]]; then
  NEW_RAM="${NEW_RAM}GiB"
fi
[[ "${NEW_RAM}" =~ ^[0-9]+GiB$ ]] || fail 'RAM must be a whole number of GiB.'
if [[ "${NEW_BOOT}" =~ ^[0-9]+$ ]]; then
  NEW_BOOT="${NEW_BOOT}GiB"
fi
[[ "${NEW_BOOT}" =~ ^[0-9]+GiB$ ]] || fail 'boot disk must be a whole number of GiB.'

CURRENT_BOOT_GIB="${CURRENT_BOOT%GiB}"
NEW_BOOT_GIB="${NEW_BOOT%GiB}"
if [[ "${CURRENT_BOOT}" != "inherited" ]]; then
  [[ "${CURRENT_BOOT_GIB}" =~ ^[0-9]+$ ]] || fail 'unable to parse current boot disk size.'
  (( NEW_BOOT_GIB >= CURRENT_BOOT_GIB )) || fail 'boot disk shrink is not allowed; choose the same or a larger size.'
fi

echo
echo 'Planned changes:'
echo "Instance      : ${INSTANCE_NAME}"
echo "CPU           : ${CURRENT_CPU} -> ${NEW_CPU}"
echo "RAM           : ${CURRENT_RAM} -> ${NEW_RAM}"
echo "Boot disk     : ${CURRENT_BOOT} -> ${NEW_BOOT}"
read -r -p 'Type yes to apply these changes: ' CONFIRM
[[ "${CONFIRM}" == 'yes' ]] || fail 'resize cancelled.'

WAS_RUNNING=0
if [[ "${INSTANCE_STATE}" == 'RUNNING' ]]; then
  WAS_RUNNING=1
fi

if [[ "${CURRENT_BOOT}" != "${NEW_BOOT}" && ${WAS_RUNNING} -eq 1 ]]; then
  read -r -p "Instance '${INSTANCE_NAME}' is running and must be stopped for boot disk changes. Stop it now? Type yes to stop, anything else to abort: " STOP_CONFIRM
  [[ "${STOP_CONFIRM}" == 'yes' ]] || fail 'resize cancelled because the instance must be powered off for boot disk changes.'
  echo "Stopping instance '${INSTANCE_NAME}' for root disk resize..."
  run lxc stop "${INSTANCE_NAME}" --project "${PROJECT_NAME}"
elif [[ "${CURRENT_BOOT}" != "${NEW_BOOT}" ]]; then
  echo "Instance '${INSTANCE_NAME}' is already stopped for boot disk resize."
fi

echo "Updating CPU to ${NEW_CPU}..."
run lxc config set "${INSTANCE_NAME}" limits.cpu "${NEW_CPU}" --project "${PROJECT_NAME}"

echo "Updating RAM to ${NEW_RAM}..."
run lxc config set "${INSTANCE_NAME}" limits.memory "${NEW_RAM}" --project "${PROJECT_NAME}"

echo "Updating root disk size to ${NEW_BOOT}..."
if lxc config device show "${INSTANCE_NAME}" --project "${PROJECT_NAME}" 2>/dev/null | grep -q '^root:'; then
  run lxc config device set "${INSTANCE_NAME}" root size="${NEW_BOOT}" --project "${PROJECT_NAME}"
else
  run lxc config device override "${INSTANCE_NAME}" root size="${NEW_BOOT}" --project "${PROJECT_NAME}"
fi

if (( WAS_RUNNING == 1 )); then
  echo "Starting instance '${INSTANCE_NAME}'..."
  run lxc start "${INSTANCE_NAME}" --project "${PROJECT_NAME}"
fi

UPDATED_IPV4="$(lxc list "${INSTANCE_NAME}" --project "${PROJECT_NAME}" -c 4 -f csv 2>/dev/null | head -n1 || true)"
[[ -n "${UPDATED_IPV4}" ]] || UPDATED_IPV4="${INSTANCE_IPV4}"

echo
echo 'Resize complete.'
echo "Project      : ${PROJECT_NAME}"
echo "Instance     : ${INSTANCE_NAME}"
echo "CPU          : ${NEW_CPU}"
echo "RAM          : ${NEW_RAM}"
echo "Boot disk    : ${NEW_BOOT}"
echo "Instance IP  : ${UPDATED_IPV4:--}"
echo "Forward IP   : ${FORWARD_IP:--}"
echo "Description  : ${INSTANCE_DESCRIPTION:--}"

