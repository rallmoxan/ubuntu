#!/usr/bin/env bash
#
# Phase 6 - Kernel, firmware, graphics, zram, networking.
#   RUN INSIDE THE CHROOT.  bash /root/install/phase6-kernel.sh
#
# CPU microcode and the graphics stack follow CPU_VENDOR / GPU_VENDOR in
# config.sh. Both default to "auto" and are detected from the running hardware.
#
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"

[ "$(id -u)" -eq 0 ] || { echo "FATAL: must run as root inside the chroot" >&2; exit 1; }


apt-get update

# ------------------------------------------------------- hardware detection
# Detected from /proc and lspci rather than assumed. Inside a chroot both read
# the HOST's hardware, which is the machine being installed onto - correct
# here, and the reason this must not be run from an unrelated build box.
detect_cpu() {
  case "$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null)" in
    AuthenticAMD) echo amd ;;
    GenuineIntel) echo intel ;;
    *)            echo none ;;
  esac
}

detect_gpu() {
  local vga
  vga="$(lspci -nn 2>/dev/null | grep -iE 'vga compatible|3d controller|display controller' || true)"
  case "$vga" in
    *NVIDIA*|*nVidia*) echo nvidia ;;
    *AMD*|*ATI*)       echo amd ;;
    *Intel*)           echo intel ;;
    *)                 echo none ;;
  esac
}

[ "$CPU_VENDOR" = "auto" ] && CPU_VENDOR="$(detect_cpu)"
[ "$GPU_VENDOR" = "auto" ] && GPU_VENDOR="$(detect_gpu)"
echo "==> CPU: $CPU_VENDOR    GPU: $GPU_VENDOR"

case "$CPU_VENDOR" in
  amd)   MICROCODE="amd64-microcode" ;;
  intel) MICROCODE="intel-microcode" ;;
  *)     MICROCODE="" ;;
esac

# ------------------------------------------------------------------- kernel
# btrfs-progs must be installed BEFORE the initramfs is built, or the initrd
# will not be able to mount a btrfs root and you get a kernel panic, not a
# desktop. linux-image-generic already depends on linux-firmware and the
# microcode; they are listed anyway so the intent is visible.
echo "==> Kernel, firmware, microcode"
# shellcheck disable=SC2086
apt_install --no-install-recommends \
  linux-image-generic \
  linux-headers-generic \
  linux-firmware \
  $MICROCODE \
  initramfs-tools \
  btrfs-progs \
  firmware-sof-signed

ls -1 /boot/vmlinuz-* >/dev/null 2>&1 || { echo "FATAL: no kernel in /boot" >&2; exit 1; }
echo "    installed kernel(s): $(ls -1 /boot/vmlinuz-* | tr '\n' ' ')"

# ----------------------------------------------------------------- graphics
# Mesa covers AMD and Intel completely - no proprietary anything. Package names
# verified against the resolute archive: mesa-va-drivers / mesa-vdpau-drivers
# no longer exist, mesa-libgallium replaces them.
echo "==> Graphics stack ($GPU_VENDOR)"
apt_install --no-install-recommends \
  mesa-libgallium \
  libgl1-mesa-dri \
  libglx-mesa0 \
  mesa-vulkan-drivers \
  mesa-utils \
  vulkan-tools \
  libvdpau-va-gl1 \
  xserver-xorg-core \
  xwayland

case "$GPU_VENDOR" in
  amd)
    apt_install --no-install-recommends xserver-xorg-video-amdgpu
    ;;
  intel)
    # intel-media-va-driver covers Broadwell and newer; i965-va-driver the
    # older parts. Whichever is absent from the archive is simply skipped.
    apt_install --no-install-recommends \
      xserver-xorg-video-intel intel-media-va-driver i965-va-driver
    ;;
  nvidia)
    # Deliberately NOT installing a driver. Which one is right depends on the
    # card's generation and on whether Secure Boot is on - an installer that
    # guesses here produces a black screen on first boot, which is the single
    # worst outcome this project can hand someone. Nouveau comes with the
    # kernel and will bring up a desktop; swap it after you have a login.
    echo "    !! NVIDIA detected. No proprietary driver installed on purpose."
    echo "    !! Nouveau (in-kernel) will get you to a desktop. After first boot:"
    echo "    !!     sudo ubuntu-drivers devices     # see what fits this card"
    echo "    !!     sudo ubuntu-drivers install"
    echo "    !! With Secure Boot on you will be asked to enrol a MOK key and"
    echo "    !! confirm it at the next reboot, or the module will not load."
    ;;
  *)
    echo "    no discrete GPU vendor detected; Mesa's software path still works"
    ;;
esac

# ---------------------------------------------------------------------- zram
echo "==> zram swap (no swap partition, no swapfile)"
apt_install --no-install-recommends systemd-zram-generator

mkdir -p /etc/systemd
cat > /etc/systemd/zram-generator.conf <<'EOF'
# Half of RAM, capped at 8 GiB, zstd-compressed, in RAM. No swap partition and
# no swapfile - which also means no hibernation.
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
