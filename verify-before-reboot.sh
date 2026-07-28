#!/usr/bin/env bash
#
# Pre-reboot audit. RUN INSIDE THE CHROOT, after Phase 8.
#   bash /root/install/verify-before-reboot.sh
#
# Every check here maps to a specific way a debootstrap install fails to boot.
# Do not reboot while anything says FAIL.
#
# Runs to completion and reports everything; it does not stop at the first
# problem, because you want the whole list, not one item at a time.

PASS=0; FAIL=0; WARN=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; WARN=$((WARN+1)); }
sect() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
sect "1. /etc/fstab  (the read-only-root killer)"

if [ ! -s /etc/fstab ]; then
  bad "/etc/fstab is missing or empty - the system WILL boot read-only"
else
  ROOT_LINE="$(awk '$2=="/" && $1 !~ /^#/ {print; exit}' /etc/fstab)"
  if [ -z "$ROOT_LINE" ]; then
    bad "no entry for / in fstab - systemd cannot remount root rw, you get a READ-ONLY system"
  else
    ok "root entry present: $ROOT_LINE"

    case "$ROOT_LINE" in
      *,ro,*|*\ ro,*|*,ro\ *) bad "root is mounted 'ro' in fstab - remove it" ;;
      *rw*)                   ok  "root options contain 'rw'" ;;
      *)                      warn "root has no explicit 'rw' (usually still fine, rw is the default)" ;;
    esac

    case "$ROOT_LINE" in
      *subvol=@*) ok "root has subvol=@" ;;
      *)          bad "root line has no subvol=@ - the wrong btrfs subvolume will be mounted" ;;
    esac

    ROOT_PASS="$(echo "$ROOT_LINE" | awk '{print $6}')"
    if [ "$ROOT_PASS" = "0" ]; then ok "root fsck pass is 0 (correct for btrfs)"
    else bad "root fsck pass is '$ROOT_PASS' - must be 0 for btrfs or boot drops to emergency mode"; fi
  fi

  # Every UUID in fstab must actually resolve.
  #
  # Deliberately a `for` over command substitution, not `while read ... < <(...)`:
  # process substitution needs /dev/fd, and in a chroot where /dev is not fully
  # populated bash fails with "/dev/fd/63: No such file or directory" and the
  # whole loop is SKIPPED SILENTLY - the checks below still print PASS and you
  # would never learn that the most important check never ran. Caught by
  # actually executing this script in a minimal chroot.
  # awk instead of `grep -oP` for the same reason: no PCRE dependency.
  UUIDS="$(awk '$1 ~ /^UUID=/ && $1 !~ /^#/ {sub(/^UUID=/,"",$1); print $1}' /etc/fstab | sort -u)"
  if [ -z "$UUIDS" ]; then
    bad "no UUID= entries in fstab at all - device names are fragile, boot may fail"
  else
    for uuid in $UUIDS; do
      if blkid -U "$uuid" >/dev/null 2>&1; then
        ok "UUID=$uuid resolves to $(blkid -U "$uuid")"
      else
        bad "UUID=$uuid in fstab does not exist - boot will hang waiting for it"
      fi
    done
  fi

  grep -qE '^\S+\s+/boot/efi\s+vfat' /etc/fstab \
    && ok "/boot/efi entry present" \
    || bad "/boot/efi missing from fstab - kernel updates will not reach the ESP"
fi

# ---------------------------------------------------------------------------
sect "2. Kernel and initramfs"

if [ -x /sbin/init ] || [ -L /sbin/init ]; then
  ok "/sbin/init present -> $(readlink -f /sbin/init 2>/dev/null || echo /sbin/init)"
else
  bad "/sbin/init missing - the kernel will panic. Install: apt-get install systemd-sysv"
fi

if ls /boot/vmlinuz-* >/dev/null 2>&1; then
  ok "kernel: $(ls -1 /boot/vmlinuz-* | xargs -n1 basename | tr '\n' ' ')"
else
  bad "no kernel in /boot - nothing to boot"
fi

if ls /boot/initrd.img-* >/dev/null 2>&1; then
  for img in /boot/initrd.img-*; do
    if lsinitramfs "$img" 2>/dev/null | grep -q btrfs; then
      ok "$(basename "$img") has btrfs support"
    else
      bad "$(basename "$img") has NO btrfs support - kernel panic on boot"
    fi
  done
else
  bad "no initramfs in /boot"
fi

# ---------------------------------------------------------------------------
sect "3. GRUB and the ESP"

if [ -s /boot/grub/grub.cfg ]; then
  ok "grub.cfg exists"
  RU="$(awk '$2=="/" && $1 ~ /^UUID=/ {print $1}' /etc/fstab | sed 's/^UUID=//')"
  [ -n "$RU" ] && grep -q "$RU" /boot/grub/grub.cfg \
    && ok "grub.cfg references the root UUID" \
    || bad "grub.cfg does not reference the root UUID from fstab"
  grep -q 'rootflags=subvol=@' /boot/grub/grub.cfg \
    && ok "grub.cfg passes rootflags=subvol=@" \
    || bad "grub.cfg lacks rootflags=subvol=@ - initramfs will mount the wrong subvolume"
  grep -qE 'linux\s+/@?/?boot/vmlinuz' /boot/grub/grub.cfg \
    && ok "grub.cfg has a kernel entry" \
    || warn "could not spot a kernel line in grub.cfg - inspect it by hand"
else
  bad "/boot/grub/grub.cfg missing - run update-grub"
fi

if mountpoint -q /boot/efi; then
  ok "/boot/efi is mounted"
  [ -f /boot/efi/EFI/Ubuntu/shimx64.efi ] || [ -f /boot/efi/EFI/ubuntu/shimx64.efi ] \
    && ok "shimx64.efi present (Secure Boot path)" \
    || warn "no shimx64.efi - fine only if Secure Boot is off"
  [ -f /boot/efi/EFI/Ubuntu/grubx64.efi ] || [ -f /boot/efi/EFI/ubuntu/grubx64.efi ] \
    && ok "grubx64.efi present" \
    || bad "no grubx64.efi in the ESP"
  [ -f /boot/efi/EFI/BOOT/BOOTX64.EFI ] || [ -f /boot/efi/EFI/boot/bootx64.efi ] \
    && ok "removable fallback BOOTX64.EFI present" \
    || warn "no fallback BOOTX64.EFI - firmware that ignores NVRAM will not find Ubuntu"
else
  bad "/boot/efi is not mounted - GRUB cannot have been installed correctly"
fi

if command -v efibootmgr >/dev/null 2>&1; then
  if efibootmgr 2>/dev/null | grep -qi ubuntu; then ok "UEFI NVRAM entry for Ubuntu exists"
  else warn "no Ubuntu NVRAM entry (efivars may not be visible in the chroot; the fallback BOOTX64.EFI covers this)"; fi
fi

# ---------------------------------------------------------------------------
sect "4. Identity, users, login"

[ -s /etc/machine-id ] && ok "machine-id set" || bad "/etc/machine-id empty - systemd/dbus will misbehave"
[ -s /etc/hostname ]   && ok "hostname: $(cat /etc/hostname)" || bad "/etc/hostname empty"
grep -q "$(cat /etc/hostname 2>/dev/null)" /etc/hosts 2>/dev/null \
  && ok "hostname resolves via /etc/hosts" \
  || warn "hostname not in /etc/hosts - sudo and GNOME may stall on lookups"

U="$(awk -F: '$3==1000 {print $1; exit}' /etc/passwd)"
if [ -n "$U" ]; then
  ok "user '$U' exists with uid 1000"
  case "$(passwd -S "$U" 2>/dev/null | awk '{print $2}')" in
    P)  ok "'$U' has a password set" ;;
    L)  bad "'$U' is LOCKED - you will not be able to log in" ;;
    NP) bad "'$U' has NO password - GDM will refuse the login" ;;
    *)  warn "could not determine password state for '$U'" ;;
  esac
  id -nG "$U" | tr ' ' '\n' | grep -qx sudo \
    && ok "'$U' is in the sudo group" \
    || bad "'$U' is not in sudo - no administrative access on the new system"
  [ -d "/home/$U" ] && ok "/home/$U exists" || bad "/home/$U missing"
else
  bad "no uid-1000 user - nothing to log in as"
fi

case "$(passwd -S root 2>/dev/null | awk '{print $2}')" in
  P) ok "root password set" ;;
  L) warn "root is locked (fine if sudo works, painful in a recovery shell)" ;;
  *) warn "root password state unknown" ;;
esac

# ---------------------------------------------------------------------------
sect "5. Boot target and services"

DEF="$(systemctl get-default 2>/dev/null || echo unknown)"
[ "$DEF" = "graphical.target" ] && ok "default target: graphical.target" \
                                || bad "default target is '$DEF' - you will land in a text console"

if systemctl is-enabled gdm3 >/dev/null 2>&1 || systemctl is-enabled gdm >/dev/null 2>&1; then
  ok "display manager (gdm3/gdm) enabled"
else
  bad "gdm3 is NOT enabled - you will boot to a text console"
fi
for u in NetworkManager systemd-resolved; do
  if systemctl is-enabled "$u" >/dev/null 2>&1; then ok "$u enabled"
  else bad "$u is NOT enabled"; fi
done

[ -f /etc/X11/default-display-manager ] \
  && ok "display manager: $(cat /etc/X11/default-display-manager)" \
  || warn "/etc/X11/default-display-manager missing"

# ---------------------------------------------------------------------------
sect "6. No-snap policy"

if dpkg-query -W -f='${Status}\n' snapd 2>/dev/null | grep -q '^install ok installed'; then
  bad "snapd IS INSTALLED"
else
  ok "snapd not installed"
fi
[ -e /etc/apt/preferences.d/nosnap.pref ] && ok "nosnap.pref in place" || bad "nosnap.pref missing"
[ "$(apt-cache policy snapd 2>/dev/null | awk '/Candidate:/{print $2}')" = "(none)" ] \
  && ok "snapd candidate is (none) - pin effective" \
  || bad "snapd is installable - the pin is not working"
[ -d /snap ] && bad "/snap directory exists" || ok "/snap absent"

# The pin must survive `apt full-upgrade` on the running system, so check that
# it is written against the ORIGIN and not against one version string that the
# next Ubuntu shim release would slip past.
if grep -q 'Pin: release o=Ubuntu' /etc/apt/preferences.d/nosnap.pref 2>/dev/null; then
  ok "browser/mail pinned by origin - survives shim version bumps"
else
  warn "the firefox/thunderbird pin is not origin-based; a version bump could slip past it"
fi

# Everything here must be uninstallable outright. firefox and thunderbird are
# NOT in this list: by now Mozilla's repo is configured and their candidate is
# supposed to be a real deb, so they get their own check further down.
#
# One apt-cache call for the lot. A package missing from the archive simply
# produces no stanza, which is the same PASS as a blocked one.
BLOCKED="snapd snapd-seed-glue snapd-installation-monitor
         gnome-software-plugin-snap plasma-discover-backend-snap fwupd-snap
         ubuntu-server-minimal ubuntu-cloud-minimal livecd-rootfs
         chromium-browser"
# shellcheck disable=SC2086
LEAKED="$(apt-cache policy $BLOCKED 2>/dev/null | awk '
  /^[^ ].*:$/                 { p = $0; sub(/:$/, "", p); next }
  /^ +Candidate: / && p != "" { if ($2 != "(none)") print p "(" $2 ")"; p = "" }')"
if [ -n "$LEAKED" ]; then
  for leak in $LEAKED; do
    bad "$leak is installable - nosnap.pref is not blocking it"
  done
else
  ok "every package named in nosnap.pref is blocked"
fi

# The forward-looking one. Rather than trusting the hand-written list above to
# stay complete, ask APT which packages hard-depend on snapd right now and
# whether the pin still names all of them. If Ubuntu converts another deb into
# a snap installer after this system is built, it surfaces here.
#
# WARN and not FAIL, deliberately: anything that hard-depends on snapd is
# already uninstallable while snapd sits at -1, because APT will not pull snapd
# in to satisfy it. Naming these packages in nosnap.pref does not close a hole,
# it turns a confusing unmet-dependency error into an explicit refusal. The
# check that actually matters - snapd's own candidate being (none) - is a FAIL
# above.
#
# Reading each candidate's own Depends field rather than using `apt-cache
# depends`: that command flattens OR groups onto separate lines, so
# `Depends: foo | snapd` would read as a hard dependency. Splitting the real
# field on commas and skipping any group containing '|' is what makes "hard"
# mean it. Batched into three apt-cache calls; per-package calls take a minute.
SNAPDEP_PKGS="$(apt-cache rdepends snapd 2>/dev/null \
  | awk '/Reverse Depends:/{f=1;next} f{gsub(/^[ |]+/,""); print $1}' | sort -u)"
SNAPDEP=""
if [ -n "$SNAPDEP_PKGS" ]; then
  # shellcheck disable=SC2086
  SNAPDEP_CANDS="$(apt-cache policy $SNAPDEP_PKGS 2>/dev/null | awk '
    /^[^ ].*:$/ { p = $0; sub(/:$/, "", p); next }
    /^ +Candidate: / && p != "" && $2 != "(none)" { print p "=" $2; p = "" }')"
  if [ -n "$SNAPDEP_CANDS" ]; then
    # shellcheck disable=SC2086
    SNAPDEP="$(apt-cache show $SNAPDEP_CANDS 2>/dev/null | awk -v RS="" '
      {
        pkg = ""; ver = ""; hard = 0
        n = split($0, L, "\n")
        for (i = 1; i <= n; i++) {
          if (L[i] ~ /^Package: /) { pkg = substr(L[i], 10); continue }
          if (L[i] ~ /^Version: /) { ver = substr(L[i], 10); continue }
          if (L[i] !~ /^(Pre-)?Depends: /) continue
          d = L[i]; sub(/^[^:]*: /, "", d)
          m = split(d, g, ",")
          for (j = 1; j <= m; j++) {
            if (g[j] ~ /\|/) continue
            gsub(/^[ \t]+|[ \t]+$/, "", g[j])
            split(g[j], t, " ")
            if (t[1] == "snapd") hard = 1
          }
        }
        if (hard && pkg != "") printf " %s", pkg
      }')"
  fi
fi
if [ -n "$SNAPDEP" ]; then
  warn "hard-depend on snapd but are not named in nosnap.pref:$SNAPDEP"
  warn "  (they cannot install while snapd is pinned; add them for a clean refusal)"
else
  ok "every package that hard-depends on snapd is named in the pin"
fi

# Ubuntu's shims are the only builds ever versioned *snap*, so the version
# string identifies them. Fine as a detector here; the enforcement is the
# o=Ubuntu pin, which is what this is checking did its job.
for app in firefox firefox-esr thunderbird; do
  APPC="$(apt-cache policy "$app" 2>/dev/null | awk '/Candidate:/{print $2}')"
  case "$APPC" in
    *snap*) bad "$app candidate is Ubuntu's snap shim ($APPC) - the o=Ubuntu pin is not working" ;;
  esac
done

# Either Firefox channel counts; both come from Mozilla and Phase 7 installs
# whichever FIREFOX_CHANNEL names.
FF_OK=""
for app in firefox firefox-esr; do
  dpkg -s "$app" >/dev/null 2>&1 || continue
  APPV="$(dpkg-query -W -f='${Version}' "$app" 2>/dev/null)"
  case "$APPV" in
    *snap*) bad "installed $app is the snap shim ($APPV)" ;;
    *)      FF_OK="$app $APPV" ;;
  esac
done
[ -n "$FF_OK" ] && ok "Firefox installed: $FF_OK" \
                || warn "no Firefox deb installed - Mozilla's repo after first boot"

# Thunderbird is a Flatpak by default here, so an absent deb is not a finding.
if dpkg -s thunderbird >/dev/null 2>&1; then
  TBV="$(dpkg-query -W -f='${Version}' thunderbird 2>/dev/null)"
  case "$TBV" in
    *snap*) bad "installed thunderbird is the snap shim ($TBV)" ;;
    *)      ok "Thunderbird deb installed ($TBV)" ;;
  esac
elif TB_REF="$(flatpak list --app --columns=application 2>/dev/null | grep -iE '^org\.mozilla\.thunderbird' | head -1)" && [ -n "$TB_REF" ]; then
  ok "Thunderbird installed as a Flatpak ($TB_REF)"
else
  warn "Thunderbird not installed - Flathub after first boot"
fi

# The two snapd shell extensions ship with gnome-shell-ubuntu-extensions and
# are enabled by default. They do nothing without snapd, but they load anyway.
if [ -d /usr/share/gnome-shell/extensions/snapd-prompting@canonical.com ]; then
  if grep -rqs 'snapd-prompting@canonical.com' /usr/share/glib-2.0/schemas/*.override; then
    ok "snapd shell extensions disabled by default"
  else
    warn "snapd shell extensions are present and enabled - see phase 7"
  fi
fi

if [ "$(apt-config dump APT::Install-Recommends 2>/dev/null | awk -F'"' '{print $2}')" = "false" ]; then
  ok "Install-Recommends is off system-wide"
else
  warn "Recommends are on - future apt installs will pull more than the build did"
fi

# ---------------------------------------------------------------------------
sect "7. Snapshot safety net"

if dpkg-query -W -f='${Status}\n' apt-btrfs-snapshot 2>/dev/null | grep -q '^install ok installed'; then
  ok "apt-btrfs-snapshot installed"

  [ -e /etc/apt/apt.conf.d/80-btrfs-snapshot ] \
    && ok "DPkg::Pre-Invoke hook in place" \
    || bad "the apt hook is missing - no snapshot will be taken before upgrades"

  apt-btrfs-snapshot supported >/dev/null 2>&1 \
    && ok "layout supported (btrfs / on subvol=@)" \
    || bad "apt-btrfs-snapshot says this layout is unsupported"

  # MaxAge switches pruning to an atime-based path that cannot work on a
  # noatime root, and disables the name-based prune at the same time.
  if [ -n "$(apt-config dump APT::Snapshots::MaxAge 2>/dev/null)" ]; then
    bad "APT::Snapshots::MaxAge is set - incompatible with the noatime root, and it disables auto-pruning"
  else
    ok "APT::Snapshots::MaxAge unset (name-based pruning stays active)"
  fi

  grep -q 'noatime' /etc/fstab 2>/dev/null \
    && ok "root is noatime - retention is by snapshot name, as configured" \
    || warn "root is not noatime; harmless, but the MaxAge caveat no longer applies"
else
  warn "apt-btrfs-snapshot not installed - upgrades will have no rollback point"
fi

# ---------------------------------------------------------------------------
sect "8. Locale, time, swap, network"

[ -e /etc/localtime ] && ok "timezone: $(cat /etc/timezone 2>/dev/null || readlink -f /etc/localtime)" \
                      || bad "/etc/localtime missing"
locale -a 2>/dev/null | grep -qi 'en_US.utf8' && ok "en_US.UTF-8 generated" \
                                              || bad "en_US.UTF-8 not generated"
[ -f /etc/systemd/zram-generator.conf ] && ok "zram configured" || warn "no zram config - system will run without swap"
grep -qE '^\s*[^#]\S*\s+swap\s' /etc/fstab 2>/dev/null \
  && warn "an on-disk swap entry exists in fstab (you chose zram-only)" \
  || ok "no on-disk swap in fstab (as intended)"
[ -L /etc/resolv.conf ] && ok "resolv.conf is a symlink -> $(readlink /etc/resolv.conf)" \
                        || warn "resolv.conf is a regular file - DNS may be stale after first boot"

[ -e /usr/sbin/policy-rc.d ] && bad "policy-rc.d still present - services will refuse to start on the real system" \
                             || ok "policy-rc.d removed"

# ---------------------------------------------------------------------------
printf '\n\033[1m===============================================\033[0m\n'
printf '  PASS %s   WARN %s   FAIL %s\n' "$PASS" "$WARN" "$FAIL"
printf '\033[1m===============================================\033[0m\n'
if [ "$FAIL" -gt 0 ]; then
  printf '\n\033[31mDO NOT REBOOT.\033[0m Fix the FAIL lines above first.\n\n'
  exit 1
fi
printf '\n\033[32mSafe to reboot.\033[0m Exit the chroot, then:\n'
printf '    exit\n    sudo umount -R /mnt\n    sudo reboot\n\n'
exit 0
