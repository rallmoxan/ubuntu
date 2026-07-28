#!/usr/bin/env bash
#
# Phase 9 - move /home onto a second disk. OPTIONAL.
#   RUN ON THE BOOTED UBUNTU, not the live USB.
#
#   sudo bash phase9-migrate-home.sh restore   # mount the old disk, copy files off
#   sudo bash phase9-migrate-home.sh migrate   # WIPE it, move /home onto it
#
# The intended shape: you replaced an older install, its disk still holds the
# only copy of your data, and you want that disk to become the new /home once
# you have taken what you need off it.
#
# Do 'restore' first, check you have what you want, only then 'migrate'.
# Until 'migrate' runs, that disk holds the ONLY copy of your old data.
#
# Skip this phase entirely if you have one disk. Nothing else depends on it.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"

OLDMNT="/mnt/old-home"

[ "$(id -u)" -eq 0 ] || { echo "FATAL: run as root" >&2; exit 1; }
ACTION="${1:-}"
require_config MIGRATE_DISK_SERIAL

# Account name inside the old filesystem. Usually the same as the new one.
OLD_USER="${OLD_HOME_USER:-$USERNAME}"

# "auto" means: find the btrfs on the configured disk and use its UUID. One
# less thing to copy by hand, and a UUID typo would mount the wrong filesystem.
resolve_old_uuid() {
  if [ "$OLD_HOME_UUID" != "auto" ] && [ -n "$OLD_HOME_UUID" ]; then
    echo "$OLD_HOME_UUID"; return 0
  fi
  local disk part uuid
  disk="$(resolve_disk_by_serial "$MIGRATE_DISK_SERIAL")" || return 1
  for part in "${disk}"p* "${disk}"[0-9]*; do
    [ -b "$part" ] || continue
    [ "$(blkid -s TYPE -o value "$part" 2>/dev/null || true)" = "btrfs" ] || continue
    uuid="$(blkid -s UUID -o value "$part" 2>/dev/null || true)"
    [ -n "$uuid" ] && { echo "$uuid"; return 0; }
  done
  return 1
}

# ===========================================================================
case "$ACTION" in

restore)
  OLD_UUID="$(resolve_old_uuid)" || {
    echo "FATAL: no btrfs filesystem found on the disk with serial $MIGRATE_DISK_SERIAL." >&2
    echo "       Set OLD_HOME_UUID in config.sh explicitly if it is not btrfs" >&2
    echo "       or lives somewhere this cannot guess. Filesystems seen:" >&2
    lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID >&2
    exit 1
  }

  echo "==> Mounting the old home at $OLDMNT (read-only)"
  echo "    UUID=$OLD_UUID  subvol=$OLD_HOME_SUBVOL"
  mkdir -p "$OLDMNT"
  mountpoint -q "$OLDMNT" \
    || mount -o "ro,subvol=$OLD_HOME_SUBVOL" "UUID=$OLD_UUID" "$OLDMNT" \
    || { echo "FATAL: could not mount UUID=$OLD_UUID with subvol=$OLD_HOME_SUBVOL." >&2
         echo "       If the old filesystem has no subvolumes, set OLD_HOME_SUBVOL=/ in config.sh." >&2
         exit 1; }

  echo
  echo "Old data is now visible at: $OLDMNT"
  ls -la "$OLDMNT" || true
  cat <<EOF

Copy what you want, for example:

    sudo rsync -aHAX --info=progress2 \\
        $OLDMNT/$OLD_USER/.mozilla \\
        $OLDMNT/$OLD_USER/.ssh \\
        $OLDMNT/$OLD_USER/Documents \\
        $OLDMNT/$OLD_USER/Pictures \\
        /home/\$SUDO_USER/

    sudo chown -R \$SUDO_USER:\$SUDO_USER /home/\$SUDO_USER

Deliberately not copying .config or .cache wholesale: another distribution's
GNOME settings dropped into this one is a common source of a broken-looking
desktop. Take individual app directories out of $OLDMNT/$OLD_USER/.config
if you need them.

Thunderbird, if you installed the Flatpak: its profile lives under
~/.var/app/${THUNDERBIRD_REF%%/*}/.thunderbird, NOT ~/.thunderbird.
Copy the old profile there, not to the home directory root.

When you are satisfied:  sudo bash $0 migrate

EOF
  ;;

# ===========================================================================
migrate)
  # Preflight BEFORE anything destructive, and this matters more than a
  # missing-command check usually does: the wipe below runs `wipefs -a` and
  # only then sgdisk. A missing sgdisk therefore used to abort with the
  # partition table signatures ALREADY gone - after the operator had typed
  # ERASE. Check the whole toolchain up front instead of discovering it
  # halfway through.
  #
  # gdisk is installed by Phase 4 on systems built after this was written.
  # An older build will not have it, which is exactly how this was found.
  MISSING=""
  MISSING_PKGS=""
  for pair in "sgdisk:gdisk" "wipefs:util-linux" "partprobe:parted" \
              "udevadm:udev" "mkfs.btrfs:btrfs-progs" "btrfs:btrfs-progs" \
              "rsync:rsync" "fuser:psmisc" "lsblk:util-linux" "findmnt:util-linux"; do
    tool="${pair%%:*}"; pkg="${pair##*:}"
    command -v "$tool" >/dev/null 2>&1 && continue
    MISSING="$MISSING $tool"
    case " $MISSING_PKGS " in
      *" $pkg "*) ;;
      *) MISSING_PKGS="$MISSING_PKGS $pkg" ;;
    esac
  done
  if [ -n "$MISSING" ]; then
    echo "FATAL: missing command(s):$MISSING" >&2
    echo "       Nothing has been touched. Install and re-run:" >&2
    echo "           sudo apt install$MISSING_PKGS" >&2
    exit 1
  fi

  # Never hold /home busy from our own working directory.
  cd /

  DISK="$(resolve_disk_by_serial "$MIGRATE_DISK_SERIAL")" || {
    echo "FATAL: no disk with serial $MIGRATE_DISK_SERIAL found." >&2
    show_disks
    exit 1
  }
  PART="$(partition_node "$DISK" 1)"

  # Refuse to wipe the disk we are booted from.
  ROOT_SRC="$(findmnt -no SOURCE / | sed 's/\[.*//')"
  ROOT_DISK="/dev/$(lsblk -no PKNAME "$ROOT_SRC")"
  [ "$DISK" = "$ROOT_DISK" ] && { echo "FATAL: that is the running root disk. Aborting." >&2; exit 1; }

  # /home must not be in use.
  if fuser -m /home >/dev/null 2>&1; then
    echo "FATAL: processes are using /home. Log out of the desktop first:" >&2
    echo "       sudo systemctl isolate multi-user.target" >&2
    echo "       then log in on the text console as root and re-run this." >&2
    exit 1
  fi

  echo "================================================================"
  echo " ABOUT TO ERASE: $DISK  (serial $MIGRATE_DISK_SERIAL)"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DISK"
  echo
  echo " Everything still on it, including the old @home, is destroyed."
  echo " The current /home is copied onto it afterwards."
  echo "================================================================"
  read -r -p "Type ERASE to proceed: " C
  [ "$C" = "ERASE" ] || { echo "Aborted."; exit 1; }

  umount -R "$OLDMNT" 2>/dev/null || true

  echo "==> Partitioning $DISK"
  wipefs -a "$DISK"
  sgdisk --zap-all "$DISK"
  sgdisk -n1:0:0 -t1:8302 -c1:"home" "$DISK"        # 8302 = Linux /home
  partprobe "$DISK"; udevadm settle; sleep 2

  echo "==> Creating btrfs + @home"
  mkfs.btrfs -f -L home "$PART"
  mkdir -p /mnt/newhome
  mount -o "$MOUNT_OPTS" "$PART" /mnt/newhome
  btrfs subvolume create /mnt/newhome/@home
  umount /mnt/newhome
  mount -o "$MOUNT_OPTS,subvol=@home" "$PART" /mnt/newhome

  echo "==> Copying /home -> new disk"
  rsync -aHAX --info=progress2 /home/ /mnt/newhome/

  SRC_N="$(find /home -mindepth 1 -maxdepth 1 | wc -l)"
  DST_N="$(find /mnt/newhome -mindepth 1 -maxdepth 1 | wc -l)"
  echo "    top-level entries: source $SRC_N, destination $DST_N"
  [ "$SRC_N" -eq "$DST_N" ] || { echo "FATAL: copy mismatch, fstab NOT changed." >&2; exit 1; }

  NEW_UUID="$(blkid -s UUID -o value "$PART")"
  [ -n "$NEW_UUID" ] || { echo "FATAL: no UUID on $PART" >&2; exit 1; }

  echo "==> Updating /etc/fstab (backup at /etc/fstab.bak)"
  cp /etc/fstab /etc/fstab.bak
  # drop the old /home line, append the new one
  awk '!($2=="/home" && $1 !~ /^#/)' /etc/fstab.bak > /etc/fstab
  printf 'UUID=%s  /home  btrfs  rw,%s,subvol=@home  0 0\n' "$NEW_UUID" "$MOUNT_OPTS" >> /etc/fstab

  echo "--------------------------- new /etc/fstab ---------------------------"
  cat /etc/fstab
  echo "----------------------------------------------------------------------"

  umount /mnt/newhome
  echo
  echo "==> Done. Reboot, then confirm with:  findmnt /home"
  echo "    It must show $PART with subvol=/@home."
  echo
  echo "    The now-unused @home subvolume on the root disk can be reclaimed later:"
  echo "      sudo btrfs subvolume delete /path/to/mounted/top-level/@home"
  echo "    (only after you have verified the new /home works)"
  ;;

# ===========================================================================
*)
  echo "Usage: sudo bash $0 restore   # mount the old disk read-only, copy files out"
  echo "       sudo bash $0 migrate   # WIPE it, move /home onto it"
  exit 1
  ;;
esac
