#!/usr/bin/env bash
#
# Shared configuration for every phase. EDIT THIS FILE, then run the phases in
# order. Nothing else needs changing for a normal install.
#
# This file is sourced, not executed. Phase 3 copies it into the target at
# /root/install/config.sh so the chroot phases read the same values.
#
# shellcheck disable=SC2034

# ============================================================================
# REQUIRED - the install refuses to start until these are set
# ============================================================================

# Serial number of the disk to WIPE and install onto. Identified by serial, not
# by /dev/nvme0n1, because device names enumerate differently between the live
# kernel and the installed one - the wrong name here means the wrong disk dies.
#
# List what is attached:
#     lsblk -dno NAME,SIZE,MODEL,SERIAL
#
# Leave empty and any phase that touches disks will print that list and stop.
TARGET_DISK_SERIAL=""

# Login account created in Phase 4. The install asks for its password.
USERNAME=""

# ============================================================================
# SYSTEM - sensible defaults, change if you like
# ============================================================================

HOSTNAME="ubuntu-nosnap"
USER_UID="1000"                  # 1000 keeps ownership compatible with an old /home
TIMEZONE="Europe/Istanbul"       # timedatectl list-timezones
LOCALE="en_US.UTF-8"
KEYMAP="us"                      # console + X keyboard layout

RELEASE="resolute"               # Ubuntu 26.04 LTS
MIRROR="http://archive.ubuntu.com/ubuntu/"

# btrfs mount options used everywhere. compress=zstd:3 is a good default on
# NVMe; drop 'ssd,discard=async' on spinning rust.
MOUNT_OPTS="noatime,compress=zstd:3,ssd,discard=async,space_cache=v2"

# ESP size. 1G is generous; it costs nothing and spares you from a full ESP
# three kernels from now.
ESP_SIZE="1G"

# ============================================================================
# HARDWARE - "auto" detects, or force a value
# ============================================================================

# auto | amd | intel | none        -> amd64-microcode / intel-microcode
CPU_VENDOR="auto"

# auto | amd | intel | nvidia | none
#
# amd and intel are fully handled: Mesa, Vulkan, VA-API. nvidia is NOT
# auto-installed - the proprietary driver choice depends on the card's age and
# on whether you want Secure Boot signing, so Phase 6 prints the command and
# leaves the decision to you.
GPU_VENDOR="auto"

# ============================================================================
# DESKTOP
# ============================================================================

# ubuntu = ubuntu-desktop-minimal with --no-install-recommends. The real Ubuntu
#          desktop, dock and all. Pulls gir1.2-snapd-2 (a GLib binding, not
#          snapd) via gnome-shell-ubuntu-extensions.
# pure   = GNOME assembled from components. No Ubuntu Dock, no desktop icons.
# none   = no desktop at all; skip Phase 7.
DESKTOP_MODE="ubuntu"

# firefox-esr = Extended Support Release, one major version a year.
# firefox     = rapid release, a new major version every ~4 weeks.
#
# Both come from Mozilla's own APT repo. Ubuntu's archive has no usable Firefox
# deb at all - theirs is a snap installer, pinned out in Phase 5.
FIREFOX_CHANNEL="firefox-esr"

# flatpak = install THUNDERBIRD_REF from Flathub at the end of Phase 7.
# no      = skip it.
INSTALL_THUNDERBIRD="flatpak"

# org.mozilla.thunderbird_esr is the ESR line; org.mozilla.Thunderbird is the
# regular one. Separate app IDs, not branches - and ~/.var/app is keyed on the
# ID, so the two do not share a profile directory.
THUNDERBIRD_REF="org.mozilla.thunderbird_esr"

# Dock/favourites are generated from what actually got installed. Ubuntu's own
# default list points at snap desktop files that do not exist here, which
# leaves a dock full of nothing. Set to "no" to keep Ubuntu's list.
GENERATE_FAVORITES="yes"

# ============================================================================
# PHASE 9 (optional) - move /home onto a second disk
# ============================================================================
#
# Only relevant if you are replacing an older install and want its disk to
# become the new /home. Phase 9 does nothing until MIGRATE_DISK_SERIAL is set,
# and it is a separate manual step run after the system boots.
#
#   restore  mounts the old disk read-only so you can copy files off it
#   migrate  WIPES that disk, recreates btrfs + @home, moves /home onto it
#
# Leave MIGRATE_DISK_SERIAL empty if you have only one disk.
MIGRATE_DISK_SERIAL=""

# btrfs UUID of the old filesystem to mount for 'restore'. "auto" finds it from
# MIGRATE_DISK_SERIAL. Set it explicitly only if that disk holds several
# filesystems and you need a specific one.
OLD_HOME_UUID="auto"

# Subvolume and account name inside the old filesystem, used to build the
# example copy commands 'restore' prints. Empty OLD_HOME_USER means $USERNAME.
OLD_HOME_SUBVOL="@home"
OLD_HOME_USER=""

# ============================================================================
# Shared helpers - not settings. Everything below is used by the phases.
# ============================================================================

# Install only what actually exists in the archive, and say what it skipped,
# instead of aborting a whole phase on one renamed package.
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

# Print the whole-disk device whose serial matches $1, or fail.
resolve_disk_by_serial() {
  local want="$1" d
  [ -n "$want" ] || return 1
  for d in /dev/nvme?n? /dev/sd? /dev/vd?; do
    [ -b "$d" ] || continue
    if [ "$(lsblk -dno SERIAL "$d" 2>/dev/null || true)" = "$want" ]; then
      echo "$d"; return 0
    fi
  done
  return 1
}

# Partition node naming differs between nvme (p1) and sd/vd (1).
partition_node() {
  case "$1" in
    *nvme*|*mmcblk*|*loop*) echo "${1}p${2}" ;;
    *)                      echo "${1}${2}"  ;;
  esac
}

show_disks() {
  echo "Attached disks:" >&2
  lsblk -dno NAME,SIZE,MODEL,SERIAL >&2
}

# Fail early and loudly on an unconfigured install rather than halfway through.
require_config() {
  local missing=""
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] || missing="$missing $v"
  done
  [ -z "$missing" ] && return 0

  echo "FATAL: config.sh is incomplete. Set:$missing" >&2
  echo >&2
  case "$missing" in
    *TARGET_DISK_SERIAL*|*MIGRATE_DISK_SERIAL*) show_disks ;;
  esac
  echo >&2
  echo "Edit config.sh next to this script, then run it again." >&2
  exit 1
}
