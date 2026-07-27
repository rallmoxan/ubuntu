# Ubuntu 26.04 LTS Debootstrap — Locked Decisions & Hardware Facts

> **Full walkthrough: `KURULUM_REHBERI.md`** — this file is just the reference card.
> Scripts run in numbered order: `phase2b-…`, then `phase3-…`, etc.

## Verified against the resolute archive (not from memory)

| Fact | Value |
|---|---|
| `resolute` | Ubuntu 26.04 LTS, released 2026-04-23 |
| Pockets | `resolute`, `-updates`, `-security`, `-backports` all live |
| Kernel | 7.0.0-28 · Mesa 26.0.3 · GNOME 50 |
| Ubuntu's `firefox` deb | `1:1snap1` — a snap installer shim. **Never install it.** |
| `snapd` in `ubuntu-desktop-minimal` | **Recommends**, not Depends |

Package names that changed in 26.04 and would abort an install if used blindly:

| Dead name | Correct name |
|---|---|
| `gnome-shell-extension-ubuntu-dock` | `gnome-shell-ubuntu-extensions` |
| `mesa-va-drivers`, `mesa-vdpau-drivers` | `mesa-libgallium` |
| `policykit-1-gnome` | `polkitd` + `policykit-desktop-privileges` |
| `gnome-bluetooth` | `gnome-bluetooth-sendto` |
| `eog` / `evince` | `loupe` / `papers` |
| `plymouth-theme-ubuntu-logo` | `plymouth-theme-spinner` |

## Hardware

| Component | Value |
|---|---|
| CPU | AMD Ryzen 5 7500X3D (needs `amd64-microcode`) |
| dGPU | Radeon RX 9060 XT — Navi 44, RDNA4 (`amdgpu`, needs current `linux-firmware`) |
| iGPU | Raphael RDNA2 (`amdgpu`) |
| RAM | 14 GiB |
| Firmware | UEFI (efivarfs present) |

## Disks

| Role | Device | Serial | Notes |
|---|---|---|---|
| **WIPE → Ubuntu** | KINGSTON SNV3S1000G, 931.5G | `50026B738450CE7B` | erased in Phase 2b |
| **KEEP until Phase 9** | SAMSUNG MZVLQ512HBLU, 476.9G | `S6F5NL0TC03659` | holds data + these scripts |

Samsung btrfs UUID: `bc8fb1bb-a4a5-4fa6-a76b-d89047b401bb`, data lives in subvol `@home`.

Mount it from the live session:
```bash
sudo mkdir -p /mnt-old
sudo mount -o subvol=@home UUID=bc8fb1bb-a4a5-4fa6-a76b-d89047b401bb /mnt-old
ls /mnt-old/baris/Ubuntu/
```

**Identify disks by SERIAL, never by `nvme0n1` vs `nvme1n1`** — enumeration order can
differ under the live kernel. The scripts already do this.

## Decisions

- **Target layout:** GPT — `p1` 1G ESP FAT32 · `p2` rest btrfs (label `ubuntu-root`)
- **Subvolumes:** `@ @home @snapshots @var_log @var_cache @var_lib_flatpak`
- **Mount opts:** `noatime,compress=zstd:3,ssd,discard=async,space_cache=v2`
- **Swap:** zram only, no swap partition, no swapfile, no hibernation
- **Locale:** `en_US.UTF-8` only, `us` keyboard, timezone `Europe/Istanbul` (confirmed)
- **Identity:** hostname `barzbug`, user `baris` at uid 1000 — set in `phase4-core.sh`
- **Release:** Ubuntu 26.04 LTS, codename `resolute`
- **Snap:** forbidden — `nosnap.pref` pin at priority -1 before any desktop package.
  Flatpak/Flathub is allowed and gets its own subvolume.
- **Firefox:** native `.deb`, never the snap.
- **Desktop:** GNOME + full Yaru, installed with `--no-install-recommends`.

## Phase 9 (the deferred wipe) — run `phase9-home-to-samsung.sh`

`/home` initially lives in the `@home` subvol on the **Kingston**. Only after Ubuntu
boots cleanly:

1. `phase9-… restore` — mounts the old Samsung home read-only at `/mnt/old-home`;
   copy back what you want
2. `phase9-… migrate` — wipes the Samsung, recreates btrfs + `@home`, moves
   `/home` onto it, rewrites `/etc/fstab` (backup at `/etc/fstab.bak`)

`migrate` must run from a text console logged in **as root** — logging in as
`baris` holds `/home` open and the script will refuse.

Do not wipe the Samsung before that point — it is the only copy.

(`/mnt-old` is the *live session* mount point for the same disk; `/mnt/old-home`
is the one used on the booted system. Same filesystem, different phases.)

## Live media

`ubuntu-26.04-desktop-amd64.iso`
SHA256 `487f87faaf547ea30e0aba4d5b53346292571256b25333a978db1692bcee9dd2`
