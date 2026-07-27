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
Package: snapd
Pin: release *
Pin-Priority: -1

Package: snapd-seed-glue
Pin: release *
Pin-Priority: -1

Package: gnome-software-plugin-snap
Pin: release *
Pin-Priority: -1

# Ubuntu's 'firefox' deb in 26.04 is version 1:1snap1 and does nothing but
# install the Firefox snap. Phase 7 replaces it with Mozilla's real .deb.
Package: firefox
Pin: version 1:1snap1*
Pin-Priority: -1

# Same trick for Chromium.
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

# Prove the pin works before we build anything on top of it.
SNAP_PRIO="$(apt-cache policy snapd | awk '/Candidate:/{print $2}')"
echo "==> snapd candidate is now: $SNAP_PRIO  (must be '(none)')"
if [ "$SNAP_PRIO" != "(none)" ]; then
  echo "FATAL: the snapd pin is not effective. Stopping before it can be pulled in." >&2
  apt-cache policy snapd >&2
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
