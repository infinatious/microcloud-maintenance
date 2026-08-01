#!/usr/bin/env bash
set -uo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo 'Error: run this script with bash, do not source it.' >&2
  return 1
fi

SSH_KEY='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCtIWE60jNhTAS/pcQBnV5MAMBzui9CNHhv3VUqVpBkCZq/c9Yt0OHzENq8FZkMWM7dQe/3+AFd+KCrRDTxPsnmNFIjw8lUUBMJgP6a9aKq8tidJi7+7ShboMHqkCGfALNXWeqIf67yG67o6SWJM+78k6f8Ie+2PCIKq/GRTpaH4mjOAHmRGH4ubiNAuL2CKRTk3MK6qyxaovCRA6WjyOSlb1qurZXQ1V/mh+Dqfo6aKMCNof9cdg5j6MneD8X7y+dG4Ge8Gy954n8ZggQwI9ifDxy71ok0GzKATMGb/O+Fwrt5wiMnMq6ct+HqP8XFYuxAl4ys4F3C68epPs4FbuwM5BWBXKOcpsKheG+I6EoXjfPDpqWioTgmNQQOP1v/Hzjw+GQNO8Bw3RK0snKZL9V5WWh9fe9Nnp532rhyTbWQIkUcskV84ToiGei3HyXdXiSy2aWoQlcM5+3dtILsw5czbW8Z9qULPexcR1DavVdFrI320bGzYu4J8T2LGoUGRqYWJapv2HQcZLDjJbXtFqm7PUKTRjXt483nSOqpXaPIhFlhEkm79zLtSAFA10P5LEmA8VwNXuPLKwtCdxj6SMLNwcXJ0djGniugoa2PHcO3g4zh38A5ZJBUx0JR30kJDxYxQ7VSeUHqvk9HBuJKVJ3LN0A6VOCfjcP76V2dT6nBJw== pk@inf-55135'
UPLINK_NETWORK='UPLINK-NAT'
OVN_MTU='1442'

fail() {
  echo "Error: $*" >&2
  exit 1
}

run() {
  "$@" || fail "command failed: $*"
}

cleanup_network() {
  if lxc network show "${NETWORK_NAME}" >/dev/null 2>&1; then
    echo "Cleaning up network '${NETWORK_NAME}' due to earlier failure..." >&2
    lxc network delete "${NETWORK_NAME}" >/dev/null 2>&1 || true
  fi
}

read -r -p 'Project name: ' PROJECT_NAME
read -r -p 'Project ID (0-255): ' PROJECT_ID

[[ -n "${PROJECT_NAME}" ]] || fail 'project name cannot be empty.'
[[ "${PROJECT_ID}" =~ ^[0-9]+$ ]] || fail 'project ID must be numeric.'
(( PROJECT_ID >= 0 && PROJECT_ID <= 255 )) || fail 'project ID must be between 0 and 255.'

NETWORK_NAME="${PROJECT_NAME}"
PROFILE_NAME="${PROJECT_NAME}"
IPV4_ADDRESS="10.127.${PROJECT_ID}.1/24"

command -v lxc >/dev/null 2>&1 || fail 'lxc command not found in PATH.'
lxc storage show zpool >/dev/null 2>&1 || fail "storage pool 'zpool' was not found."
lxc network show "${UPLINK_NETWORK}" >/dev/null 2>&1 || fail "uplink network '${UPLINK_NETWORK}' was not found."

lxc network show "${NETWORK_NAME}" >/dev/null 2>&1 && fail "network '${NETWORK_NAME}' already exists."
lxc project show "${PROJECT_NAME}" >/dev/null 2>&1 && fail "project '${PROJECT_NAME}' already exists."

echo "Creating project '${PROJECT_NAME}'..."
run lxc project create "${PROJECT_NAME}"

run lxc project set "${PROJECT_NAME}" features.images=false
run lxc project set "${PROJECT_NAME}" features.networks=true
run lxc project set "${PROJECT_NAME}" features.networks.zones=true
run lxc project set "${PROJECT_NAME}" features.profiles=true
run lxc project set "${PROJECT_NAME}" features.storage.volumes=true
run lxc project set "${PROJECT_NAME}" restricted=false

trap cleanup_network ERR

echo "Creating OVN network '${NETWORK_NAME}' with IPv4 subnet ${IPV4_ADDRESS}, uplink ${UPLINK_NETWORK}, MTU ${OVN_MTU}, and IPv6 disabled..."
run lxc network create "${NETWORK_NAME}" \
  --project "${PROJECT_NAME}" \
  --type=ovn \
  network="${UPLINK_NETWORK}" \
  bridge.mtu="${OVN_MTU}" \
  ipv4.address="${IPV4_ADDRESS}" \
  ipv4.nat=true \
  ipv6.address=none

run lxc project set "${PROJECT_NAME}" restricted.networks.access="${NETWORK_NAME}"
run lxc project set "${PROJECT_NAME}" restricted.devices.nic=managed
run lxc project set "${PROJECT_NAME}" restricted.devices.disk=managed

echo "Leaving the required default profile in place for project '${PROJECT_NAME}'..."

echo "Creating profile '${PROFILE_NAME}' in project '${PROJECT_NAME}'..."
run lxc profile create "${PROFILE_NAME}" --project "${PROJECT_NAME}"

cat <<PROFILE | lxc profile edit "${PROFILE_NAME}" --project "${PROJECT_NAME}" >/dev/null || fail "unable to apply profile '${PROFILE_NAME}'."
config:
  boot.autostart: "true"
  cloud-init.user-data: |
    #cloud-config
    ssh_authorized_keys:
      - ${SSH_KEY}
  limits.cpu: "2"
  limits.memory: 4GiB
  snapshots.expiry: 3d
  snapshots.schedule: '@daily'
description: ""
devices:
  eth0:
    name: eth0
    network: ${NETWORK_NAME}
    type: nic
  root:
    path: /
    pool: zpool
    size: 20GiB
    type: disk
name: ${PROFILE_NAME}
PROFILE

trap - ERR

echo
echo 'Deployment complete.'
echo "Project : ${PROJECT_NAME}"
echo "Network : ${NETWORK_NAME} (${IPV4_ADDRESS})"
echo "Uplink  : ${UPLINK_NETWORK}"
echo "MTU     : ${OVN_MTU}"
echo "Profile : ${PROFILE_NAME}"
