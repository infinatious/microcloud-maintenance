#!/usr/bin/env bash
set -euo pipefail

PS1_VALUE='\[\e[38;5;140m\][\[\e[38;5;206m\]\t\[\e[0m\] \[\e[38;5;76m\]\u@\[\e[38;5;36;1m\]\h\[\e[0m\] \[\e[38;5;39m\]\w\[\e[38;5;141m\]]\[\e[0m\] '

if [[ -d /home/kauffpc ]]; then
  BASHRC_FILE="/home/kauffpc/.bashrc"
  if ! grep -q '^PS1=' "${BASHRC_FILE}" 2>/dev/null; then
    printf "%s\n" "PS1='${PS1_VALUE}'" >> "${BASHRC_FILE}"
    chown kauffpc:kauffpc "${BASHRC_FILE}"
  fi
fi

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
else
  echo 'Error: unable to detect OS release.' >&2
  exit 1
fi

case "${ID,,}" in
  almalinux|rocky|centos)
    echo 'fastestmirror=true' >> /etc/dnf/dnf.conf
    echo 'max_parallel_downloads=10' >> /etc/dnf/dnf.conf
    echo 'defaultyes=True' >> /etc/dnf/dnf.conf
    dnf update -y
    dnf install epel-release -y
    dnf install open-vm-tools -y
    dnf install nfs-utils -y
    dnf install htop -y
    dnf install vim-enhanced -y
    dnf install git -y
    dnf install wget -y
    dnf install make -y
    dnf install gcc -y
    dnf install links -y
    dnf install mlocate -y
    dnf install figlet -y
    dnf install dnf-automatic -y
    sed -i 's/^apply_updates =.*/apply_updates = yes/' /etc/dnf/automatic.conf
    sed -i 's/^download_updates =.*/download_updates = yes/' /etc/dnf/automatic.conf
    sed -i 's/^upgrade_type =.*/upgrade_type = security/' /etc/dnf/automatic.conf
    systemctl enable --now dnf-automatic.timer
    ;;
  ubuntu|debian)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
    apt-get install -y open-vm-tools nfs-common htop vim git wget make gcc links mlocate figlet unattended-upgrades apt-listchanges
    cat <<'EOF' > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
    cat <<'EOF' > /etc/apt/apt.conf.d/50unattended-upgrades
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}-security";
  "${distro_id}:${distro_codename}-updates";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
    systemctl enable --now unattended-upgrades
    ;;
  *)
    echo "Unsupported OS: ${ID}" >&2
    exit 1
    ;;
esac

if command -v updatedb >/dev/null 2>&1; then
  updatedb || true
fi

cat <<'EOF' > /etc/profile.d/motd-refresh.sh
#!/usr/bin/env bash
if command -v figlet >/dev/null 2>&1; then
  HOSTNAME_ASCII="$(hostname | tr '[:lower:]' '[:upper:]')"
  ASCII_ART="$(figlet -c "${HOSTNAME_ASCII}" 2>/dev/null || true)"
else
  ASCII_ART=''
fi

CPU_USAGE=$(top -bn1 2>/dev/null | awk '/^%Cpu/ {usage = $2 + $4 + $6; printf "%.0f", usage; exit}')
CPU_CAPACITY=$(nproc 2>/dev/null || echo 'unknown')
RAM_TOTAL=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}')
RAM_USED=$(free -m 2>/dev/null | awk '/^Mem:/ {print $3}')
RAM_TOTAL_GB=$(awk -v total="${RAM_TOTAL}" 'BEGIN {printf "%.1f", total / 1024}')
RAM_USED_GB=$(awk -v used="${RAM_USED}" 'BEGIN {printf "%.1f", used / 1024}')
PRIMARY_IPV4="$(hostname -I 2>/dev/null | awk '{print $1}')"
DISK_LINES="$(df -hP / /home 2>/dev/null | awk 'NR>1 {printf "%-20s %5s used\n", $6, $5}')"

{
  echo '############################################################'
  if [[ -n "${ASCII_ART}" ]]; then
    printf '%s\n' "${ASCII_ART}"
  fi
  echo "CPU ${CPU_USAGE}% of ${CPU_CAPACITY} cores"
  echo "RAM ${RAM_USED_GB}GB/${RAM_TOTAL_GB}GB"
  echo "IPv4 ${PRIMARY_IPV4:-unknown}"
  echo
  echo 'Disk usage:'
  printf '%s\n' "${DISK_LINES}"
  echo '############################################################'
} > /etc/motd
EOF
chmod 755 /etc/profile.d/motd-refresh.sh

if [[ -f /etc/profile ]]; then
  grep -q 'motd-refresh.sh' /etc/profile || echo '. /etc/profile.d/motd-refresh.sh' >> /etc/profile
fi

if [[ -f /etc/bash.bashrc ]]; then
  grep -q 'motd-refresh.sh' /etc/bash.bashrc || echo '. /etc/profile.d/motd-refresh.sh' >> /etc/bash.bashrc
fi

if [[ -f /etc/profile.d/motd-refresh.sh ]]; then
  . /etc/profile.d/motd-refresh.sh
fi

echo 'Post-install setup complete.'
