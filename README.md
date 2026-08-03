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

### Command-line usage

All of the scripts now accept command-line arguments and keep the original prompt-driven flow as an interactive fallback when you omit the matching arguments.

#### `deploy-project.sh`

Create a new project, OVN network, and both profiles.

Examples:

```bash
./deploy-project.sh --project-name demo --project-id 42
```

If you omit the options, the script will prompt for them in the original interactive way.

#### `create-instance.sh`

Create a new instance inside an existing project.

Examples:

```bash
./create-instance.sh --project-id 42 --environment p --service-code demo1 --profile-type linux --cpu 2 --ram 4 --disk 20 --image-index 3
./create-instance.sh --project-id 42 --environment d --service-code svc01 --profile-type win --image-alias ubuntu --description-suffix 'site-a'
```

Supported arguments:

- `--project-id` selects the target project by numeric project ID.
- `--environment` uses `p`, `t`, `q`, or `d`.
- `--service-code` must be exactly five alphanumeric characters.
- `--profile-type` is `linux` or `win`.
- `--cpu`, `--ram`, and `--disk` override the profile defaults.
- `--image-index` selects the image from the numbered filtered list.
- `--image-alias` can be supplied instead of `--image-index` when you know the exact alias.
- `--description-suffix` appends an optional text suffix to the instance description.

If you omit any of these positional choices, the script will prompt for the missing values.

#### `resize-instance.sh`

Resize an existing instance in a project.

Examples:

```bash
./resize-instance.sh --project-id 42 --instance-index 1 --cpu 4 --ram 8 --boot-disk 60 --yes
```

Supported arguments:

- `--project-id` selects the project by numeric project ID.
- `--instance-index` selects the instance from the numbered list shown by the script.
- `--cpu`, `--ram`, and `--boot-disk` set the new values.
- `--yes` skips the final confirmation prompt.

If you omit the selection or resource values, the script will prompt for them interactively.

#### `delete-instance.sh`

Delete a single instance safely.

Examples:

```bash
./delete-instance.sh --project-id 42 --instance-index 2 --yes
./delete-instance.sh --project-id 42 --instance-name p42-tstng-ct01 --yes
```

Supported arguments:

- `--project-id` selects the source project by numeric project ID.
- `--instance-index` selects the instance from the numbered list.
- `--instance-name` deletes the instance directly by exact LXD instance name.
- `--yes` skips the final confirmation prompt.

#### `delete-project.sh`

Delete all profiles, remove the OVN network, and remove an entire project.

Examples:

```bash
./delete-project.sh --project-id 42
```

A delete run will still refuse to proceed if the project still contains instances.

### Deployment flow

1. Run `deploy-project.sh` with `--project-name` and `--project-id`, or let it prompt if you omit them.
2. The script creates:
   - the project
   - the OVN network for the project
   - the Linux profile
   - the Windows profile
3. The Linux profile uses the cloud-init payload from `cloud-init-user-data.yaml`.
4. The Windows profile is created without cloud-init and uses a larger boot disk size.

### Instance creation flow

1. Run `create-instance.sh` with the required argument set, or let it prompt for the missing values.
2. The script selects the project, environment, and service code.
3. It chooses either the Linux or Windows profile.
4. It applies the chosen CPU, RAM, and disk values.
5. It selects an image from the filtered list shown for the chosen profile family.
6. The script creates the instance, allocates a forward IP, and stores the created description text.

### Resize flow

1. Run `resize-instance.sh` with `--project-id`, `--instance-index`, and the desired resource values, or let it prompt interactively.
2. The existing description is preserved as-is.
3. If the new boot disk is larger while the instance is running, the script will stop and restart it automatically.

### Project deletion flow

1. Run `delete-project.sh` with `--project-id`, or let it prompt if you omit it.
2. The script removes every profile in the project first.
3. It then removes the project network.
4. Finally, it deletes the project itself.

---

## Notes

- The Linux profile is intended for cloud-init based image deployment.
- The Windows profile is intended for Windows-capable images and uses a `64GiB` root disk.
- The image picker filters the list based on the chosen profile family so that Linux selections exclude names containing `win`, and Windows selections only show images whose names include `win`.
