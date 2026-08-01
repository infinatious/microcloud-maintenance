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

read -r -p 'Project name: ' PROJECT_NAME
[[ -n "${PROJECT_NAME}" ]] || fail 'project name cannot be empty.'

PROFILE_NAME="${PROJECT_NAME}"
NETWORK_NAME="${PROJECT_NAME}"

command -v lxc >/dev/null 2>&1 || fail 'lxc command not found in PATH.'
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
