#!/usr/bin/env bash
#
# Phase 4 + 5 - System core, and the snap block.
#   RUN INSIDE THE CHROOT.  bash /root/install/phase4-core.sh
#
# Phase 5 (snap eradication) is deliberately fused into the front of this
# script: the APT pin MUST exist before the first `apt-get install`, otherwise
# a recommended snapd can slip in and pull /snap mounts into the image.
#
set -euo pipefail

# ============================== EDIT THESE ==================================
HOSTNAME="barzbug"
USERNAME="baris"
USER_UID="1000"                 # keeps ownership compatible with the old /home
TIMEZONE="Europe/Istanbul"      # confirmed
LOCALE="en_US.UTF-8"
KEYMAP="us"                     # console + X keyboard layout
RELEASE="resolute"
MIRROR="http://archive.ubuntu.com/ubuntu/"
# ============================================================================

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

[ "$(id -u)" -eq 0 ] || { echo "FATAL: must run as root inside the chroot" >&2; exit 1; }
[ -e /etc/fstab ]    || { echo "FATAL: /etc/fstab missing - Phase 3 did not complete" >&2; exit 1; }
grep -qE '^\S+\s+/\s+btrfs' /etc/fstab || { echo "FATAL: no root entry in /etc/fstab" >&2; exit 1; }

# Install only what actually exists in the archive, and say what it skipped,
# instead of aborting the whole run on one renamed package.
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

# ---------------------------------------------------- keep daemons from starting
# Services must not try to start inside the chroot; 101 tells the maintainer
# scripts "do not run". Phase 8 removes this file.
cat > /usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x /usr/sbin/policy-rc.d

# =========================== PHASE 5: BLOCK SNAP ============================
echo "==> Installing the snap block BEFORE any package is installed"
mkdir -p /etc/apt/preferences.d
cat > /etc/apt/preferences.d/nosnap.pref <<'EOF'
# No-snap policy. Priority -1 means "never install, not even as a dependency".
#
# The list below is not "the snap things we plan to install". It is every
# package in the resolute archive with a HARD dependency on snapd - Depends or
# Pre-Depends, alternatives excluded - plus the frontends whose only job is
# talking to snapd. Enumerated from the archive indices, not from memory:
#
#   apt-cache rdepends snapd \
#     | awk '/Reverse Depends:/{f=1;next} f{gsub(/^[ |]+/,""); print $1}' \
#     | sort -u \
#     | while read -r p; do
#         apt-cache depends "$p" | grep -qE '^ +(Pre)?Depends: snapd$' && echo "$p"
#       done
#
# Blocking packages this desktop will never intentionally install is the point.
# A no-snap system should not depend on remembering never to type
# `apt install thunderbird`.

# --- snapd itself, and the machinery that exists only to serve it -----------
Package: snapd snapd-seed-glue snapd-installation-monitor
Pin: release *
Pin-Priority: -1

# --- snap store frontends ---------------------------------------------------
# fwupd-snap Pre-Depends on snapd; the rest are store plugins.
Package: gnome-software-plugin-snap plasma-discover-backend-snap fwupd-snap
Pin: release *
Pin-Priority: -1

# --- server/cloud/image metapackages that hard-depend on snapd --------------
# None of these belong on a desktop, but ubuntu-server-minimal in particular is
# an easy thing to type by accident, and it would drag snapd in as a Depends.
Package: ubuntu-server-minimal ubuntu-cloud-minimal livecd-rootfs
Pin: release *
Pin-Priority: -1

# --- Ubuntu's browser/mail "debs" that are only snap installers -------------
# firefox    1:1snap1-0ubuntu8  Pre-Depends: snapd
# thunderbird 2:1snap1-0ubuntu5 Pre-Depends: snapd
# Note the different epochs: 1 vs 2. That is exactly why these are pinned by
# ORIGIN and not by version string - a `Pin: version 1:1snap1*` pin never
# matched thunderbird at all, and stops matching firefox the day Ubuntu bumps
# the shim. o=Ubuntu blocks every version the Ubuntu archive will ever ship.
# Mozilla's repo is Origin: Mozilla and the Mozilla Team PPA is
# Origin: LP-PPA-mozillateam, so the real debs remain installable.
Package: firefox thunderbird
Pin: release o=Ubuntu
Pin-Priority: -1

# chromium-browser is an Ubuntu-only package name and always the shim, so it is
# blocked outright rather than per-origin. Real Chromium debs elsewhere are
# named 'chromium' or 'ungoogled-chromium'; Flathub is the easy route.
Package: chromium-browser
Pin: release *
Pin-Priority: -1
EOF

# ------------------------------------------------------------- APT sources
echo "==> Writing deb822 APT sources for $RELEASE"
rm -f /etc/apt/sources.list
mkdir -p /etc/apt/sources.list.d
cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: $MIRROR
Suites: $RELEASE $RELEASE-updates $RELEASE-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: $RELEASE-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

apt-get update
apt-get -y upgrade

# Prove the pin works before we build anything on top of it. Every name in
# nosnap.pref is checked, not just snapd: the stanzas use the space-separated
# multi-package form, so one bad name or one unsupported syntax would silently
# leave part of the list unpinned until the day it mattered.
#
# Firefox and thunderbird are expected to be blocked HERE too - Mozilla's repo
# does not exist yet at this point in the install, so the only candidate on
# offer is Ubuntu's shim, and it must be refused.
echo "==> Verifying every pin in nosnap.pref"
PIN_FAIL=0
for pkg in snapd snapd-seed-glue snapd-installation-monitor \
           gnome-software-plugin-snap plasma-discover-backend-snap fwupd-snap \
           ubuntu-server-minimal ubuntu-cloud-minimal livecd-rootfs \
           firefox thunderbird chromium-browser; do
  cand="$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/{print $2}')"
  if [ -z "$cand" ]; then
    echo "    $pkg: not in this archive at all"
  elif [ "$cand" = "(none)" ]; then
    echo "    $pkg: blocked  OK"
  else
    echo "    !!!! $pkg: candidate is $cand - NOT blocked" >&2
    PIN_FAIL=1
  fi
done
if [ "$PIN_FAIL" -ne 0 ]; then
  echo "FATAL: nosnap.pref is not fully effective. Stopping before anything can" >&2
  echo "       be built on top of a broken pin." >&2
  exit 1
fi
apt-mark hold snapd 2>/dev/null || true

# ------------------------------------------------ preseed the interactive bits
debconf-set-selections <<EOF
tzdata tzdata/Areas select ${TIMEZONE%%/*}
tzdata tzdata/Zones/${TIMEZONE%%/*} select ${TIMEZONE##*/}
keyboard-configuration keyboard-configuration/layoutcode string $KEYMAP
keyboard-configuration keyboard-configuration/modelcode string pc105
keyboard-configuration keyboard-configuration/xkb-keymap select $KEYMAP
console-setup console-setup/charmap47 select UTF-8
console-setup console-setup/codeset47 select . Combined - Latin; Slavic Cyrillic; Greek
EOF

# ------------------------------------------------------------- base system
echo "==> Installing the Ubuntu base (both metapackages are snapd-free)"
apt_install --no-install-recommends ubuntu-minimal ubuntu-standard

apt_install --no-install-recommends \
  locales tzdata console-setup keyboard-configuration \
  ca-certificates curl wget gpg \
  btrfs-progs dosfstools zstd \
  nano vim less bash-completion \
  software-properties-common apt-transport-https \
  systemd-resolved

# ------------------------------------------------------------------ locale
echo "==> Locale: $LOCALE"
sed -i "s/^# *\(${LOCALE} UTF-8\)/\1/" /etc/locale.gen
grep -q "^${LOCALE} UTF-8" /etc/locale.gen || echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
update-locale LANG="$LOCALE"

# ---------------------------------------------------------------- timezone
echo "==> Timezone: $TIMEZONE"
[ -e "/usr/share/zoneinfo/$TIMEZONE" ] || { echo "FATAL: unknown timezone $TIMEZONE" >&2; exit 1; }
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
echo "$TIMEZONE" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata

# ---------------------------------------------------------------- keyboard
cat > /etc/default/keyboard <<EOF
XKBMODEL="pc105"
XKBLAYOUT="$KEYMAP"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
dpkg-reconfigure -f noninteractive keyboard-configuration || true

# -------------------------------------------------------- hostname & hosts
echo "==> Hostname: $HOSTNAME"
echo "$HOSTNAME" > /etc/hostname
# The 127.0.1.1 line matters: without it sudo and GNOME stall on name lookups.
cat > /etc/hosts <<EOF
127.0.0.1       localhost
127.0.1.1       $HOSTNAME
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

# -------------------------------------------------------------- machine-id
echo "==> machine-id"
rm -f /etc/machine-id /var/lib/dbus/machine-id
systemd-machine-id-setup
mkdir -p /var/lib/dbus
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# ------------------------------------------------------------------- users
echo "==> Creating user '$USERNAME' (uid $USER_UID)"
if ! id -u "$USERNAME" >/dev/null 2>&1; then
  useradd -m -u "$USER_UID" -s /bin/bash -c "$USERNAME" "$USERNAME"
fi
# Fail here rather than let the phase report success and leave you with a
# system that has no account to log in as.
id -u "$USERNAME" >/dev/null 2>&1 \
  || { echo "FATAL: could not create user '$USERNAME'." >&2; exit 1; }
for g in sudo adm dialout cdrom floppy audio dip video plugdev users lpadmin netdev render input; do
  getent group "$g" >/dev/null 2>&1 && usermod -aG "$g" "$USERNAME"
done
echo "    groups: $(id -nG "$USERNAME")"

# Retry on typos instead of aborting the whole phase at the last step.
#
# The tty guard is not theoretical: `passwd` calls tcflush() and discards any
# input that arrived before its prompt, so when stdin is not a terminal it sits
# on "New password:" forever. Discovered by running this phase under automation
# in a VM, where it blocked indefinitely with no error. In a normal terminal
# this branch never triggers.
set_password() {
  local who="$1" i
  if [ ! -t 0 ]; then
    echo
    echo "!! stdin is not a terminal - cannot prompt for '$who' password."
    echo "!! Skipping. Before you leave the chroot you MUST run:  passwd $who"
    echo "!! verify-before-reboot.sh will FAIL until you do."
    return 1
  fi
  for i in 1 2 3; do
    echo
    echo "############################################################"
    echo "# Password for: $who   (attempt $i of 3)"
    echo "############################################################"
    if passwd "$who"; then return 0; fi
    echo "    -> did not take, try again"
  done
  echo "!! Could not set the password for '$who'."
  echo "!! Run 'passwd $who' by hand before you leave the chroot -"
  echo "!! an account with no password cannot log in through GDM."
  return 1
}

set_password "$USERNAME" || true
set_password root || true

echo
echo "==> Phase 4+5 complete. Next: bash /root/install/phase6-kernel.sh"
