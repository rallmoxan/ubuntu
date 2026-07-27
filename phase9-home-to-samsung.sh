#!/usr/bin/env bash
#
# Phase 9 - the deferred Samsung wipe. RUN ON THE BOOTED UBUNTU, not the live USB.
#
#   sudo bash phase9-home-to-samsung.sh restore   # pull old files off the Samsung
#   sudo bash phase9-home-to-samsung.sh migrate   # wipe Samsung, move /home onto it
#
# Do 'restore' first, check you have what you want, only then 'migrate'.
# Until 'migrate' runs, the Samsung still holds the ONLY copy of your old data.
#
set -euo pipefail

KEEP_SERIAL="S6F5NL0TC03659"                              # Samsung
OLD_UUID="bc8fb1bb-a4a5-4fa6-a76b-d89047b401bb"           # old btrfs on the Samsung
MOUNT_OPTS="noatime,compress=zstd:3,ssd,discard=async,space_cache=v2"
OLDMNT="/mnt/old-home"

[ "$(id -u)" -eq 0 ] || { echo "FATAL: run as root" >&2; exit 1; }
ACTION="${1:-}"

resolve_samsung() {
  local d
  for d in /dev/nvme?n? /dev/sd?; do
    [ -b "$d" ] || continue
    if [ "$(lsblk -dno SERIAL "$d" 2>/dev/null || true)" = "$KEEP_SERIAL" ]; then
      echo "$d"; return 0
    fi
  done
  return 1
}

# ===========================================================================
case "$ACTION" in

restore)
  echo "==> Mounting the old Samsung home at $OLDMNT (read-only)"
  mkdir -p "$OLDMNT"
  mountpoint -q "$OLDMNT" || mount -o ro,subvol=@home "UUID=$OLD_UUID" "$OLDMNT"

  echo
  echo "Old data is now visible at: $OLDMNT"
  ls -la "$OLDMNT" || true
  cat <<EOF

Copy what you want, for example:

    sudo rsync -aHAX --info=progress2 \\
        $OLDMNT/baris/.mozilla \\
        $OLDMNT/baris/.thunderbird \\
        $OLDMNT/baris/.ssh \\
        $OLDMNT/baris/Documents \\
        $OLDMNT/baris/Pictures \\
        /home/\$SUDO_USER/

    sudo chown -R \$SUDO_USER:\$SUDO_USER /home/\$SUDO_USER

Deliberately not copying .config or .cache: Debian GNOME 4x settings dropped
into Ubuntu GNOME 50 is a common source of a broken-looking desktop. Copy
individual app directories out of $OLDMNT/baris/.config if you need them.

When you are satisfied:  sudo bash $0 migrate

EOF
  ;;

# ===========================================================================
migrate)
  # Never hold /home busy from our own working directory.
  cd /

  DISK="$(resolve_samsung)" || { echo "FATAL: Samsung ($KEEP_SERIAL) not found" >&2; exit 1; }
  case "$DISK" in *nvme*) PART="${DISK}p1" ;; *) PART="${DISK}1" ;; esac

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
  echo " ABOUT TO ERASE: $DISK  (serial $KEEP_SERIAL)"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DISK"
  echo
  echo " Everything still on it, including the old @home, is destroyed."
  echo " Current /home (on the Kingston) will be copied onto it afterwards."
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
  echo "    The now-unused @home subvolume on the Kingston can be reclaimed later:"
  echo "      sudo btrfs subvolume delete /path/to/mounted/top-level/@home"
  echo "    (only after you have verified the new /home works)"
  ;;

# ===========================================================================
*)
  echo "Usage: sudo bash $0 restore   # mount old Samsung home, copy files out"
  echo "       sudo bash $0 migrate   # wipe Samsung, move /home onto it"
  exit 1
  ;;
esac
