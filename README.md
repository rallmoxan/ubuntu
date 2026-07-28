# Ubuntu 26.04 LTS — Debootstrap Kurulum Rehberi (Snap'siz)

Bu rehber tek başına yeterlidir. Sohbete ihtiyacın yok.
Scriptler bu klasörde, numara sırasıyla çalıştırılır.

**Tüm paket isimleri, sürümler ve kod adı `resolute` arşivinden doğrulandı** —
hafızadan yazılmadı. Doğrulanmış gerçekler:

| Şey | Değer |
|---|---|
| Kod adı | `resolute` = Ubuntu 26.04 LTS (23 Nisan 2026) |
| Çekirdek | 7.0.0-28 (RX 9060 XT / RDNA4 tam destekli) |
| Mesa | 26.0.3 |
| GNOME | 50 |
| Ubuntu'nun `firefox` paketi | `1:1snap1-0ubuntu8` — `Pre-Depends: snapd`, **sadece snap kurar**, kullanma |
| Ubuntu'nun `thunderbird` paketi | `2:1snap1-0ubuntu5` — aynı şey, **epoch'u 2** (bu yüzden sürüm bazlı pin işe yaramaz, `o=Ubuntu` kaynağına göre pinleniyor) |
| `snapd` | `ubuntu-desktop-minimal` içinde **Recommends**, Depends değil → pin + `--no-install-recommends` yeterli |
| snapd'ye **sert** bağımlı paketler | resolute'ta 10 tane, hepsi `nosnap.pref`'te (aşağıda liste) |

---

## 0. Donanım ve plan

| | |
|---|---|
| CPU | AMD Ryzen 5 7500X3D |
| GPU | Radeon RX 9060 XT (RDNA4) + Raphael iGPU |
| RAM | 14 GiB |
| Firmware | UEFI |
| **Silinecek** | KINGSTON SNV3S1000G 931.5G — seri `50026B738450CE7B` |
| **Faz 9'a kadar korunacak** | SAMSUNG MZVLQ512HBLU 476.9G — seri `S6F5NL0TC03659` |

Disk düzeni: GPT · `p1` 1G ESP (FAT32) · `p2` kalan (btrfs)
Subvolume'ler: `@ @home @snapshots @var_log @var_cache @var_lib_flatpak`
Mount seçenekleri: `noatime,compress=zstd:3,ssd,discard=async,space_cache=v2`
Swap: sadece zram. Disk swap yok, hazırda bekletme yok.
Dil: `en_US.UTF-8`, klavye `us`, saat dilimi `Europe/Istanbul`.
Hostname: `barzbug`. Kullanıcı: `baris` (uid 1000).

> Bunların hepsi `phase4-core.sh` dosyasının başındaki blokta yazılı ve
> onaylandı — kurulum sırasında değiştirmen gereken bir şey yok.

> ⚠️ **Diskleri asla `nvme0n1` / `nvme1n1` isimleriyle ayırt etme.** Live
> çekirdek altında sıra değişebilir. Bütün scriptler diski **seri numarasından**
> bulur ve yanlış diske denk gelirse kendini durdurur.

---

## 1. Hazırlık — şu anki Debian'dan

**1.1 ISO indir**

```bash
curl -L -o /home/baris/ubuntu-26.04-desktop-amd64.iso https://releases.ubuntu.com/26.04/ubuntu-26.04-desktop-amd64.iso
```

**1.2 Doğrula** — çıktı `OK` olmalı, olmazsa tekrar indir:

```bash
echo "487f87faaf547ea30e0aba4d5b53346292571256b25333a978db1692bcee9dd2  /home/baris/ubuntu-26.04-desktop-amd64.iso" | sha256sum -c -
```

**1.3 USB'yi tak ve bul**

```bash
lsblk -dno NAME,SIZE,MODEL,SERIAL,TRAN,HOTPLUG
```

USB çubuğu `TRAN=usb`, `HOTPLUG=1` olarak görünür. NVMe diskler `nvme` / `0`.

**1.4 ISO'yu yaz**

Önce USB cihazını bir değişkene koy — **bölüm değil, disk** (`/dev/sdb`, `/dev/sdb1` değil):

```bash
U=/dev/sdX   # <-- 1.3'te bulduğun USB cihazı
```

Yazmadan önce doğru cihaza baktığını teyit et. Çıktıda NVMe diskleri
görüyorsan **dur**, `$U` yanlış:

```bash
lsblk -o NAME,SIZE,MODEL,TRAN,HOTPLUG "$U"
```

> ⚠️ **`dd` yanlış cihaza yazarsa o diski anında, onay sormadan yok eder.**
> Yukarıdaki çıktı gerçekten USB çubuğunu gösteriyorsa devam et.

```bash
sudo dd if=/home/baris/ubuntu-26.04-desktop-amd64.iso of="$U" bs=4M status=progress oflag=direct conv=fsync && sync
```

**1.5 (isteğe bağlı) İkinci bir yedek**

`dd` ile yazılmış çubuğa dosya kopyalayamazsın — ISO9660 olarak salt-okunur
hale gelir. Yedek istiyorsan **ayrı** bir USB çubuğu kullan:

```bash
cp -r /home/baris/Ubuntu /media/baris/IKINCI_USB/
```

Zorunlu değil: Samsung diski Faz 9'a kadar hiç silinmiyor, scriptler orada duruyor.

---

## 2. Live oturumu başlat

1. Yeniden başlat, UEFI menüsünden (çoğu anakartta `F11`/`F12`) USB'yi seç.
2. GRUB menüsünde **"Try or Install Ubuntu"**. Açılan kurulumcuda
   **"Try Ubuntu"** / *Ubuntu'yu dene* seçeneğini işaretle — *Install* değil.
3. Ağa bağlan (kablo veya Wi-Fi). **Ağ zorunlu**, tüm paketler ağdan geliyor.
4. Terminal aç (`Ctrl+Alt+T`).

**Secure Boot açıksa** kurulum yine çalışır (`shim-signed` kuruluyor). Kontrol:

```bash
mokutil --sb-state
```

**Scriptlere ulaş** — Samsung diski bağla:

```bash
sudo mkdir -p /mnt-old
sudo mount -o subvol=@home UUID=bc8fb1bb-a4a5-4fa6-a76b-d89047b401bb /mnt-old
ls /mnt-old/baris/Ubuntu/
```

```bash
cd /mnt-old/baris/Ubuntu
```

---

## 3. Faz 2b — Kingston'ı sil ve bölümle

> ⚠️ **Bu adım Debian kurulumunu kalıcı olarak yok eder.** Script `ERASE`
> yazmanı isteyecek. Samsung'a dokunmaz.

```bash
sudo bash phase2b-partition-kingston.sh
```

Sonunda `findmnt -R /mnt` çıktısında `/mnt`, `/mnt/home`, `/mnt/var/log`,
`/mnt/boot/efi` görünmeli. Görünmüyorsa devam etme.

**Elle yapmak istersen** — önce diski **seri numarasından** bul, cihaz adına
güvenme:

```bash
lsblk -dno NAME,SIZE,MODEL,SERIAL
```

Kingston'ın (`50026B738450CE7B`) hangi isme düştüğünü gör, sonra o ismi bir
değişkene koy ve komutlarda hep onu kullan:

```bash
D=/dev/nvme0n1   # <-- yukarıdaki çıktıda Kingston hangisiyse ONU yaz
```

> ⚠️ Aşağıdaki ilk komut `$D` diskini geri dönüşsüz siler. Yazmadan önce
> `lsblk $D` ile doğru diske baktığını teyit et.

```bash
sudo wipefs -a "$D" && sudo sgdisk --zap-all "$D" && sudo sgdisk -n1:0:+1G -t1:ef00 -c1:"EFI" "$D" && sudo sgdisk -n2:0:0 -t2:8304 -c2:"ubuntu-root" "$D" && sudo partprobe "$D"
```

```bash
sudo mkfs.vfat -F32 -n EFI "${D}p1" && sudo mkfs.btrfs -f -L ubuntu-root "${D}p2"
```

Ama script bunu seri numarası kontrolü, `ERASE` onayı ve bölüm-hazır beklemesiyle
birlikte yapıyor — elle yapmanın hiçbir avantajı yok.

---

## 4. Faz 3 — debootstrap

```bash
sudo bash phase3-debootstrap.sh
```

Bu script:
- `resolute` için debootstrap script'i yoksa `gutsy`'ye symlink atar,
- temel sistemi kurar (birkaç dakika),
- **`/etc/fstab`'ı üretir** — read-only açılışın bir numaralı sebebi eksik
  fstab kök satırıdır, bu script onu garanti eder,
- `/dev /proc /sys /run` bağlarını `--rbind` ile kurar (`--bind` değil:
  `--rbind` olmadan `/dev/pts` ve `efivars` chroot'a gelmez, `grub-install`
  UEFI kaydını yazamaz),
- kalan scriptleri `/mnt/root/install/` altına kopyalar.

Ekrana basılan fstab'ı **oku**. Kök satırı şuna benzemeli:

```
UUID=xxxx  /  btrfs  rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=@  0 0
```

---

## 5. chroot'a gir

```bash
sudo chroot /mnt /usr/bin/env -i HOME=/root TERM="$TERM" LANG=C.UTF-8 PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/bash --login
```

Artık yeni sistemin içindesin. Sıradaki bütün komutlar burada çalışır.
Doğru yerde olduğunu şöyle teyit edebilirsin — `resolute` yazmalı:

```bash
cat /etc/os-release | head -3 && ls /root/install/
```

---

## 6. Faz 4 + 5 — çekirdek yapılandırma ve snap engeli

Ayarlar dosyanın başında hazır: `HOSTNAME="barzbug"`, `USERNAME="baris"`,
`TIMEZONE="Europe/Istanbul"`. Değiştirmen gerekmiyor; yine de bir bakmak
istersen:

```bash
head -20 /root/install/phase4-core.sh
```

```bash
bash /root/install/phase4-core.sh
```

Yaptıkları, bu sırayla:
1. **`nosnap.pref`'i ilk iş olarak yazar** — tek bir `apt install` çalışmadan
   önce. Sonra yazarsan snapd bir Recommends üzerinden içeri sızabilir.
2. deb822 formatında APT kaynakları (`resolute`, `-updates`, `-backports`, `-security`).
3. **Pin'lerin çalıştığını kanıtlar**: `nosnap.pref`'teki **her** paket için
   adayın `(none)` olduğunu doğrular, biri bile geçerse kurulumu durdurur.

   Pin listesi "kuracağımız snap şeyler" değil, arşivde snapd'ye **sert**
   bağımlı (Depends / Pre-Depends) olan **her paket** — hiç kurmayacağın
   olanlar dahil. Kazara `apt install thunderbird` yazmayı hatırlamak zorunda
   kalmamak için:

   | Grup | Paketler |
   |---|---|
   | snapd ve makinesi | `snapd`, `snapd-seed-glue`, `snapd-installation-monitor` |
   | snap mağaza eklentileri | `gnome-software-plugin-snap`, `plasma-discover-backend-snap`, `fwupd-snap` |
   | sunucu/bulut metapaketleri | `ubuntu-server-minimal`, `ubuntu-cloud-minimal`, `livecd-rootfs` |
   | snap kurucu "deb"leri | `firefox`, `thunderbird` (`o=Ubuntu`), `chromium-browser` |

   Liste hafızadan değil arşivden çıkarıldı; komutu `nosnap.pref`'in yorumunda
   duruyor, sürüm atladıktan sonra tekrar çalıştırabilirsin.

   Firefox ve Thunderbird pin'i sürüm dizesine değil **kaynağa** bağlıdır
   (`Pin: release o=Ubuntu`): firefox'un epoch'u 1, thunderbird'ünki 2 —
   sürüm bazlı tek bir pin ikisini birden zaten tutamazdı, üstelik Ubuntu
   shim'i `1:1snap2` diye güncellenince de ıskalardı. Mozilla deposu
   `Origin: Mozilla`, Mozilla Team PPA'sı `Origin: LP-PPA-mozillateam`
   olduğu için gerçek deb'ler bu engelden etkilenmez.
4. `ubuntu-minimal` + `ubuntu-standard` (ikisi de snapd içermez — doğrulandı).
5. Locale, saat dilimi, klavye, hostname, `/etc/hosts`, `machine-id`.
6. Kullanıcı (uid 1000) + sudo grubu, **parola sorar**.

Sonunda kullanıcı ve root parolasını soracak. İkisini de gerçekten gir.

---

## 7. Faz 6 — çekirdek, firmware, AMD sürücüleri, zram

```bash
bash /root/install/phase6-kernel.sh
```

Önemli nokta: `btrfs-progs` initramfs üretilmeden **önce** kurulur. Aksi halde
initrd btrfs kökü bağlayamaz ve masaüstü yerine kernel panic alırsın.

RX 9060 XT için `mesa-libgallium` + `mesa-vulkan-drivers` kurulur.
(`mesa-va-drivers` ve `mesa-vdpau-drivers` 26.04'te **artık yok** — eski
rehberlerdeki bu isimler kurulumu komple durdurur.)

---

## 8. Faz 7 — GNOME 50 + Yaru, gerçek Firefox, Flatpak

```bash
bash /root/install/phase7-desktop.sh
```

`ubuntu-desktop-minimal` paketini `--no-install-recommends` ile kurar. Arşivden
doğrulandı: `snapd` ve snap-Firefox bu paketin **Recommends** listesinde,
Depends değil — yani gelmezler, ama tam Ubuntu masaüstünü (dock dahil) alırsın.

**Snap kütüphaneleri hakkında dürüst tablo.** Tüm paket listesinin bağımlılık
kapanışını (1087 paket) arşivden hesapladım. Sonuç:

| Paket | Nereden geliyor | Ne? |
|---|---|---|
| `gir1.2-snapd-2` | `ubuntu-desktop-minimal` → `gnome-shell-ubuntu-extensions` | GLib binding |
| `libsnapd-glib-2-1` | **`pipewire`** → `libpipewire-0.3-modules` (sert Depends) | GLib binding |

İkincisi önemli: `DESKTOP_MODE="pure"` yapsan bile `libsnapd-glib-2-1` yine
gelir, çünkü çalışan bir ses yığını olmadan sistem kullanılmaz ve PipeWire ona
sert bağımlı. **Snap kütüphanesiz bir masaüstü 26.04'te mümkün değil.**

Ama bunlar `snapd` **değil**: servis yok, `/snap` bağlantı noktası yok, snap
kurulamaz. Kapanış taramasında `snapd`'ye giden **tek** sert yol Ubuntu'nun
firefox kabuğuydu — o da pin'lenip script tarafından açıkça reddediliyor.

`"pure"` modun gerçek getirisi `gir1.2-snapd-2`'den kurtulmak; bedeli Ubuntu
Dock ve masaüstü simgelerinin gitmesi.

Firefox Mozilla'nın kendi APT deposundan kurulur ve `Pin-Priority: 1000` ile
sabitlenir. Ubuntu'nun `firefox` paketini **asla kurma**.

Ağ takılır da script Firefox'u atlarsa (çıktıda söyler), ilk açılıştan sonra
depo zaten hazır olduğu için tek komut yeter:

```bash
sudo apt update && sudo apt install -y firefox && apt policy firefox
```

Çıktıda kaynağın `packages.mozilla.org` olduğunu ve sürümün `1:1snap1`
**olmadığını** gör.

---

## 9. Faz 8 — GRUB

```bash
bash /root/install/phase8-bootloader.sh
```

- `rootflags=subvol=@` **açıkça** yazılır. GRUB bunu genelde kendi bulur; bulamazsa
  initramfs btrfs'in en üst seviyesini bağlar, `/sbin/init`'i bulamaz, açılış ölür.
- initramfs'te btrfs var mı diye kontrol eder, yoksa durur.
- GRUB iki kez kurulur: NVRAM kaydı **ve** `EFI/BOOT/BOOTX64.EFI` yedeği.
  Disk silindikten sonra NVRAM'i yok sayan anakartlarda seni kurtaran ikincisidir.
- `GRUB_CMDLINE_LINUX_DEFAULT` **boş** bırakılır (`quiet splash` yok) — ilk
  açılışta bütün çekirdek mesajlarını göresin diye. Sorunsuz açıldıktan sonra
  istersen `/etc/default/grub` içinde `"quiet splash"` yapıp `sudo update-grub` çalıştır.
- `/etc/resolv.conf` symlink'i **en sonda** yapılır: erken yapılsaydı chroot
  içindeki apt'ın DNS'i kırılırdı.
- **`apt-btrfs-snapshot` kurulur** — Faz 2b'den beri duran `@snapshots`
  altyapısı ilk kez işe yarıyor. `/etc/apt/apt.conf.d/80-btrfs-snapshot`
  içindeki `DPkg::Pre-Invoke` kancası, **her dpkg çalışmasından önce** `@`
  subvolume'ünün snapshot'ını alır. Bozuk bir upgrade artık yeniden kurulum
  değil, bir `set-default` + reboot meselesi. Kurulum sırası bilinçli:
  `autoremove`'dan **sonra**, çünkü APT `apt.conf.d`'yi başlangıçta bir kez
  okur — yani kanca kendi kurulumu sırasında tetiklenmez ve önceki fazlar
  chroot içinde boşuna snapshot almaz.
- `--no-install-recommends` **kalıcı** hale getirilir
  (`/etc/apt/apt.conf.d/99norecommends`). Bütün fazlar bu bayrağı komut
  satırında geçiyordu, ama o sadece o tek komut için geçerli — ilk açılıştan
  sonra `sudo apt install X` dediğinde Recommends geri gelirdi. Dosya
  `autoremove`'dan **sonra** yazılır; daha erken yazılsa kurulum fazlarının
  neyi çözdüğünü değiştirirdi. Tek seferlik istisna: `apt install --install-recommends X`.

---

## 10. Yeniden başlatmadan ÖNCE — denetim

```bash
bash /root/install/verify-before-reboot.sh
```

Bu, geçen seferki hatanın tekrarını engellemek için yazıldı. 7 başlıkta
kontrol eder: fstab, çekirdek/initramfs, GRUB/ESP, kullanıcı ve parolalar,
servisler ve boot hedefi, snap politikası, locale/zram/DNS.

**Tek bir `FAIL` varsa yeniden başlatma.** Script zaten sıfırdan farklı kodla
çıkar ve ne yapman gerektiğini yazar.

Hepsi `PASS` ise chroot'tan çık:

```bash
exit
```

Live oturumda, `/mnt` içinde durmadığından emin ol ve çöz:

```bash
cd / && sudo umount -R /mnt
```

`target is busy` derse ne tuttuğuna bak ve tekrar dene:

```bash
sudo fuser -vm /mnt ; sudo umount -R -l /mnt
```

```bash
sudo reboot
```

Kapanırken USB'yi çıkar.

---

## 11. İlk açılıştan sonra

```bash
findmnt /
```

`subvol=/@` ve `rw` görmelisin. `ro` görürsen 13. bölüme git.

```bash
free -h && swapon --show
```

zram swap görünmeli (~7G).

```bash
apt policy snapd
```

`Candidate: (none)` olmalı.

```bash
glxinfo -B | grep -E "OpenGL renderer|OpenGL version"
```

`AMD Radeon RX 9060 XT` görünmeli.

```bash
sudo findmnt --verify --verbose
```

`Success, no errors or warnings detected` olmalı — fstab'da hata varsa burada çıkar.

> Ev dizinin **boş** olacak, bu normal: `/home` şu an Kingston'daki taze
> `@home` subvolume'ünde. Eski dosyaların Samsung'da duruyor, Faz 9'da alacaksın.

Her şey iyiyse `quiet splash`'ı açabilirsin:

```bash
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=""/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' /etc/default/grub && sudo update-grub
```

### Snapshot'lar ve geri dönüş

İlk `apt` çalışmasından itibaren her dpkg işleminden önce otomatik snapshot
alınır. Listelemek için:

```bash
sudo apt-btrfs-snapshot list
```

`@apt-snapshot-2026-07-28_14:03:11` gibi isimler göreceksin. Bozuk bir upgrade
sonrası geri dönmek:

```bash
sudo apt-btrfs-snapshot set-default @apt-snapshot-2026-07-28_14:03:11
sudo reboot
```

`set-default` mevcut `@`'yı `@apt-snapshot-old-root-<tarih>` olarak yeniden
adlandırıp seçtiğin snapshot'ı `@` yapar. GRUB'un `rootflags=subvol=@` ile
**isme** göre boot etmesi (subvolid'ye değil) bunu sorunsuz kılıyor — Faz 8'in
o satırı açıkça yazmasının ikinci faydası.

Bilmen gereken dört şey:

| | |
|---|---|
| Nerede duruyorlar | btrfs'in **en üst seviyesinde** `@apt-snapshot-*` olarak, `/.snapshots` içinde değil |
| Ne snapshot'lanıyor | **sadece `@`** — `/home`, `/var/log`, `/var/cache`, `/var/lib/flatpak` ayrı subvolume'ler, geri dönüş verini geri almaz |
| Temizlik | snapshot alınırken otomatik: son 8 saatlik, 7 günlük, 2 haftalık (`/etc/apt/apt.conf.d/81-btrfs-snapshot-retain`) |
| **Dokunma** | `APT::Snapshots::MaxAge` **ayarlama**. Temizliği atime tabanlı yola çevirir, kök `noatime` bağlı olduğu için hata verir, üstelik yukarıdaki otomatik temizliği de kapatır |

> Not: paketin içindeki `/etc/cron.weekly/apt-btrfs-snapshot` yorumu ayar
> anahtarını `APT::Snapshots::Retain::*` (çoğul) diye belgeliyor. Kodun
> gerçekte okuduğu `APT::Snapshot::Retain::*` (tekil) — çoğul yazım sessizce
> hiçbir şey yapmaz. Repodaki dosya doğru olanı kullanıyor.

Snapshot'tan **boot menüsü** üzerinden dönmek istersen `grub-btrfs` gerekiyor;
Ubuntu arşivinde yok, elle kurulması lazım. Bu repo onu kapsamıyor.

---

## 12. Faz 9 — Samsung diski (en son)

Sistem düzgün açıldıktan **sonra**. Önce eski dosyaları al:

```bash
sudo bash /root/install/phase9-home-to-samsung.sh restore
```

İstediklerini kopyala (script komutu yazdırıyor). `.config` ve `.cache`'i
komple kopyalama — Debian GNOME ayarlarını GNOME 50'ye taşımak masaüstünü
bozmanın klasik yoludur; ihtiyacın olan uygulamaların klasörlerini tek tek al.

Elindekilerden emin olduktan sonra masaüstünden çık:

```bash
sudo systemctl isolate multi-user.target
```

> ⚠️ Açılan metin konsoluna **`root` olarak** giriş yap, `baris` olarak değil.
> `baris` ile girersen ev dizinin `/home` üzerinde açık kalır, script de
> "processes are using /home" deyip haklı olarak durur. Root parolasını
> Faz 4'te belirlemiştin.

Sonra:

```bash
bash /root/install/phase9-home-to-samsung.sh migrate
```

Samsung silinir, `/home` oraya taşınır, `fstab` güncellenir (yedeği
`/etc/fstab.bak`). Kopyalama sayıları tutmazsa fstab'a dokunmaz.

```bash
sudo reboot
```

```bash
findmnt /home
```

---

## 13. Sorun giderme

### "Sistem read-only açıldı" — geçen seferki hata

Sebep neredeyse her zaman şunlardan biridir:

1. **`/etc/fstab`'da kök satırı yok.** systemd kökü rw yapmak için fstab'a
   bakar; satır yoksa initramfs'in bıraktığı `ro` halde kalır. En sık sebep budur.
2. Kök satırında `ro` yazıyor.
3. btrfs hata verip kendini `ro`'ya düşürmüş (disk/kablo sorunu).

**Adım 1 — önce yazılabilir yap.** Bunu yapmadan `/etc/fstab`'ı zaten
düzenleyemezsin:

```bash
sudo mount -o remount,rw /
```

**Adım 2 — kök satırı var mı bak:**

```bash
awk '$1 !~ /^#/ && $2=="/" {print}' /etc/fstab
```

**Adım 3 — çıktı boşsa satırı ekle:**

```bash
echo "UUID=$(findmnt -no UUID /)  /  btrfs  rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=@  0 0" | sudo tee -a /etc/fstab
```

Ekledikten sonra doğrula ve yeniden başlat:

```bash
sudo findmnt --verify --verbose && sudo reboot
```

**btrfs hatası mı diye bak:**

```bash
sudo dmesg | grep -i btrfs | tail -20
```

`forced readonly` geçiyorsa dosya sistemi bozulmuş demektir; `btrfs check`
gerekir, fstab'ın suçu yoktur.

### debootstrap "Retrieving InRelease" satırında donuyor

**Bu senin ağında gerçekten oluyor** — test ederken bizzat karşılaştım. `wget`
IPv6 üzerinden `archive.ubuntu.com`'a bağlanmaya çalışıp sonsuza kadar
bekliyor; `curl`'ün aksine IPv4'e düşmüyor. `curl` çalışıyor olması bir şey
kanıtlamaz, debootstrap `wget` kullanır.

`phase3-debootstrap.sh` bunu kendisi tespit edip düzeltiyor. Elle yapman
gerekirse:

```bash
printf 'inet4_only = on\ntimeout = 30\ntries = 5\n' | sudo tee -a /etc/wgetrc
```

Doğrula — anında dönmeli:

```bash
time wget -q -O /dev/null http://archive.ubuntu.com/ubuntu/dists/resolute/InRelease && echo OK
```

Kurulum yarıda kaldıysa **üstüne devam etme**: `/mnt/debootstrap` klasörü varsa
sistem yarım demektir. `phase2b`'yi baştan çalıştır (diski yeniden biçimlendirir).
`phase3` bunu zaten kontrol edip yarım kurulumun üstüne yazmayı reddediyor.

### Hiç açılmıyor / GRUB gelmiyor

Live USB'den aç, sonra:

Bölümlerin etiketleri var, o yüzden cihaz adı tahmin etmene gerek yok:

```bash
sudo mount -o subvol=@ /dev/disk/by-label/ubuntu-root /mnt && sudo mount /dev/disk/by-label/EFI /mnt/boot/efi
```

```bash
for f in dev proc sys run; do sudo mount --rbind /$f /mnt/$f && sudo mount --make-rslave /mnt/$f; done
```

```bash
sudo chroot /mnt /bin/bash
```

İçeride:

```bash
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Ubuntu --recheck && grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --recheck && update-grub
```

### GRUB var, çekirdek panic ("cannot mount root")

`rootflags=subvol=@` eksiktir. GRUB menüsünde `e` ile satırı düzenle, `linux`
satırının sonuna ekle, `Ctrl+X`. Açıldıktan sonra kalıcı yap:

```bash
sudo sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="rootflags=subvol=@"/' /etc/default/grub && sudo update-grub
```

### Metin konsolu geliyor, masaüstü gelmiyor

```bash
systemctl status gdm3
systemctl get-default
```

```bash
sudo systemctl enable gdm3 && sudo systemctl set-default graphical.target
```

### Ağ yok

```bash
systemctl status NetworkManager
nmcli device status
```

```bash
sudo systemctl enable --now NetworkManager
```

DNS çalışmıyorsa:

```bash
ls -l /etc/resolv.conf && systemctl status systemd-resolved
```

### `apt update && apt full-upgrade` snap'i geri getirir mi?

**Hayır.** `nosnap.pref` hiçbir pakete ait olmayan yerel bir dosyadır; APT onu
güncelleme sırasında ne siler ne üzerine yazar. `Pin-Priority: -1` "asla kurma,
**bağımlılık olarak bile**" demektir. İleride bir paket `Depends: snapd` haline
gelirse APT snapd'yi kurmaz, **o paketi geri tutar** (`kept back`) — yani en kötü
senaryo "snap geri geldi" değil, "bir paket güncellenmedi".

Upgrade çıktısında `libsnapd-glib-2-1` ve `gir1.2-snapd-2` güncellenirken
görürsen panik yapma: bunlar snapd **değil**, sadece GLib binding kütüphaneleri
(`libpipewire-0.3-modules` bunlara sert bağımlı, 26.04'te kaçınılmaz — 8. bölüme
bak). Servis yok, `/snap` mount yok, snap kurulamaz.

Upgrade sonrası denetim:

```bash
apt policy snapd            # Candidate: (none)
dpkg -l snapd 2>/dev/null   # boş
ls -d /snap                 # olmamalı
apt-mark showhold           # snapd görünmeli
apt policy firefox          # kaynak packages.mozilla.org olmalı
apt policy thunderbird      # Ubuntu'nun 2:1snap1'i OLMAMALI
sudo apt-btrfs-snapshot list  # upgrade öncesi snapshot alınmış olmalı
```

Arşiv değişmiş mi diye bakmak istersen — snapd'ye sert bağımlı olup pin'de
adı geçmeyen bir paket var mı:

```bash
apt-cache rdepends snapd \
  | awk '/Reverse Depends:/{f=1;next} f{gsub(/^[ |]+/,""); print $1}' | sort -u \
  | while read -r p; do
      [ "$(apt-cache policy "$p" | awk '/Candidate:/{print $2}')" = "(none)" ] || echo "$p"
    done
```

Çıktı boşsa her şey yerinde. Bir isim çıkarsa `nosnap.pref`'e ekle —
snapd zaten -1'de olduğu için o paket **kurulamaz**, ama eklemek anlaşılmaz
bir bağımlılık hatası yerine temiz bir ret verir.

`kept back` uyarısı görürsen sebebini `apt install -s <paket>` ile bul.

Asıl dikkat edilecek yer normal upgrade değil, **sürüm yükseltmesidir**
(`do-release-upgrade`): `ubuntu-release-upgrader` üçüncü parti depoları (Mozilla
dahil) devre dışı bırakır. Sürüm atladıktan sonra yukarıdaki beş komutu tekrar
çalıştır ve `/etc/apt/sources.list.d/mozilla.sources` dosyasının hâlâ etkin
olduğunu doğrula.

### Thunderbird kurmak istiyorum

`sudo apt install thunderbird` **çalışmaz** ve çalışmaması doğru: Ubuntu'nun
`thunderbird` paketi `2:1snap1-0ubuntu5`, `Pre-Depends: snapd` taşıyan bir snap
kurucusu. `nosnap.pref` onu `o=Ubuntu` ile engelliyor.

Gerçek Thunderbird için iki yol — Flatpak Faz 7'de zaten kurulu:

```bash
flatpak install flathub org.mozilla.Thunderbird
```

ya da Mozilla'nın APT deposunda `thunderbird` paketi varsa (depo Faz 7'de
eklendi, `o=Ubuntu` pin'i onu etkilemez):

```bash
apt policy thunderbird     # kaynak packages.mozilla.org mu?
sudo apt install thunderbird
```

Aynısı Chromium için: `chromium-browser` engelli, Flathub'dan
`org.chromium.Chromium` kur.

Faz 9 eski `~/.thunderbird` profilini geri getiriyor; Flatpak sürümü profili
`~/.var/app/org.mozilla.Thunderbird/.thunderbird` altında arar, deb sürümü
`~/.thunderbird` altında. Hangisini kuracağına buna göre karar ver.

### Bir şekilde snapd geldi

```bash
sudo apt purge -y snapd && sudo rm -rf /snap /var/snap /var/lib/snapd && sudo apt-mark hold snapd
```

Sonra `/etc/apt/preferences.d/nosnap.pref` dosyasının durduğunu doğrula.

---

## 14. Dosyalar

| Dosya | Nerede çalışır |
|---|---|
| `phase2b-partition-kingston.sh` | Live USB |
| `phase3-debootstrap.sh` | Live USB |
| `phase4-core.sh` | chroot |
| `phase6-kernel.sh` | chroot |
| `phase7-desktop.sh` | chroot |
| `phase8-bootloader.sh` | chroot |
| `verify-before-reboot.sh` | chroot — **yeniden başlatmadan önce zorunlu** |
| `phase9-home-to-samsung.sh` | Açılmış Ubuntu |
| `KURULUM_REHBERI.md` | Bu dosya |
| `INSTALL_NOTES.md` | Karar ve donanım özeti (kısa referans kartı) |

Faz 3, bu klasörün tamamını `/mnt/root/install/` altına kopyalar; chroot'a
girdikten sonra rehber de yanında olur.
