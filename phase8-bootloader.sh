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

# --------------------------------------------------- apt snapshot safety net
# Phase 2b creates an @snapshots subvolume and Phase 3 mounts it at
# /.snapshots, but nothing has ever written to it: the layout was
# snapshot-ready with no snapshots in it. apt-btrfs-snapshot closes that gap.
#
# It ships /etc/apt/apt.conf.d/80-btrfs-snapshot, a DPkg::Pre-Invoke hook that
# snapshots the @ subvolume before every dpkg run. A bad upgrade then costs one
# `set-default` and a reboot instead of a reinstall.
#
# Installed HERE, after autoremove, on purpose. APT reads apt.conf.d once at
# startup, so the hook that arrives during this run does not fire during it -
# and every earlier phase finishes before the hook exists. Snapshotting a
# chroot mid-build would be noise at best.
echo "==> apt-btrfs-snapshot (pre-upgrade rollback point)"
apt_install --no-install-recommends apt-btrfs-snapshot

# Retention. Pruning runs automatically every time a snapshot is taken and
# works off the TIMESTAMP IN THE SNAPSHOT NAME, which is what makes it safe
# here - see the MaxAge warning below.
#
# The key is APT::Snapshot (singular). The comment block shipped inside
# /etc/cron.weekly/apt-btrfs-snapshot documents it as APT::Snapshots::Retain
# (plural); that spelling is not what the code reads and silently does nothing.
cat > /etc/apt/apt.conf.d/81-btrfs-snapshot-retain <<'EOF'
// Keep the last 8 hourly, 7 daily and 2 weekly apt snapshots of @.
// Snapshots are CoW, so an idle one costs almost nothing until @ diverges.
APT::Snapshot::Retain::hourly "8";
APT::Snapshot::Retain::daily "7";
APT::Snapshot::Retain::weekly "2";

// Deliberately NOT set: APT::Snapshots::MaxAge.
// It switches cleanup over to `delete-older-than`, which derives a snapshot's
// age from the atime of its etc/fstab - and this root is mounted noatime, so
// that path errors out. Setting it also disables the automatic prune above,
// which would leave snapshots accumulating forever.
EOF
echo "    wrote /etc/apt/apt.conf.d/81-btrfs-snapshot-retain"

# `supported` only reads /etc/fstab (btrfs root mounted with subvol=@); it does
# not mount anything, so it is safe to run inside the chroot. Creating a
# snapshot is not - that waits for the real system.
if apt-btrfs-snapshot supported >/dev/null 2>&1; then
  echo "    layout supported - snapshots will be taken from the first apt run"
else
  echo "    !! apt-btrfs-snapshot reports this layout as unsupported."
  echo "    !! It needs a btrfs / mounted with subvol=@ in /etc/fstab."
fi

apt-get clean

# ------------------------------------------------- make no-recommends permanent
# Every phase passed --no-install-recommends on the command line, which governs
# that one invocation and nothing else. The moment you run `sudo apt install X`
# on the booted system, Recommends come back. snapd stays pinned at -1 either
# way, so this is not what keeps snap out - it keeps the system as lean as the
# one the installer built, and stops a stray Recommends from dragging in a
# package whose own dependencies then collide with the pin.
#
# Written LAST, after autoremove: doing it earlier would change what the
# install phases resolve. Override per command with --install-recommends.
echo "==> Making --no-install-recommends the system default"
cat > /etc/apt/apt.conf.d/99norecommends <<'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
EOF
echo "    wrote /etc/apt/apt.conf.d/99norecommends"

echo
echo "==> Phase 8 complete."
echo "==> NOW RUN THE AUDIT BEFORE YOU REBOOT:"
echo "        bash /root/install/verify-before-reboot.sh"
