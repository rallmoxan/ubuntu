#!/usr/bin/env bash
#
# Phase 3 - Debootstrap Ubuntu 26.04 (resolute) into /mnt, write fstab,
#           bind virtual filesystems, stage the remaining scripts.
#
#   RUN FROM THE UBUNTU 26.04 LIVE SESSION, AFTER phase2b.
#   Usage: sudo bash phase3-debootstrap.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"

[ "$(id -u)" -eq 0 ] || { echo "FATAL: run as root (sudo bash $0)" >&2; exit 1; }

# ------------------------------------------------------------ sanity checks
echo "==> Verifying the Phase 2b layout is mounted"
findmnt -no TARGET /mnt          >/dev/null || { echo "FATAL: /mnt not mounted. Run phase2b first." >&2; exit 1; }
findmnt -no TARGET /mnt/boot/efi >/dev/null || { echo "FATAL: /mnt/boot/efi not mounted." >&2; exit 1; }

case "$(findmnt -no OPTIONS /mnt)" in
  *subvol=/@,*|*subvol=/@) : ;;
  *) echo "FATAL: /mnt is not mounted with subvol=@. Re-run phase2b." >&2
     findmnt -no SOURCE,OPTIONS /mnt >&2; exit 1 ;;
esac

echo "==> Checking network"
getent hosts archive.ubuntu.com >/dev/null || { echo "FATAL: no DNS/network in the live session." >&2; exit 1; }

# debootstrap downloads with wget, and wget has no Happy Eyeballs fallback: on a
# network that advertises IPv6 but cannot actually reach the archive over it,
# wget hangs forever on "Retrieving InRelease" rather than failing over to IPv4.
# curl hides this, so a working `curl archive.ubuntu.com` proves nothing here.
# Measured on this machine: plain wget hangs, `wget -4` returns instantly.
FORCE_IPV4=0
echo "==> Testing that wget itself can reach the archive"
if timeout 30 wget -q -O /dev/null "${MIRROR}dists/${RELEASE}/InRelease" 2>/dev/null; then
  echo "    wget works as-is"
elif timeout 30 wget -4 -q -O /dev/null "${MIRROR}dists/${RELEASE}/InRelease" 2>/dev/null; then
  echo "    !! IPv6 path is broken here - forcing IPv4 for wget and apt"
  grep -qs '^inet4_only' /etc/wgetrc || echo 'inet4_only = on' >> /etc/wgetrc
  FORCE_IPV4=1
else
  echo "FATAL: cannot fetch ${MIRROR} over IPv4 either. Fix the network first." >&2
  exit 1
fi

# wget's defaults never give up on a stalled connection, so one bad mirror
# socket hangs the whole bootstrap with no error. Observed in testing: the
# run froze mid-package with no output and no timeout. Bound it.
if ! grep -qs '^timeout' /etc/wgetrc; then
  printf 'timeout = 30\ntries = 5\nwaitretry = 5\n' >> /etc/wgetrc
  echo "    added wget timeout/retry limits (a stalled mirror now retries instead of hanging)"
fi

# ------------------------------------------------------- debootstrap itself
echo "==> Ensuring debootstrap knows the '$RELEASE' release"
apt-get update -qq
apt-get install -y -qq debootstrap ubuntu-keyring
# Older debootstrap versions have no script for a brand-new release. gutsy is
# Ubuntu's generic profile and is what Ubuntu itself symlinks new releases to.
if [ ! -e "/usr/share/debootstrap/scripts/$RELEASE" ]; then
  echo "    '$RELEASE' script missing -> symlinking to gutsy"
  ln -sf gutsy "/usr/share/debootstrap/scripts/$RELEASE"
fi

# /mnt/debootstrap only exists while a bootstrap is in progress; debootstrap
# removes it on success. Without this check, a run that was interrupted or that
# stalled and got killed leaves a half-populated rootfs that still has
# /bin/bash and /etc/os-release - and we would happily "skip" it and build a
# broken system on top.
if [ -d /mnt/debootstrap ]; then
  echo "FATAL: /mnt holds an INCOMPLETE debootstrap from an earlier run." >&2
  echo "       Start clean - re-run phase2b (it reformats), or remove the tree:" >&2
  echo "         umount -R /mnt   # then re-run phase2b-partition.sh" >&2
  exit 1
fi

if [ -x /mnt/bin/bash ] && [ -e /mnt/etc/os-release ]; then
  echo "==> Base system already present and complete in /mnt, skipping debootstrap"
else
  echo "==> Running debootstrap ($RELEASE). This takes several minutes."
  debootstrap \
    --arch=amd64 \
    --components=main,restricted,universe,multiverse \
    --keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg \
    "$RELEASE" /mnt "$MIRROR"
fi

[ -x /mnt/bin/bash ] || { echo "FATAL: debootstrap produced no usable rootfs." >&2; exit 1; }

# debootstrap's default variant pulls Priority: required + important, which
# includes ubuntu-keyring and systemd-sysv. Verify rather than assume: without
# the keyring, Phase 4's `apt-get update` dies on NO_PUBKEY.
if [ ! -e /mnt/usr/share/keyrings/ubuntu-archive-keyring.gpg ]; then
  echo "    keyring missing in target -> copying from the live session"
  mkdir -p /mnt/usr/share/keyrings
  cp /usr/share/keyrings/ubuntu-archive-keyring.gpg /mnt/usr/share/keyrings/
fi
[ -e /mnt/sbin/init ] || [ -L /mnt/sbin/init ] \
  || echo "    WARNING: /sbin/init absent in the target; Phase 4 installs it via ubuntu-minimal"

# ------------------------------------------------------------------- fstab
# THIS IS THE STEP THAT PREVENTS A READ-ONLY ROOT ON FIRST BOOT.
# systemd only remounts / read-write if / has an entry in /etc/fstab.
# A missing or wrong root line is the #1 cause of "my new system booted read-only".
echo "==> Generating /etc/fstab from the live mounts"

ROOT_SRC="$(findmnt -no SOURCE /mnt | sed 's/\[.*//')"     # strip the [/@] suffix
ESP_SRC="$(findmnt -no SOURCE /mnt/boot/efi)"
# -c /dev/null bypasses the blkid cache. These filesystems were created minutes
# ago; a cached entry from the old layout would write the wrong UUID into fstab.
ROOT_UUID="$(blkid -c /dev/null -s UUID -o value "$ROOT_SRC")"
ESP_UUID="$(blkid -c /dev/null -s UUID -o value "$ESP_SRC")"

[ -n "$ROOT_UUID" ] || { echo "FATAL: could not read root UUID from $ROOT_SRC" >&2; exit 1; }
[ -n "$ESP_UUID"  ] || { echo "FATAL: could not read ESP UUID from $ESP_SRC"   >&2; exit 1; }

echo "    root  $ROOT_SRC  UUID=$ROOT_UUID"
echo "    esp   $ESP_SRC   UUID=$ESP_UUID"

mkdir -p /mnt/etc
cat > /mnt/etc/fstab <<EOF
# /etc/fstab - Ubuntu 26.04 (debootstrap, no-snap)
# <file system>  <mount point>  <type>  <options>  <dump>  <pass>
#
# 'rw' on the root line is stated explicitly on purpose: without a root entry
# here systemd cannot remount / read-write and the system boots read-only.
# btrfs has no boot-time fsck, so pass must be 0 for every btrfs line.

UUID=$ROOT_UUID  /                 btrfs  rw,$MOUNT_OPTS,subvol=@                 0 0
UUID=$ROOT_UUID  /home             btrfs  rw,$MOUNT_OPTS,subvol=@home             0 0
UUID=$ROOT_UUID  /.snapshots       btrfs  rw,$MOUNT_OPTS,subvol=@snapshots        0 0
UUID=$ROOT_UUID  /var/log          btrfs  rw,$MOUNT_OPTS,subvol=@var_log          0 0
UUID=$ROOT_UUID  /var/cache        btrfs  rw,$MOUNT_OPTS,subvol=@var_cache        0 0
UUID=$ROOT_UUID  /var/lib/flatpak  btrfs  rw,$MOUNT_OPTS,subvol=@var_lib_flatpak  0 0

# ESP. pass=0 deliberately: fsck.vfat failing at boot can drop you to emergency
# mode, and there is nothing here worth that risk.
UUID=$ESP_UUID   /boot/efi         vfat   umask=0077,shortname=mixed,utf8         0 0
EOF

echo "--------------------------------- /etc/fstab ---------------------------------"
cat /mnt/etc/fstab
echo "------------------------------------------------------------------------------"

# --------------------------------------------------------------- DNS in chroot
# Copy DEREFERENCED: the live session's /etc/resolv.conf is a symlink into
# /run/systemd/resolve/ which does not exist inside the fresh rootfs.
# Phase 8 replaces this with the real systemd-resolved symlink.
# If wget needed IPv4 forced, apt inside the chroot will hit the same broken
# IPv6 path on every download. Carry the workaround into the target.
if [ "$FORCE_IPV4" = "1" ]; then
  mkdir -p /mnt/etc/apt/apt.conf.d
  echo 'Acquire::ForceIPv4 "true";' > /mnt/etc/apt/apt.conf.d/99force-ipv4
  echo "    wrote /etc/apt/apt.conf.d/99force-ipv4 into the target"
fi

if cp --dereference /etc/resolv.conf /mnt/etc/resolv.conf 2>/dev/null \
   && [ -s /mnt/etc/resolv.conf ]; then
  echo "    resolv.conf copied from the live session"
else
  echo "    !! live resolv.conf unusable - writing a fallback resolver so apt works"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /mnt/etc/resolv.conf
fi

# ---------------------------------------------------------------- bind mounts
# --rbind (not --bind) so nested mounts like /dev/pts and
# /sys/firmware/efi/efivars come along. efivars is required for grub-install
# to write the UEFI boot entry. --make-rslave keeps unmounts from propagating
# back into the live session.
echo "==> Binding virtual filesystems"
for fs in dev proc sys run; do
  mkdir -p "/mnt/$fs"
  if ! mountpoint -q "/mnt/$fs"; then
    mount --rbind "/$fs" "/mnt/$fs"
    mount --make-rslave "/mnt/$fs"
  fi
done

if [ -d /sys/firmware/efi/efivars ]; then
  mountpoint -q /mnt/sys/firmware/efi/efivars \
    && echo "    efivars available in chroot: yes" \
    || echo "    WARNING: efivars not visible in chroot - grub-install may not create a UEFI entry"
fi

# -------------------------------------------------------------- stage scripts
echo "==> Copying the remaining phase scripts into /mnt/root/install/"
mkdir -p /mnt/root/install
cp -a "$SCRIPT_DIR"/. /mnt/root/install/
chmod +x /mnt/root/install/*.sh 2>/dev/null || true

# The chroot has no other copy of these. If the staging failed you would only
# find out after entering the chroot, with the live session no longer in reach.
# config.sh is in the list for the same reason: every chroot phase sources it.
for needed in config.sh phase4-core.sh phase6-kernel.sh phase7-desktop.sh \
              phase8-bootloader.sh verify-before-reboot.sh phase9-migrate-home.sh; do
  [ -s "/mnt/root/install/$needed" ] \
    || { echo "FATAL: $needed did not reach /mnt/root/install/" >&2; exit 1; }
done
echo "    staged: $(ls -1 /mnt/root/install/*.sh | wc -l) scripts"

cat <<'EOS'

==> Phase 3 complete.

Next, enter the chroot:

    sudo chroot /mnt /usr/bin/env -i \
        HOME=/root TERM="$TERM" PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        /bin/bash --login

Then, inside the chroot, run in order:

    bash /root/install/phase4-core.sh
    bash /root/install/phase6-kernel.sh
    bash /root/install/phase7-desktop.sh
    bash /root/install/phase8-bootloader.sh
    bash /root/install/verify-before-reboot.sh

EOS
