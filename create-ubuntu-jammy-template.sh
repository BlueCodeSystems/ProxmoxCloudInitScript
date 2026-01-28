#!/bin/bash
set -euo pipefail

imageURL="https://cloud-images.ubuntu.com/noble/20260108/noble-server-cloudimg-amd64.img"
imageName="noble-server-cloudimg-amd64.img"
volumeName="local-zfs"
virtualMachineId="9000"
templateName="noble-tpl"
tmp_cores="2"
tmp_memory="2048"
cpuTypeRequired="host"
bridgeName="vmbr0"
snippetStorage="local"
snippetDir="/var/lib/vz/snippets"
cloudInitUser="ubuntu"
sshPublicKeyPath=""
breakGlassKeyPath=""
includeBreakGlassKey="false"
tailscaleAuthKey="${TAILSCALE_AUTH_KEY:-}"
rotateTailscaleKey="true"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

require_cmd qm
require_cmd virt-customize

sshPublicKey=""
if [[ -n "$sshPublicKeyPath" ]]; then
  if [[ ! -f "$sshPublicKeyPath" ]]; then
    echo "sshPublicKeyPath is set but the file does not exist." >&2
    exit 1
  fi
  sshPublicKey="$(tr -d '\r\n' < "$sshPublicKeyPath")"
  if [[ -z "$sshPublicKey" ]]; then
    echo "sshPublicKeyPath is empty." >&2
    exit 1
  fi
fi

breakGlassKey=""
if [[ "$includeBreakGlassKey" == "true" ]]; then
  if [[ -z "$breakGlassKeyPath" || ! -f "$breakGlassKeyPath" ]]; then
    echo "includeBreakGlassKey is true but breakGlassKeyPath is invalid." >&2
    exit 1
  fi
  breakGlassKey="$(tr -d '\r\n' < "$breakGlassKeyPath")"
  if [[ -z "$breakGlassKey" ]]; then
    echo "breakGlassKeyPath is empty." >&2
    exit 1
  fi
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y libguestfs-tools wget

workdir="$(mktemp -d)"
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image_dir="$script_dir"
img_path="$image_dir/$imageName"
if [[ -f "$img_path" ]]; then
  echo "Using cached image: $img_path"
else
  wget -O "$img_path" "$imageURL"
fi

if qm status "$virtualMachineId" >/dev/null 2>&1; then
  qm stop "$virtualMachineId" >/dev/null 2>&1 || true
  qm destroy "$virtualMachineId" --purge 1
fi

# Keep the image cloud-init ready (like AWS); do not set a root password.
virt-customize -a "$img_path" --install qemu-guest-agent

mkdir -p "$snippetDir"
cloudInitPath="$snippetDir/${templateName}-user-data.yaml"
runcmd_lines=""

if [[ "$rotateTailscaleKey" == "true" && -z "$tailscaleAuthKey" && -t 0 ]]; then
  read -r -s -p "Enter Tailscale auth key (leave blank to skip): " tailscaleAuthKey
  echo
fi

if [[ "$rotateTailscaleKey" == "true" && -n "$tailscaleAuthKey" ]]; then
  runcmd_lines+=$'\n  - curl -fsSL https://tailscale.com/install.sh | sh'
  runcmd_lines+=$'\n  - tailscale up --ssh --auth-key='"$tailscaleAuthKey"
fi

ssh_keys_block=""
if [[ -n "$sshPublicKey" || -n "$breakGlassKey" ]]; then
  ssh_keys_block+=$'\n    ssh_authorized_keys:'
  if [[ -n "$sshPublicKey" ]]; then
    ssh_keys_block+=$'\n      - '"$sshPublicKey"
  fi
  if [[ -n "$breakGlassKey" ]]; then
    ssh_keys_block+=$'\n      - '"$breakGlassKey"
  fi
fi

cat >"$cloudInitPath" <<EOF
#cloud-config
users:
  - name: $cloudInitUser
    groups: sudo
    shell: /bin/bash
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    lock_passwd: true
$ssh_keys_block
disable_root: true
ssh_pwauth: false
package_update: true
package_upgrade: false
runcmd:
$runcmd_lines
EOF

qm create "$virtualMachineId" \
  --name "$templateName" \
  --memory "$tmp_memory" \
  --cores "$tmp_cores" \
  --net0 "virtio,bridge=$bridgeName" \
  --ostype l26 \
  --agent 1 \
  --cpu "cputype=$cpuTypeRequired"

qm importdisk "$virtualMachineId" "$img_path" "$volumeName"
qm set "$virtualMachineId" --scsihw virtio-scsi-pci --scsi0 "$volumeName:vm-$virtualMachineId-disk-0"
qm set "$virtualMachineId" --boot c --bootdisk scsi0
qm set "$virtualMachineId" --ide2 "$volumeName:cloudinit"
qm set "$virtualMachineId" --cicustom "user=${snippetStorage}:snippets/$(basename "$cloudInitPath")"
qm set "$virtualMachineId" --serial0 socket --vga serial0
qm set "$virtualMachineId" --ipconfig0 ip=dhcp
qm template "$virtualMachineId"
