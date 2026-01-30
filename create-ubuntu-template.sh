#!/bin/bash
set -euo pipefail

imageURL="https://cloud-images.ubuntu.com/noble/20260108/noble-server-cloudimg-amd64.img"
imageName="noble-server-cloudimg-amd64.img"
volumeName="local-zfs"
vmIdMin="9000"
vmIdMax="9500"
virtualMachineId=""
templateName="ubuntu-24.04-noble-server-20260108-tpl"
tmp_cores="2"
tmp_memory="2048"
defaultDiskSize="10G"
cpuTypeRequired="host"
bridgeName="vmbr0"
snippetStorage="local"
snippetDir="/var/lib/vz/snippets"
cloudInitUser="ubuntu"
cloudInitHostname=""
enableDynamicHostname="true"
hookscriptName="cloudinit-hostname-hook.sh"
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

random_vm_id() {
  local min="$1"
  local max="$2"
  local attempts=100
  local id
  if (( min > max )); then
    echo "vmIdMin must be <= vmIdMax." >&2
    exit 1
  fi
  for ((i=0; i<attempts; i++)); do
    id=$(( RANDOM % (max - min + 1) + min ))
    if ! qm status "$id" >/dev/null 2>&1; then
      echo "$id"
      return 0
    fi
  done
  echo "Failed to find a free VM ID in range ${min}-${max}." >&2
  exit 1
}

virtualMachineId="$(random_vm_id "$vmIdMin" "$vmIdMax")"
echo "Selected VM ID: $virtualMachineId"

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
elif [[ -t 0 ]]; then
  read -r -p "Enter SSH public key (leave blank to skip): " sshPublicKey
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
# Bake in package updates so clones start fully patched.
virt-customize -a "$img_path" --update --install qemu-guest-agent

mkdir -p "$snippetDir"
cloudInitPath="$snippetDir/${templateName}-user-data.yaml"
runcmd_lines=""

  if [[ "$enableDynamicHostname" == "true" ]]; then
    hookscriptPath="$snippetDir/$hookscriptName"
    cat >"$hookscriptPath" <<EOF
#!/bin/bash
set -e

vmid="\$1"
phase="\$2"

SNIPPET_STORAGE="local"
SNIPPET_DIR="/var/lib/vz/snippets"
BASE_USER_SNIPPET="$(basename "$cloudInitPath")"
BASE_USER_PATH="\$SNIPPET_DIR/\$BASE_USER_SNIPPET"

raw_name="\$(qm config "\$vmid" | awk -F': ' '/^name:/{print \$2}')"
if [[ -z "\$raw_name" ]]; then
  exit 0
fi

sanitize_hostname() {
  local name="\$1"
  name="\$(echo "\$name" | tr '[:upper:]' '[:lower:]')"
  name="\$(echo "\$name" | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-\$//')"
  if (( \${#name} > 63 )); then
    name="\${name:0:63}"
    name="\$(echo "\$name" | sed 's/-\$//')"
  fi
  echo "\$name"
}

hostname="\$(sanitize_hostname "\$raw_name")"
if [[ -z "\$hostname" ]]; then
  exit 0
fi

snippet_file="\$SNIPPET_DIR/ci-hostname-\$vmid.yaml"
if [[ ! -f "\$BASE_USER_PATH" ]]; then
  exit 0
fi

write_snippet() {
  cat "\$BASE_USER_PATH" >"\$snippet_file"
  cat >>"\$snippet_file" <<SNIPPET

preserve_hostname: false
hostname: \$hostname
manage_etc_hosts: true
bootcmd:
  - hostnamectl set-hostname \$hostname
  - sed -i "s/127.0.1.1.*/127.0.1.1 \$hostname/" /etc/hosts || true
SNIPPET
}

if [[ "\$phase" == "pre-start" ]]; then
  write_snippet
elif [[ "\$phase" == "post-clone" ]]; then
  write_snippet
else
  exit 0
fi

snippet_ref="\$SNIPPET_STORAGE:snippets/\$(basename "\$snippet_file")"
meta_file="\$SNIPPET_DIR/ci-meta-\$vmid.yaml"
meta_ref="\$SNIPPET_STORAGE:snippets/\$(basename "\$meta_file")"

# Create meta-data with local-hostname (processed early by cloud-init)
cat >"\$meta_file" <<META
instance-id: \$vmid
local-hostname: \$hostname
META

# Use qm set to update cicustom - this properly notifies Proxmox
qm set "\$vmid" --cicustom "user=\$snippet_ref,meta=\$meta_ref" 2>/dev/null || true
EOF
  chmod 0755 "$hookscriptPath"
fi

if [[ "$rotateTailscaleKey" == "true" && -z "$tailscaleAuthKey" && -t 0 ]]; then
  read -r -s -p "Enter Tailscale auth key (leave blank to skip): " tailscaleAuthKey
  echo
fi

if [[ "$rotateTailscaleKey" == "true" && -n "$tailscaleAuthKey" ]]; then
  runcmd_lines+=$'\n  - curl -fsSL https://tailscale.com/install.sh | sh'
  runcmd_lines+=$'\n  - tailscale up --ssh --auth-key='"$tailscaleAuthKey"' --hostname="$(hostname)"'
fi
if [[ "$rotateTailscaleKey" == "true" ]]; then
  runcmd_lines+=$'\n  - if command -v tailscale >/dev/null 2>&1; then tailscale up --ssh --hostname="$(hostname)" || true; fi'
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

hostname_block=""
if [[ -n "$cloudInitHostname" ]]; then
  hostname_block+=$'\nhostname: '"$cloudInitHostname"
  hostname_block+=$'\nmanage_etc_hosts: true'
fi

cat >"$cloudInitPath" <<'USERDATA'
#cloud-config
preserve_hostname: false
bootcmd:
  - |
    # Reboot once on first boot to pick up hookscript's cloud-init changes
    marker="/var/lib/cloud/instance/hostnameboot"
    if [ ! -f "$marker" ]; then
      mkdir -p "$(dirname "$marker")"
      touch "$marker"
      reboot
    fi
USERDATA

cat >>"$cloudInitPath" <<EOF
users:
  - name: $cloudInitUser
    groups: sudo
    shell: /bin/bash
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    lock_passwd: true
$ssh_keys_block
$hostname_block
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
qm resize "$virtualMachineId" scsi0 "$defaultDiskSize"
qm set "$virtualMachineId" --boot c --bootdisk scsi0
qm set "$virtualMachineId" --ide2 "$volumeName:cloudinit"
qm set "$virtualMachineId" --cicustom "user=${snippetStorage}:snippets/$(basename "$cloudInitPath")"
qm set "$virtualMachineId" --serial0 socket --vga serial0
qm set "$virtualMachineId" --ipconfig0 ip=dhcp
if [[ "$enableDynamicHostname" == "true" ]]; then
      qm set "$virtualMachineId" --hookscript "local:snippets/$hookscriptName"
    fi
qm template "$virtualMachineId"
