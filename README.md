# MicroCloud maintenance workflow

## Fresh MicroCloud install setup

Before using the scripts in this repository, set up a fresh MicroCloud host with a working LXD environment and a storage pool named `zpool`.

### 1. Install the base tooling

On the MicroCloud host, ensure the following are available:

- `lxc`
- `lxd`
- `bash`
- `jq`
- `python3`

The scripts in this repository assume that:

- the host has an available storage pool named `zpool` (can be changed in deploy-project.sh)
- an uplink physical network named `UPLINK-NAT` already exists (can be changed in deploy-project.sh)
- the `default` project is available for image discovery

### 2. Create the network uplink

Create a physical uplink network for the host that will act as the external-facing network for OVN traffic. The network should be configured as a physical network on the host NIC that will carry your traffic upstream.

In practice, that means:

- pick the host physical interface that should connect to the external network
- create a physical network object named `UPLINK-NAT`
- set the network to use that interface
- configure DNS servers for the uplink
- configure a gateway and the correct IPv4 routes for the upstream network
- reserve the OVN IPv4 address range that the project networks should use for NAT and routing

The important idea is that `UPLINK-NAT` should represent a real physical uplink path, not an isolated bridge or a private virtual network.

A typical configuration pattern looks like this conceptually, using an uplink network of 192.168.232.0/21:

```yaml
access_entitlements:
  - can_edit
  - can_delete
project: default
name: UPLINK-NAT
description: ''
type: physical
config:
  dns.nameservers: 1.1.1.1,9.9.9.9
  ipv4.gateway: 192.168.232.1/21
  ipv4.routes: 192.168.233.0/24,192.168.234.0/24,192.168.235.0/24,192.168.236.0/24, 192.168.237.0/24, 192.168.238.0/24, 192.168.239.0/24, 192.168.232.128/25
  ipv4.ovn.ranges: 192.168.232.2-192.168.232.127
```

Use values that match your site network planning. The exact address block should be chosen to fit the external network that the host is attached to.

### 3. Confirm the storage pool

Create or confirm the storage pool named `zpool` before running the deployment scripts.

This repository expects the root disk for profiles and instances to come from that storage pool.

### 4. Validate the environment

Once the host is ready, verify that:

- `lxc network show UPLINK-NAT` succeeds
- `lxc storage show zpool` succeeds
- `lxc image list --project default` returns images that can be used for instance creation

---

## Script overview

These scripts are intended for a project-based workflow on a MicroCloud host.

- `deploy-project.sh` creates a project, network, and Linux/Windows profiles.
- `create-instance.sh` creates instances inside the selected project using the chosen profile and image set.
- `resize-instance.sh` resizes an existing instance in the selected project.
- `delete-instance.sh` removes a single instance.
- `delete-project.sh` deletes all profiles in a project, removes the network, and destroys the project.

### Deployment flow

1. Run `deploy-project.sh`.
2. Enter a project name and a numeric project ID.
3. The script creates:
   - the project
   - the OVN network for the project
   - the Linux profile
   - the Windows profile
4. The Linux profile uses the cloud-init payload from `cloud-init-user-data.yaml`.
5. The Windows profile is created without cloud-init and uses a larger boot disk size.

### Instance creation flow

1. Run `create-instance.sh`.
2. Enter the project name, environment code, and service code.
3. Choose either the Linux or Windows profile.
4. Accept or override the profile defaults for CPU, RAM, and disk size.
5. Select an image from the filtered list shown for the chosen profile family.
6. The script creates the instance, allocates a forward IP, and stores the created description text.

### Resize flow

1. Run `resize-instance.sh`.
2. Pick the instance to resize.
3. Enter the new CPU, RAM, and boot disk values.
4. The existing description is preserved as-is.

### Project deletion flow

1. Run `delete-project.sh`.
2. The script removes every profile in the project first.
3. It then removes the project network.
4. Finally, it deletes the project itself.

---

## Notes

- The Linux profile is intended for cloud-init based image deployment.
- The Windows profile is intended for Windows-capable images and uses a `64GiB` root disk.
- The image picker filters the list based on the chosen profile family so that Linux selections exclude names containing `win`, and Windows selections only show images whose names include `win`.
