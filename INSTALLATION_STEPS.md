# Ubuntu 26.04 LTS Debootstrap Roadmap

## Phase 1: Hardware & Partition Strategy Questions
Ask the user:
1. What is the target drive? (e.g., `/dev/nvme0n1` or `/dev/sda`)
2. Is the system UEFI or Legacy BIOS?
3. Preferred filesystem for root (`/`)? (EXT4, BTRFS)
4. Preferred Swap setup? (Swap partition, Swapfile, or None/ZRAM)

## Phase 2: Partitioning & Preparation
- Partition target disk using `fdisk` or `parted`.
- Format partitions (EFI as FAT32, Root as chosen FS).
- Mount target layout under `/mnt` and `/mnt/boot/efi`.

## Phase 3: Base Debootstrap
- Install prerequisites on host: `apt update && apt install -y debootstrap ubuntu-keyring`
- Execute debootstrap for Ubuntu 26.04 LTS (e.g. release codename `resolute` or target branch):
  ```bash
  debootstrap --arch=amd64 resolute /mnt http://archive.ubuntu.com/ubuntu/
  ```
- Mount system bindings:
  ```bash
  for dir in /dev /dev/pts /proc /sys /run; do mount --bind $dir /mnt$dir; done
  ```

## Phase 4: Chroot Base Setup
- Enter chroot: `chroot /mnt /bin/bash`
- Set Hostname, Locales (`en_US.UTF-8` / `tr_TR.UTF-8`), Timezone.
- Configure `/etc/fstab` using `genfstab` or manual UUID mapping.
- Set Root password and create Sudo user.

## Phase 5: Complete Snap Eradication Block
Inside chroot, enforce APT policy before installing desktop environment:
```bash
cat <<'EOF' > /etc/apt/preferences.d/nosnap.pref
Package: snapd
Pin: release *
Pin-Priority: -1
EOF

apt-get purge -y snapd 2>/dev/null || true
```

## Phase 6: Kernel, Firmware & Drivers
- Install core kernel & firmware:
  ```bash
  apt-get install -y --no-install-recommends linux-image-generic linux-headers-generic linux-firmware
  ```
- Install GPU microcode / drivers based on user choice.

## Phase 7: Full Yaru + GNOME (No Snap)
- Install GNOME Core & Yaru Theme stack without recommending snapd:
  ```bash
  apt-get install -y --no-install-recommends \
    gdm3 \
    gnome-session \
    gnome-shell \
    ubuntu-wallpapers \
    yaru-theme-gtk \
    yaru-theme-icon \
    yaru-theme-sound \
    yaru-theme-gnome-shell \
    gnome-terminal \
    nautilus \
    network-manager-gnome
  ```
- Enable GDM and NetworkManager services:
  ```bash
  systemctl enable gdm NetworkManager
  ```
- Setup native Firefox (Mozilla Team PPA / direct deb).

## Phase 8: Bootloader & Exit
- Install GRUB for EFI:
  ```bash
  apt-get install -y grub-efi-amd64 shim-signed
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Ubuntu
  update-grub
  ```
- Exit chroot, unmount virtual filesystems and reboot:
  ```bash
  exit
  umount -R /mnt
  reboot
  ```
