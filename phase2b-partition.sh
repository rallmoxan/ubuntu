#!/usr/bin/env bash
#
# Phase 2b - Wipe and partition the target disk for Ubuntu 26.04
#
#   *** RUN FROM THE UBUNTU 26.04 LIVE SESSION ONLY ***
#   *** THIS DESTROYS ALL DATA ON TARGET_DISK_SERIAL ***
#
# Every other disk is left alone. If MIGRATE_DISK_SERIAL is set in config.sh,
# this script actively refuses to touch it.
#
# Usage:  sudo bash phase2b-partition.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"

[ "$(id -u)" -eq 0 ] || { echo "FATAL: run as root (sudo bash $0)" >&2; exit 1; }
require_config TARGET_DISK_SERIAL

# ---------------------------------------------------------------- prerequisites
echo "==> Checking network (needed to fetch the partitioning tools)"
getent hosts archive.ubuntu.com >/dev/null 2>&1 \
  || { echo "FATAL: no network in the live session. Connect first." >&2; exit 1; }

echo "==> Installing partitioning prerequisites into the live session"
apt-get update -qq
apt-get install -y -qq gdisk btrfs-progs dosfstools

# ------------------------------------------------- resolve target BY SERIAL only
# Device names (nvme0n1 vs nvme1n1) can enumerate differently under the live
# kernel. Matching on serial is the only safe way to identify the target.
DISK="$(resolve_disk_by_serial "$TARGET_DISK_SERIAL")" || {
  echo "FATAL: no disk with serial $TARGET_DISK_SERIAL found." >&2
  show_disks
  exit 1
}

# Paranoia: refuse to continue if the target and the disk to preserve are the
# same. Cheap check, and the failure it prevents is total.
if [ -n "${MIGRATE_DISK_SERIAL:-}" ] && [ "$TARGET_DISK_SERIAL" = "$MIGRATE_DISK_SERIAL" ]; then
  echo "FATAL: TARGET_DISK_SERIAL and MIGRATE_DISK_SERIAL are the same disk." >&2
  echo "       Phase 9 would have nothing to migrate from. Aborting." >&2
  exit 1
fi

# Refuse to wipe the disk the live session itself is running from.
LIVE_SRC="$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*//')"
if [ -n "$LIVE_SRC" ] && [ -b "$LIVE_SRC" ]; then
  LIVE_DISK="/dev/$(lsblk -no PKNAME "$LIVE_SRC" 2>/dev/null || true)"
  [ "$LIVE_DISK" = "$DISK" ] && {
    echo "FATAL: that is the disk this live session is running from. Aborting." >&2
    exit 1
  }
fi

P1="$(partition_node "$DISK" 1)"
P2="$(partition_node "$DISK" 2)"

# ------------------------------------------------------------------ confirmation
echo
echo "================================================================"
echo " TARGET (WILL BE COMPLETELY ERASED): $DISK  serial $TARGET_DISK_SERIAL"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DISK"
echo
if [ -n "${MIGRATE_DISK_SERIAL:-}" ]; then
  echo " PRESERVED (not touched): serial $MIGRATE_DISK_SERIAL"
else
  echo " Every other attached disk is left untouched."
fi
echo "================================================================"
echo
read -r -p "Type ERASE in capitals to destroy $DISK, anything else aborts: " CONFIRM
[ "$CONFIRM" = "ERASE" ] || { echo "Aborted, nothing changed."; exit 1; }

# ------------------------------------------------------------------- unmount all
# Only touch things on THIS disk. A blanket `swapoff -a` would also kill the
# live session's own zram swap, which we still want during debootstrap.
echo "==> Releasing any existing mounts / swap on $DISK"
umount -R /mnt 2>/dev/null || true
for part in $(lsblk -lno NAME "$DISK" | tail -n +2); do
  swapoff "/dev/$part" 2>/dev/null || true
  umount -Rf "/dev/$part" 2>/dev/null || true
done

# ------------------------------------------------------------------ partitioning
echo "==> Wiping old filesystem signatures"
# Per-partition first: zapping only the GPT can leave stale superblocks behind
# at the old offsets, which then confuse blkid and produce duplicate UUIDs.
for part in $(lsblk -lno NAME "$DISK" | tail -n +2); do
  wipefs -a "/dev/$part" 2>/dev/null || true
done

echo "==> Writing fresh GPT to $DISK"
wipefs -a "$DISK"
sgdisk --zap-all "$DISK"
sgdisk -n1:0:"+$ESP_SIZE" -t1:ef00 -c1:"EFI"         "$DISK"   # ESP
sgdisk -n2:0:0            -t2:8304 -c2:"ubuntu-root" "$DISK"   # Linux x86-64 root, rest
partprobe "$DISK"
udevadm settle
sleep 2

# The kernel does not always publish new partition nodes immediately. Formatting
# a device that does not exist yet is how people end up with half-made disks.
for dev in "$P1" "$P2"; do
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -b "$dev" ] && break
    sleep 1
  done
  [ -b "$dev" ] || { echo "FATAL: $dev never appeared after partitioning." >&2; exit 1; }
done
echo "    partitions ready: $P1 $P2"

# -------------------------------------------------------------------- formatting
echo "==> Formatting $P1 as FAT32 (ESP) and $P2 as btrfs"
mkfs.vfat -F32 -n EFI "$P1"
mkfs.btrfs -f -L ubuntu-root "$P2"

# ------------------------------------------------------------------- subvolumes
echo "==> Creating btrfs subvolumes"
mkdir -p /mnt
mount -o "$MOUNT_OPTS" "$P2" /mnt
for sv in @ @home @snapshots @var_log @var_cache @var_lib_flatpak; do
  btrfs subvolume create "/mnt/$sv"
done
btrfs subvolume list /mnt
umount /mnt

# ---------------------------------------------------------------- final mounting
echo "==> Mounting target layout under /mnt"
mount -o "$MOUNT_OPTS,subvol=@" "$P2" /mnt
mkdir -p /mnt/home /mnt/.snapshots /mnt/var/log /mnt/var/cache \
         /mnt/var/lib/flatpak /mnt/boot/efi
mount -o "$MOUNT_OPTS,subvol=@home"            "$P2" /mnt/home
mount -o "$MOUNT_OPTS,subvol=@snapshots"       "$P2" /mnt/.snapshots
mount -o "$MOUNT_OPTS,subvol=@var_log"         "$P2" /mnt/var/log
mount -o "$MOUNT_OPTS,subvol=@var_cache"       "$P2" /mnt/var/cache
mount -o "$MOUNT_OPTS,subvol=@var_lib_flatpak" "$P2" /mnt/var/lib/flatpak
mount "$P1" /mnt/boot/efi

echo
echo "==> Phase 2b complete. Current layout:"
findmnt -R /mnt
echo
echo "Target disk : $DISK"
echo "ESP         : $P1  -> /mnt/boot/efi"
echo "Root btrfs  : $P2  -> /mnt (subvol=@)"
echo
echo "Next: bash phase3-debootstrap.sh"
