#!/usr/bin/env bash
#
# Phase 8 - initramfs, GRUB (UEFI + Secure Boot), final cleanup.
#   RUN INSIDE THE CHROOT.  bash /root/install/phase8-bootloader.sh
#
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

[ "$(id -u)" -eq 0 ] || { echo "FATAL: must run as root inside the chroot" >&2; exit 1; }
mountpoint -q /boot/efi || { echo "FATAL: /boot/efi is not mounted inside the chroot" >&2; exit 1; }

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

# -------------------------------------------------------------------- GRUB
echo "==> Installing GRUB (UEFI, Secure Boot capable)"
apt_install --no-install-recommends \
  grub-efi-amd64 grub-efi-amd64-signed shim-signed efibootmgr grub2-common

# ---------------------------------------------------------- /etc/default/grub
# rootflags=subvol=@ is stated explicitly. GRUB usually derives it, but if it
# does not, the initramfs mounts the btrfs top level instead of @, finds no
# /sbin/init, and the boot dies. Costs nothing to be certain.
#
# GRUB_CMDLINE_LINUX_DEFAULT is left EMPTY on purpose so the first boot shows
# every kernel message. Once it boots cleanly, set it to "quiet splash".
echo "==> Writing /etc/default/grub"
cat > /etc/default/grub <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu
GRUB_DISTRIBUTOR="Ubuntu"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="rootflags=subvol=@"
GRUB_TERMINAL_OUTPUT=gfxterm
GRUB_GFXMODE=auto
EOF

# --------------------------------------------------------------- initramfs
echo "==> Rebuilding the initramfs for every installed kernel"
# -c fails if an initrd already exists (the kernel postinst usually made one),
# so update when present and create only when genuinely absent.
if ls /boot/initrd.img-* >/dev/null 2>&1; then
  update-initramfs -u -k all
else
  update-initramfs -c -k all
fi

for img in /boot/initrd.img-*; do
  [ -e "$img" ] || { echo "FATAL: no initramfs was produced" >&2; exit 1; }
  if lsinitramfs "$img" 2>/dev/null | grep -q 'btrfs'; then
    echo "    $(basename "$img"): contains btrfs support  OK"
  else
    echo "    !!!! $(basename "$img") HAS NO BTRFS SUPPORT - it will not boot." >&2
    echo "    !!!! Fix: apt-get install btrfs-progs && update-initramfs -c -k all" >&2
    exit 1
  fi
done

# ------------------------------------------------------------- grub-install
echo "==> grub-install (NVRAM entry)"
# Not fatal on its own: if efivars is not writable from the chroot the files
# still land in the ESP, and the removable fallback below covers booting.
if grub-install --target=x86_64-efi --efi-directory=/boot/efi \
                --bootloader-id=Ubuntu --recheck; then
  echo "    UEFI NVRAM entry written"
else
  echo "    !! Could not write the NVRAM entry (efivars unavailable in chroot)."
  echo "    !! The removable fallback below will still boot the system."
fi

# Fallback path. Some firmware ignores NVRAM entries after a disk wipe; a
# BOOTX64.EFI at the default path is what saves you from a black screen.
echo "==> grub-install (removable fallback EFI/BOOT/BOOTX64.EFI)"
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
             --removable --recheck

echo "==> Generating grub.cfg"
update-grub

# ------------------------------------------------------------ verify grub.cfg
echo "==> Verifying grub.cfg"
ROOT_UUID="$(awk '$1 !~ /^#/ && $2=="/" && $3=="btrfs" {print $1; exit}' /etc/fstab | sed 's/^UUID=//')"
[ -n "$ROOT_UUID" ] || { echo "FATAL: no root UUID in /etc/fstab" >&2; exit 1; }

grep -q "$ROOT_UUID" /boot/grub/grub.cfg \
  && echo "    root UUID present in grub.cfg  OK" \
  || { echo "FATAL: grub.cfg does not reference root UUID $ROOT_UUID" >&2; exit 1; }

grep -q 'rootflags=subvol=@' /boot/grub/grub.cfg \
  && echo "    rootflags=subvol=@ present  OK" \
  || { echo "FATAL: grub.cfg is missing rootflags=subvol=@" >&2; exit 1; }

# ------------------------------------------------------------------ DNS
# Done LAST: this symlink only resolves once systemd-resolved is actually
# running, which is on the real system, not in this chroot. Doing it earlier
# would break apt for the rest of the install.
echo "==> Pointing /etc/resolv.conf at systemd-resolved"
rm -f /etc/resolv.conf
ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# --------------------------------------------------------------- cleanup
echo "==> Cleanup"
rm -f /usr/sbin/policy-rc.d
apt-get -y autoremove --purge
apt-get clean

echo
echo "==> Phase 8 complete."
echo "==> NOW RUN THE AUDIT BEFORE YOU REBOOT:"
echo "        bash /root/install/verify-before-reboot.sh"
