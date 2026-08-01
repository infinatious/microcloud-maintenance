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

command -v lxc >/dev/null 2>&1 || fail 'lxc command not found in PATH.'

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

PROFILE_NAME="${PROJECT_NAME}"
NETWORK_NAME="${PROJECT_NAME}"

lxc project show "${PROJECT_NAME}" >/dev/null 2>&1 || fail "project '${PROJECT_NAME}' does not exist."

INSTANCE_LIST="$(lxc list --project "${PROJECT_NAME}" --format csv -c n 2>/dev/null || true)"
if [[ -n "${INSTANCE_LIST}" ]]; then
  echo "Project '${PROJECT_NAME}' still has instances:" >&2
  printf '%s\n' "${INSTANCE_LIST}" >&2
  echo 'Delete the instances first, then re-run this script.' >&2
  exit 1
fi

mapfile -t PROFILE_NAMES < <(lxc profile list --project "${PROJECT_NAME}" --format csv -c n 2>/dev/null || true)
if (( ${#PROFILE_NAMES[@]} > 0 )); then
  for PROFILE_NAME in "${PROFILE_NAMES[@]}"; do
    if [[ "${PROFILE_NAME}" == 'default' ]]; then
      echo "Skipping built-in profile '${PROFILE_NAME}'."
      continue
    fi
    echo "Deleting profile '${PROFILE_NAME}'..."
    run lxc profile delete "${PROFILE_NAME}" --project "${PROJECT_NAME}"
  done
else
  echo "No project profiles found, skipping."
fi

if lxc network show "${NETWORK_NAME}" --project "${PROJECT_NAME}" >/dev/null 2>&1; then
  echo "Deleting network '${NETWORK_NAME}'..."
  run lxc network delete "${NETWORK_NAME}" --project "${PROJECT_NAME}"
else
  echo "Network '${NETWORK_NAME}' not found, skipping."
fi

echo "Deleting project '${PROJECT_NAME}'..."
run lxc project delete "${PROJECT_NAME}"

echo
echo 'Deletion complete.'
echo "Project : ${PROJECT_NAME}"
