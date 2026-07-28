# Ubuntu 26.04 LTS Debootstrap — Locked Decisions & Archive Facts

> **Full walkthrough: `README.md`** — this file is the reference card.
> Everything machine-specific lives in **`config.sh`**; nothing here is
> hardcoded to one person's hardware.
>
> Scripts run in numbered order: `phase2b-…`, then `phase3-…`, etc.

## Verified against the resolute archive (not from memory)

| Fact | Value |
|---|---|
| `resolute` | Ubuntu 26.04 LTS, released 2026-04-23 |
| Pockets | `resolute`, `-updates`, `-security`, `-backports` all live |
| Kernel | 7.0.0-28 · Mesa 26.0.3 · GNOME 50 |
| Ubuntu's `firefox` deb | `1:1snap1-0ubuntu8` — a snap installer shim. **Never install it.** |
| Ubuntu's `thunderbird` deb | `2:1snap1-0ubuntu5` — same shim pattern, note the different epoch |
| `snapd` in `ubuntu-desktop-minimal` | **Recommends**, not Depends |
| Packages hard-depending on `snapd` | 10, all pinned — see `phase4-core.sh` |

Package names that changed in 26.04 and would abort an install if used blindly:

| Dead name | Correct name |
|---|---|
| `gnome-shell-extension-ubuntu-dock` | `gnome-shell-ubuntu-extensions` |
| `mesa-va-drivers`, `mesa-vdpau-drivers` | `mesa-libgallium` |
| `policykit-1-gnome` | `polkitd` + `policykit-desktop-privileges` |
| `gnome-bluetooth` | `gnome-bluetooth-sendto` |
| `eog` / `evince` | `loupe` / `papers` |
| `plymouth-theme-ubuntu-logo` | `plymouth-theme-spinner` |

## Hardware assumptions

- **UEFI only.** No BIOS/CSM path. `efivarfs` should be present; Phase 8 copes
  if it is not visible inside the chroot.
- **amd64.**
- **CPU microcode and GPU stack are detected**, not assumed — `CPU_VENDOR` and
  `GPU_VENDOR` in `config.sh` default to `auto`. AMD and Intel are fully
  handled by Mesa. NVIDIA deliberately gets no proprietary driver: which one is
  right depends on the card and on Secure Boot, and guessing produces a black
  screen on first boot. Nouveau brings up a desktop; swap it after login.
- **Disks are identified by SERIAL, never by `nvme0n1` vs `nvme1n1`** —
  enumeration order differs between the live kernel and the installed one, and
  the wrong name means the wrong disk is destroyed. List them with
  `lsblk -dno NAME,SIZE,MODEL,SERIAL`.

## Decisions

- **Config:** one file, `config.sh`, sourced by every phase. Phase 3 copies it
  into the target so the chroot phases read the same values.
- **Target layout:** GPT — `p1` ESP FAT32 (`ESP_SIZE`, default 1G) ·
  `p2` rest btrfs (label `ubuntu-root`)
- **Subvolumes:** `@ @home @snapshots @var_log @var_cache @var_lib_flatpak`
- **Mount opts:** `noatime,compress=zstd:3,ssd,discard=async,space_cache=v2`
- **Swap:** zram only, no swap partition, no swapfile, no hibernation
- **Snap:** forbidden — `nosnap.pref` pin at priority -1 before any desktop
  package. Pinned by enumeration, not by intent: every package in the archive
  with a hard snapd dependency, including ones a desktop would never install.
  Flatpak/Flathub is allowed and gets its own subvolume.
- **Firefox:** native `.deb` from Mozilla's repo, never the snap.
  `FIREFOX_CHANNEL` selects ESR (default) or rapid release.
- **Thunderbird:** Flathub, `THUNDERBIRD_REF` (ESR app id by default). Ubuntu's
  deb is a snap installer. Same story for `chromium-browser`.
- **Rollback:** `apt-btrfs-snapshot`, installed at the end of Phase 8. Snapshots
  `@` before every dpkg run, keeps them at the btrfs top level as
  `@apt-snapshot-*`, prunes by name (8 hourly / 7 daily / 2 weekly).
  Never set `APT::Snapshots::MaxAge` — atime-based, and this root is `noatime`.
  `grub-btrfs` (boot-menu entries per snapshot) is out of scope: not packaged
  for Ubuntu.
- **Desktop:** GNOME + full Yaru, installed with `--no-install-recommends`,
  made permanent in Phase 8 via `/etc/apt/apt.conf.d/99norecommends`.
  Ubuntu's snapd shell extensions are disabled and the dock favourites are
  regenerated from what actually got installed.

## What `--no-install-recommends` leaves out

Worth knowing before treating the result as a finished desktop. These are
`ubuntu-standard` Recommends and are **not** installed:

`apparmor` (no MAC enforcement at all), `ufw`, `update-manager-core`
(so no `do-release-upgrade` command), `command-not-found`, `sysstat`,
`openssh-client`, `ntfs-3g`.

README §15.1 has the one-line fix.

## Phase 9 (optional) — `phase9-migrate-home.sh`

Only relevant when you are replacing an older install and want its disk to
become the new `/home`. Set `MIGRATE_DISK_SERIAL` in `config.sh`; leave it
empty on a single-disk machine and skip the phase entirely.

`/home` initially lives in the `@home` subvol on the install disk. After the
system boots cleanly:

1. `phase9-… restore` — mounts the old disk read-only at `/mnt/old-home`;
   copy back what you want
2. `phase9-… migrate` — wipes that disk, recreates btrfs + `@home`, moves
   `/home` onto it, rewrites `/etc/fstab` (backup at `/etc/fstab.bak`)

`migrate` must run from a text console logged in **as root** — logging in as
the normal user holds `/home` open and the script will refuse. It also
preflights every command it needs before touching anything, because the wipe
sequence is `wipefs -a` then `sgdisk` and a missing tool used to abort with the
partition table already gone.

Do not wipe the old disk before that point — it is the only copy.
