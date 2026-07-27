#!/usr/bin/env bash
#
# Phase 2b - Wipe and partition the Kingston target disk for Ubuntu 26.04
#
#   *** RUN FROM THE UBUNTU 26.04 LIVE SESSION ONLY ***
#   *** THIS DESTROYS ALL DATA ON THE KINGSTON DISK ***
#
# The Samsung disk (S6F5NL0TC03659) is NOT touched by this script.
# It keeps your data and these scripts until Phase 9.
#
# Usage:  sudo bash phase2b-partition-kingston.sh
#
set -euo pipefail

TARGET_SERIAL="50026B738450CE7B"
TARGET_MODEL="KINGSTON SNV3S1000G"
KEEP_SERIAL="S6F5NL0TC03659"          # Samsung - must never be touched here
MOUNT_OPTS="noatime,compress=zstd:3,ssd,discard=async,space_cache=v2"

[ "$(id -u)" -eq 0 ] || { echo "FATAL: run as root (sudo bash $0)" >&2; exit 1; }

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
DISK=""
for d in /dev/nvme?n? /dev/sd?; do
  [ -b "$d" ] || continue
  if [ "$(lsblk -dno SERIAL "$d" 2>/dev/null || true)" = "$TARGET_SERIAL" ]; then
    DISK="$d"; break
  fi
done

if [ -z "$DISK" ]; then
  echo "FATAL: no disk with serial $TARGET_SERIAL ($TARGET_MODEL) found." >&2
  echo "Attached disks:" >&2
  lsblk -dno NAME,SIZE,MODEL,SERIAL >&2
  exit 1
fi

# Paranoia: refuse to continue if we somehow resolved to the disk we must keep.
if [ "$(lsblk -dno SERIAL "$DISK")" = "$KEEP_SERIAL" ]; then
  echo "FATAL: resolved to the Samsung disk. Aborting." >&2
  exit 1
fi

case "$DISK" in
  *nvme*) P1="${DISK}p1"; P2="${DISK}p2" ;;
  *)      P1="${DISK}1";  P2="${DISK}2"  ;;
esac

# ------------------------------------------------------------------ confirmation
echo
echo "================================================================"
echo " TARGET (WILL BE COMPLETELY ERASED): $DISK"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DISK"
echo
echo " PRESERVED (not touched): serial $KEEP_SERIAL"
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
sgdisk -n1:0:+1G -t1:ef00 -c1:"EFI"         "$DISK"   # ESP, 1G
sgdisk -n2:0:0   -t2:8304 -c2:"ubuntu-root" "$DISK"   # Linux x86-64 root, rest
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
echo "Next: mount the Samsung disk to reach the remaining phase scripts:"
echo "  sudo mkdir -p /mnt-old"
echo "  sudo mount -o subvol=@home UUID=bc8fb1bb-a4a5-4fa6-a76b-d89047b401bb /mnt-old"
echo "  ls /mnt-old/baris/Ubuntu/"
