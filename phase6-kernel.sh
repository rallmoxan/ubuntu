#!/usr/bin/env bash
#
# Phase 6 - Kernel, firmware, AMD graphics, zram, networking.
#   RUN INSIDE THE CHROOT.  bash /root/install/phase6-kernel.sh
#
# Hardware this is tuned for:
#   CPU  AMD Ryzen 5 7500X3D          -> amd64-microcode
#   GPU  Radeon RX 9060 XT (RDNA4)    -> amdgpu + Mesa 26.x, kernel 7.0
#   GPU  Raphael iGPU (RDNA2)         -> same stack
#   RAM  14 GiB                       -> zram, no on-disk swap
#
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

[ "$(id -u)" -eq 0 ] || { echo "FATAL: must run as root inside the chroot" >&2; exit 1; }

apt_install() {
  local mode="$1"; shift
  local avail=() miss=() p cand
  for p in "$@"; do
    cand="$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/{print $2}')"
    if [ -n "$cand" ] && [ "$cand" != "(none)" ]; then avail+=("$p"); else miss+=("$p"); fi
  done
  [ ${#miss[@]}  -gt 0 ] && printf '    !! NOT IN ARCHIVE, skipped: %s\n' "${miss[*]}"
  [ ${#avail[@]} -eq 0 ] && return 0
  # shellcheck disable=SC2086
  apt-get install -y $mode "${avail[@]}"
}

apt-get update

# ------------------------------------------------------------------- kernel
# btrfs-progs must be installed BEFORE the initramfs is built, or the initrd
# will not be able to mount a btrfs root and you get a kernel panic, not a
# desktop. linux-image-generic already depends on linux-firmware and
# amd64-microcode; they are listed anyway so the intent is visible.
echo "==> Kernel, firmware, microcode"
apt_install --no-install-recommends \
  linux-image-generic \
  linux-headers-generic \
  linux-firmware \
  amd64-microcode \
  initramfs-tools \
  btrfs-progs \
  firmware-sof-signed

ls -1 /boot/vmlinuz-* >/dev/null 2>&1 || { echo "FATAL: no kernel in /boot" >&2; exit 1; }
echo "    installed kernel(s): $(ls -1 /boot/vmlinuz-* | tr '\n' ' ')"

# ------------------------------------------------------------- AMD graphics
# RDNA4 needs current linux-firmware (already installed above) plus Mesa's
# gallium driver. Package names verified against the resolute archive:
# mesa-va-drivers / mesa-vdpau-drivers no longer exist, mesa-libgallium
# replaces them.
echo "==> AMD graphics stack"
apt_install --no-install-recommends \
  mesa-libgallium \
  libgl1-mesa-dri \
  libglx-mesa0 \
  mesa-vulkan-drivers \
  mesa-utils \
  vulkan-tools \
  libvdpau-va-gl1 \
  xserver-xorg-video-amdgpu \
  xserver-xorg-core \
  xwayland

# ---------------------------------------------------------------------- zram
echo "==> zram swap (no swap partition, no swapfile)"
apt_install --no-install-recommends systemd-zram-generator

mkdir -p /etc/systemd
cat > /etc/systemd/zram-generator.conf <<'EOF'
# 14 GiB RAM -> up to 7 GiB of zstd-compressed swap in RAM.
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

# Tuning that makes zram behave. With compressed RAM swap a high swappiness is
# correct - it is not the same trade-off as swapping to disk.
cat > /etc/sysctl.d/99-zram.conf <<'EOF'
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
EOF

# ------------------------------------------------------------------ network
echo "==> NetworkManager + systemd-resolved"
apt_install --no-install-recommends network-manager systemd-resolved

# netplan comes in via ubuntu-minimal; without a renderer stanza NetworkManager
# will not be given the interfaces to manage.
if dpkg -s netplan.io >/dev/null 2>&1; then
  mkdir -p /etc/netplan
  cat > /etc/netplan/01-network-manager-all.yaml <<'EOF'
network:
  version: 2
  renderer: NetworkManager
EOF
  chmod 600 /etc/netplan/01-network-manager-all.yaml
  echo "    netplan renderer set to NetworkManager"
fi

# ------------------------------------------------------------------ services
echo "==> Enabling services"
for unit in NetworkManager systemd-resolved fstrim.timer; do
  systemctl enable "$unit" 2>/dev/null && echo "    enabled $unit" \
    || echo "    !! could not enable $unit"
done
# Time sync comes from chrony (a dependency of ubuntu-minimal). Only touch
# systemd-timesyncd if chrony is genuinely absent, otherwise they fight.
if ! dpkg -s chrony >/dev/null 2>&1; then
  systemctl enable systemd-timesyncd 2>/dev/null || true
fi

apt_install --no-install-recommends power-profiles-daemon
systemctl enable power-profiles-daemon 2>/dev/null || true

echo
echo "==> Phase 6 complete. Next: bash /root/install/phase7-desktop.sh"
