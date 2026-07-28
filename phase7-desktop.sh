#!/usr/bin/env bash
#
# Phase 7 - GNOME 50 + full Yaru, native Firefox, Flatpak. No snaps.
#   RUN INSIDE THE CHROOT.  bash /root/install/phase7-desktop.sh
#
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ============================== EDIT THIS ===================================
# ubuntu  = install the ubuntu-desktop-minimal metapackage with
#           --no-install-recommends. Verified against the archive: snapd and
#           the firefox snap shim are Recommends, not Depends, so they are NOT
#           pulled in. You get the real Ubuntu desktop, dock and all.
#           Caveat: gnome-shell-ubuntu-extensions hard-depends on gir1.2-snapd-2.
#
# pure    = skip the metapackage and build GNOME from components. Cost: no
#           Ubuntu Dock, no Ubuntu desktop-icons, a plainer GNOME.
#
# NEITHER mode is free of snap-related *libraries*, and it is not possible to
# make one: libpipewire-0.3-modules hard-depends on libsnapd-glib-2-1, so any
# working audio stack pulls it. Verified against the resolute archive.
# What both modes DO guarantee: snapd itself is never installed. A full
# dependency-closure check over every package this installer requests found
# exactly one hard path to snapd - Ubuntu's firefox shim - which is pinned out
# below and refused explicitly. libsnapd-glib is a GLib binding: no daemon,
# no /snap mount, no snap can be installed.
DESKTOP_MODE="ubuntu"

# Which Firefox channel to install from Mozilla's APT repo.
#
# firefox      = rapid release. A new major version roughly every 4 weeks.
# firefox-esr  = Extended Support Release. One major version a year, security
#                fixes backported in between. The calmer choice, and the one
#                that matches what the rest of this install optimises for.
#
# Ubuntu's archive has NEITHER as a real deb - its 'firefox' is a snap
# installer and there is no firefox-esr at all - so both come from Mozilla.
# The nosnap pin blocks 'firefox' from o=Ubuntu only, which does not touch
# either Mozilla build.
#
# Whether Mozilla's repo actually carries firefox-esr was NOT verifiable when
# this was written - packages.mozilla.org was unreachable from the machine that
# wrote it. If the channel below has no candidate the script installs nothing,
# prints what both channels resolve to, and lets you pick. It will not quietly
# put you on a release cadence you did not ask for.
FIREFOX_CHANNEL="firefox-esr"

# Thunderbird. Ubuntu's thunderbird deb is 2:1snap1 with Pre-Depends: snapd -
# another snap installer - so it is pinned out and Flathub is the way in.
#
# flatpak = install THUNDERBIRD_REF from Flathub at the end of this phase.
#           Pulls the freedesktop runtime too, so budget a few hundred MB.
# no      = skip it; install it yourself after first boot.
#
# Read the profile-path note this prints at the end before running Phase 9.
INSTALL_THUNDERBIRD="flatpak"

# Which Flathub ref.
#
#   org.mozilla.thunderbird_esr  = the ESR line. Reported present on Flathub
#                                  by someone who could actually reach it.
#   org.mozilla.Thunderbird      = the regular app id.
#
# Note the different app IDs, not branches of one ID - which matters, because
# the Flatpak profile directory is named after the ID. The profile note at the
# end of this phase is derived from whatever is set here, so it stays correct
# if you change it.
#
# The script lists every Thunderbird ref Flathub actually publishes right
# before installing, and prints `flatpak info` for what landed. Trust that
# output over this comment: the machine running the install can reach Flathub.
THUNDERBIRD_REF="org.mozilla.thunderbird_esr"
# ============================================================================

[ "$(id -u)" -eq 0 ] || { echo "FATAL: must run as root inside the chroot" >&2; exit 1; }

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

apt-get update

# Re-check the pin. If something upstream loosened it, stop now rather than
# discover /snap on the installed system.
[ "$(apt-cache policy snapd | awk '/Candidate:/{print $2}')" = "(none)" ] \
  || { echo "FATAL: snapd is installable again. Check /etc/apt/preferences.d/nosnap.pref" >&2; exit 1; }

# ------------------------------------------------------------ desktop base
if [ "$DESKTOP_MODE" = "ubuntu" ]; then
  echo "==> Installing ubuntu-desktop-minimal (Depends only, no Recommends)"
  apt_install --no-install-recommends ubuntu-desktop-minimal
else
  echo "==> Installing GNOME from components (pure mode)"
  apt_install --no-install-recommends \
    gdm3 gnome-session gnome-shell gnome-settings-daemon gnome-control-center \
    gnome-menus gnome-session-canberra ubuntu-settings \
    at-spi2-core xdg-user-dirs xdg-user-dirs-gtk xkb-data xwayland
fi

# --------------------------------------------------------------- Yaru theme
echo "==> Yaru theme stack"
apt_install --no-install-recommends \
  yaru-theme-gtk yaru-theme-icon yaru-theme-sound yaru-theme-gnome-shell \
  ubuntu-wallpapers gsettings-ubuntu-schemas \
  fonts-ubuntu fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji fonts-liberation \
  xcursor-themes dmz-cursor-theme

# ------------------------------------------------------------- desktop apps
echo "==> Desktop applications and services"
apt_install --no-install-recommends \
  network-manager-gnome \
  ptyxis gnome-terminal \
  nautilus gnome-text-editor loupe papers file-roller \
  gnome-calculator gnome-disk-utility gnome-system-monitor baobab \
  gnome-characters gnome-font-viewer gnome-clocks gnome-logs \
  gnome-tweaks gnome-shell-extension-manager \
  gnome-keyring libpam-gnome-keyring seahorse \
  gvfs gvfs-backends gvfs-fuse \
  xdg-desktop-portal xdg-desktop-portal-gnome xdg-desktop-portal-gtk xdg-utils \
  pipewire pipewire-pulse pipewire-alsa wireplumber \
  polkitd policykit-desktop-privileges \
  plymouth plymouth-theme-spinner \
  appstream packagekit systemd-oomd \
  cups cups-filters system-config-printer \
  bluez bluez-cups gnome-bluetooth-sendto \
  gnome-software gnome-software-plugin-flatpak flatpak

# ------------------------------------------------------------------ Firefox
# Ubuntu's own 'firefox' package in 26.04 is version 1:1snap1 whose entire job
# is installing the Firefox snap. Mozilla's APT repo ships the genuine .deb.
echo "==> Native Firefox from Mozilla's APT repository ($FIREFOX_CHANNEL)"
install -d -m 0755 /etc/apt/keyrings
if curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
        -o /etc/apt/keyrings/packages.mozilla.org.asc; then

  echo "    Mozilla signing key fingerprint:"
  gpg --show-keys --with-fingerprint /etc/apt/keyrings/packages.mozilla.org.asc 2>/dev/null \
    | sed 's/^/      /' || true
  echo "    Expected: 35BAA0B3 3E9EB396 F59CA838 C0BA5CE6 DC6315A3"
  echo "    (cross-check at https://support.mozilla.org/kb/install-firefox-linux)"

  cat > /etc/apt/sources.list.d/mozilla.sources <<'EOF'
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla
Components: main
Signed-By: /etc/apt/keyrings/packages.mozilla.org.asc
EOF

  cat > /etc/apt/preferences.d/mozilla.pref <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF

  apt-get update

  # Test the CANDIDATE, not merely that Mozilla's repo is visible. Ubuntu's
  # firefox carries `Pre-Depends: snapd (>= 2.54)` - a Pre-Depends, stronger
  # than a normal dependency - so installing the wrong candidate is not a
  # cosmetic mistake. Any version string containing "snap" is the shim.
  FF_CAND="$(apt-cache policy "$FIREFOX_CHANNEL" | awk '/Candidate:/{print $2}')"
  echo "    $FIREFOX_CHANNEL candidate: $FF_CAND"

  case "$FF_CAND" in
    ""|"(none)")
      # Deliberately no fallback to the other channel: silently installing a
      # release cadence nobody asked for is worse than installing nothing.
      # Print what BOTH channels resolve to so the choice takes one command,
      # not an investigation.
      echo "    !! No $FIREFOX_CHANNEL candidate at all; installing no browser."
      echo "    !! What the archive offers right now:"
      apt-cache policy firefox firefox-esr 2>/dev/null | sed 's/^/         /'
      echo "    !! Pick one and install it by hand, e.g.:"
      echo "    !!     sudo apt install firefox"
      ;;
    *snap*)
      echo "    !! The candidate is Ubuntu's snap shim ($FF_CAND), not Mozilla's build."
      echo "    !! The pin in /etc/apt/preferences.d/mozilla.pref is not taking effect."
      echo "    !! REFUSING to install $FIREFOX_CHANNEL. Check the repo, then re-run this phase."
      ;;
    *)
      apt_install "" "$FIREFOX_CHANNEL"
      FF_INST="$(dpkg-query -W -f='${Version}' "$FIREFOX_CHANNEL" 2>/dev/null || echo none)"
      case "$FF_INST" in
        *snap*) echo "    !!!! Installed $FIREFOX_CHANNEL is the snap shim ($FF_INST) - purge it." ;;
        none)   echo "    !! $FIREFOX_CHANNEL did not install." ;;
        *)      echo "    $FIREFOX_CHANNEL installed: $FF_INST  OK" ;;
      esac
      ;;
  esac
else
  echo "    !! Could not fetch Mozilla's key. Skipping Firefox - install it after first boot."
  echo "    !! DO NOT 'apt install firefox' from Ubuntu's archive: it is a snap shim."
fi

# ------------------------------------------------------------------ Flatpak
echo "==> Flathub"
if command -v flatpak >/dev/null 2>&1; then
  flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo \
    && echo "    flathub added" \
    || echo "    !! could not add flathub now - run the same command after first boot"
else
  echo "    !! flatpak is not installed; skipping"
fi

# ------------------------------------------------- snapd GNOME Shell extensions
# gnome-shell-ubuntu-extensions ships two extensions that exist purely to talk
# to snapd, and Ubuntu enables them by default:
#
#   snapd-prompting@canonical.com        "SNAPD Permission Prompting"
#   snapd-search-provider@canonical.com  "Snapd Search Provider"
#
# They are JavaScript, not snaps, and with no snapd running they do nothing -
# the search provider finds no snaps, the prompter has no daemon to prompt for.
# But they load into gnome-shell on every login and they show up in Extension
# Manager, which on a machine built specifically to have no snap is at best
# confusing. Turning them off costs nothing.
#
# The package cannot simply be removed: ubuntu-desktop-minimal hard-depends on
# it, and it is also what provides Ubuntu Dock, DING, AppIndicators and the
# Tiling Assistant.
#
# disabled-extensions is subtracted from enabled-extensions by gnome-shell, so
# this switches them off without touching Ubuntu's own enabled list. Written as
# a gschema override with a high number so it wins over 10_ubuntu-settings.
# It sets the DEFAULT: anyone who later flips the toggle in Extension Manager
# still gets their way.
echo "==> Disabling the snapd GNOME Shell extensions"
cat > /usr/share/glib-2.0/schemas/99-nosnap-extensions.gschema.override <<'EOF'
[org.gnome.shell]
disabled-extensions=['snapd-prompting@canonical.com', 'snapd-search-provider@canonical.com']

[org.gnome.shell:ubuntu]
disabled-extensions=['snapd-prompting@canonical.com', 'snapd-search-provider@canonical.com']
EOF
if glib-compile-schemas /usr/share/glib-2.0/schemas/ 2>/dev/null; then
  echo "    snapd-prompting + snapd-search-provider disabled by default"
else
  echo "    !! glib-compile-schemas failed; the override will apply after the"
  echo "    !! next package that recompiles schemas. Per-user fallback:"
  echo "    !!     gnome-extensions disable snapd-prompting@canonical.com"
  echo "    !!     gnome-extensions disable snapd-search-provider@canonical.com"
fi

# ----------------------------------------------------------------- services
echo "==> Enabling desktop services"
mkdir -p /etc/X11
echo "/usr/sbin/gdm3" > /etc/X11/default-display-manager

# The unit is gdm.service with a gdm3 alias, and which name resolves has
# changed between releases. Try both rather than assume.
if systemctl enable gdm3 2>/dev/null || systemctl enable gdm 2>/dev/null; then
  echo "    enabled the display manager"
else
  echo "    !! could not enable gdm3/gdm - you will boot to a text console"
fi
for unit in cups bluetooth systemd-oomd; do
  systemctl enable "$unit" 2>/dev/null && echo "    enabled $unit" \
    || echo "    !! could not enable $unit"
done
systemctl set-default graphical.target

# ------------------------------------------------------------- final snap check
echo
echo "==> Snap audit"
if dpkg-query -W -f='${Status}\n' snapd 2>/dev/null | grep -q '^install ok installed'; then
  echo "    !!!! snapd IS INSTALLED - this should not happen. Purge it:"
  echo "         apt-get purge -y snapd && rm -rf /snap /var/snap /var/lib/snapd"
else
  echo "    snapd: not installed  OK"
fi
[ -d /snap ] && echo "    !! /snap directory exists" || echo "    /snap: absent  OK"

# --------------------------------------------------------------- Thunderbird
# Ubuntu's thunderbird deb is 2:1snap1-0ubuntu5 with Pre-Depends: snapd - the
# same snap-installer pattern as firefox - so Phase 5 pins it out and Flathub
# is the way in.
#
# Runs last on purpose: it is the longest network step in this phase and the
# likeliest to fail on a flaky link. Everything above is already done by the
# time it starts, and a failure here costs one command after first boot.
if [ "$INSTALL_THUNDERBIRD" = "flatpak" ]; then
  echo
  echo "==> Thunderbird (Flathub)"
  if ! command -v flatpak >/dev/null 2>&1; then
    echo "    !! flatpak is not installed; skipping"
  elif ! flatpak remote-list 2>/dev/null | grep -q flathub; then
    echo "    !! the flathub remote is missing; skipping"
    echo "    !! After first boot: flatpak install flathub $THUNDERBIRD_REF"
  else
    # Ground truth beats a guess written months ago. This machine can reach
    # Flathub; the one that wrote the script could not. If you wanted an ESR
    # branch and no such ref is listed here, the default branch is all there
    # is - which for Thunderbird has historically been the ESR line anyway.
    echo "    Thunderbird refs Flathub publishes:"
    flatpak remote-ls flathub --app --columns=ref,version 2>/dev/null \
      | grep -i thunderbird | sed 's/^/      /' \
      || echo "      (could not list - continuing anyway)"

    echo "    installing: $THUNDERBIRD_REF"
    if flatpak install -y --noninteractive flathub "$THUNDERBIRD_REF"; then
      echo "    $THUNDERBIRD_REF installed  OK"
      flatpak info "$THUNDERBIRD_REF" 2>/dev/null \
        | grep -iE '^ *(Version|Branch|Ref):' | sed 's/^/      /' || true
    else
      echo "    !! $THUNDERBIRD_REF did not install."
      echo "    !! If the ref is wrong, pick one from the list above."
      echo "    !! After first boot: flatpak install flathub <ref>"
    fi
  fi

  # The part that fails silently if nobody says it. Phase 9 restores the old
  # profile to ~/.thunderbird, which is where a .deb Thunderbird looks. The
  # Flatpak looks somewhere else and would start with an empty account list -
  # looking exactly like the restore did not work.
  #
  # Derived from THUNDERBIRD_REF, because ~/.var/app is keyed on the app ID:
  # org.mozilla.thunderbird_esr and org.mozilla.Thunderbird do NOT share a
  # profile. Strip any //branch suffix.
  TB_APPID="${THUNDERBIRD_REF%%/*}"
  cat <<NOTE

    PROFILE PATH - read this before running Phase 9:
        deb build      ~/.thunderbird
        Flatpak build  ~/.var/app/$TB_APPID/.thunderbird

    Phase 9 restores the old profile to ~/.thunderbird. For the Flatpak,
    move it after restoring:

        mkdir -p ~/.var/app/$TB_APPID
        mv ~/.thunderbird ~/.var/app/$TB_APPID/.thunderbird
NOTE
fi

echo
echo "==> Phase 7 complete. Next: bash /root/install/phase8-bootloader.sh"
