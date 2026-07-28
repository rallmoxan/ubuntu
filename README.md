# Ubuntu 26.04 LTS — Debootstrap Kurulum Rehberi (Snap'siz)

Bu rehber tek başına yeterlidir. Sohbete ihtiyacın yok.
Scriptler bu klasörde, numara sırasıyla çalıştırılır.

**Tüm paket isimleri, sürümler ve kod adı `resolute` arşivinden doğrulandı** —
hafızadan yazılmadı. Doğrulanmış gerçekler:

| Şey | Değer |
|---|---|
| Kod adı | `resolute` = Ubuntu 26.04 LTS (23 Nisan 2026) |
| Çekirdek | 7.0.0-28 |
| Mesa | 26.0.3 |
| GNOME | 50 |
| Ubuntu'nun `firefox` paketi | `1:1snap1-0ubuntu8` — `Pre-Depends: snapd`, **sadece snap kurar**, kullanma |
| Ubuntu'nun `thunderbird` paketi | `2:1snap1-0ubuntu5` — aynı şey, **epoch'u 2** (bu yüzden sürüm bazlı pin işe yaramaz, `o=Ubuntu` kaynağına göre pinleniyor) |
| `snapd` | `ubuntu-desktop-minimal` içinde **Recommends**, Depends değil → pin + `--no-install-recommends` yeterli |
| snapd'ye **sert** bağımlı paketler | resolute'ta 10 tane, hepsi `nosnap.pref`'te (aşağıda liste) |

---

## 0. Önce `config.sh`

Bu depo tek bir makineye özel değil. Makineye özel **her şey** `config.sh`
içinde; başka hiçbir dosyaya dokunman gerekmiyor.

**Zorunlu iki alan:**

```bash
TARGET_DISK_SERIAL=""   # SİLİNECEK disk
USERNAME=""             # açılacak kullanıcı
```

Diskin serisini şöyle bul:

```bash
lsblk -dno NAME,SIZE,MODEL,SERIAL
```

Boş bırakırsan diske dokunan her faz bu listeyi basıp durur — yanlışlıkla
yanlış diski silmek mümkün değil.

> ⚠️ **Diskleri asla `nvme0n1` / `nvme1n1` isimleriyle ayırt etme.** Live
> çekirdek altında sıra değişebilir. Bütün scriptler diski **seri numarasından**
> bulur, ayrıca live oturumun kendi diskini ve Faz 9'a ayrılmış diski silmeyi
> reddeder.

**İsteğe bağlı, makul varsayılanları var:**

| Ayar | Varsayılan | Ne işe yarar |
|---|---|---|
| `HOSTNAME` | `ubuntu-nosnap` | |
| `TIMEZONE` / `LOCALE` / `KEYMAP` | `Europe/Istanbul` / `en_US.UTF-8` / `us` | |
| `CPU_VENDOR` / `GPU_VENDOR` | `auto` | Mikrokod ve grafik yığını donanımdan tespit edilir |
| `DESKTOP_MODE` | `ubuntu` | `pure` (sade GNOME) veya `none` |
| `FIREFOX_CHANNEL` | `firefox-esr` | veya `firefox` |
| `THUNDERBIRD_REF` | `org.mozilla.thunderbird_esr` | Flathub kimliği |
| `MIGRATE_DISK_SERIAL` | boş | Faz 9 — ikinci disk yoksa boş bırak |

**NVIDIA notu:** tescilli sürücü **bilerek** kurulmuyor. Doğru sürücü kartın
kuşağına ve Secure Boot durumuna bağlı; tahmin etmek ilk açılışta siyah ekran
demek. Nouveau ile masaüstüne çıkarsın, sonra `sudo ubuntu-drivers install`.

### Sabit tasarım kararları

Disk düzeni: GPT · `p1` ESP (FAT32, `ESP_SIZE`) · `p2` kalan (btrfs)
Subvolume'ler: `@ @home @snapshots @var_log @var_cache @var_lib_flatpak`
Mount seçenekleri: `noatime,compress=zstd:3,ssd,discard=async,space_cache=v2`
Swap: sadece zram. Disk swap yok, hazırda bekletme yok.
Firmware: **sadece UEFI** — BIOS/CSM yolu yok.

---

## 1. Hazırlık — şu anki Debian'dan

**1.1 ISO indir**

```bash
curl -L -o ~/ubuntu-26.04-desktop-amd64.iso https://releases.ubuntu.com/26.04/ubuntu-26.04-desktop-amd64.iso
```

**1.2 Doğrula** — çıktı `OK` olmalı, olmazsa tekrar indir:

```bash
echo "487f87faaf547ea30e0aba4d5b53346292571256b25333a978db1692bcee9dd2  ~/ubuntu-26.04-desktop-amd64.iso" | sha256sum -c -
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
sudo dd if=~/ubuntu-26.04-desktop-amd64.iso of="$U" bs=4M status=progress oflag=direct conv=fsync && sync
```

**1.5 Scriptleri yanına al**

`dd` ile yazılmış çubuğa dosya kopyalayamazsın — ISO9660 olarak salt-okunur
hale gelir. Bu depoyu **ayrı** bir USB çubuğuna kopyala, ya da live oturumda
doğrudan klonla:

```bash
git clone <bu-deponun-adresi> ubuntu-nosnap && cd ubuntu-nosnap
```

Silmeyeceğin ikinci bir diskin varsa scriptleri orada da tutabilirsin.

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

**Scriptlere ulaş.** USB'den kopyaladıysan çubuğu bağla, ya da:

```bash
git clone <bu-deponun-adresi> && cd ubuntu-nosnap
```

**`config.sh`'i şimdi doldur** (0. bölüm). Diske dokunan hiçbir faz o dosya
eksikken çalışmaz:

```bash
lsblk -dno NAME,SIZE,MODEL,SERIAL
nano config.sh
```

---

## 3. Faz 2b — hedef diski sil ve bölümle

> ⚠️ **Bu adım `TARGET_DISK_SERIAL` diskindeki her şeyi kalıcı olarak yok
> eder.** Script `ERASE` yazmanı isteyecek. Başka hiçbir diske dokunmaz;
> `MIGRATE_DISK_SERIAL` ve live oturumun kendi diski açıkça korunur.

```bash
sudo bash phase2b-partition.sh
```

Sonunda `findmnt -R /mnt` çıktısında `/mnt`, `/mnt/home`, `/mnt/var/log`,
`/mnt/boot/efi` görünmeli. Görünmüyorsa devam etme.

Script diski seri numarasından bulur, `ERASE` onayı ister, bölümlerin
hazır olmasını bekler ve yanlış diske denk gelirse durur. Elle yapmanın
hiçbir avantajı yok.

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

Ayarlar `config.sh`'ten geliyor (`HOSTNAME`, `USERNAME`, `TIMEZONE`, `LOCALE`,
`KEYMAP`). Faz 3 o dosyayı da chroot'a kopyaladı; kontrol etmek istersen:

```bash
grep -E '^(HOSTNAME|USERNAME|TIMEZONE|LOCALE|KEYMAP)=' /root/install/config.sh
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

CPU mikrokodu ve grafik yığını donanımdan tespit edilir (`CPU_VENDOR`,
`GPU_VENDOR` = `auto`). AMD ve Intel tamamen Mesa ile karşılanır:
`mesa-libgallium` + `mesa-vulkan-drivers`. (`mesa-va-drivers` ve
`mesa-vdpau-drivers` 26.04'te **artık yok** — eski rehberlerdeki bu isimler
kurulumu komple durdurur.)

NVIDIA'da tescilli sürücü **bilerek kurulmaz**; script ne yapman gerektiğini
yazar. Nouveau ile masaüstüne çıkar, sonra `sudo ubuntu-drivers install`.

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

### Dosyanın başındaki üç değişken

```bash
head -60 /root/install/phase7-desktop.sh
```

| Değişken | Varsayılan | Diğer seçenek |
|---|---|---|
| `DESKTOP_MODE` | `"ubuntu"` — tam Ubuntu masaüstü, dock dahil | `"pure"` — bileşenlerden GNOME, dock yok |
| `FIREFOX_CHANNEL` | **`"firefox-esr"`** — yılda bir major, arada güvenlik yaması | `"firefox"` — rapid release, ~4 haftada bir major |
| `INSTALL_THUNDERBIRD` | `"flatpak"` — Flathub'dan kurar | `"no"` — atla |
| `THUNDERBIRD_REF` | **`"org.mozilla.thunderbird_esr"`** — ESR hattı | `"org.mozilla.Thunderbird"` — normal uygulama kimliği |

**Firefox kanalı.** İkisi de Mozilla'nın APT deposundan gelir; Ubuntu arşivinde
ikisi de yok (`firefox` orada snap kurucusu, `firefox-esr` hiç yok). Varsayılan
ESR, çünkü bu kurulumun geri kalanı da kararlılık için optimize edilmiş.

> **Doğrulanamadı:** Mozilla deposunun `firefox-esr` paketi taşıyıp taşımadığı
> bu script yazılırken kontrol edilemedi — `packages.mozilla.org` yazan
> makineden erişilemiyordu. Taşımıyorsa script **hiçbir tarayıcı kurmaz**,
> `apt policy firefox firefox-esr` çıktısını ekrana basar ve seçimi sana
> bırakır. İstemediğin bir sürüm kadansına sessizce düşmez.
>
> Bu durumda tek komut yeter:
>
> ```bash
> sudo apt install firefox
> ```

Firefox `Pin-Priority: 1000` ile `packages.mozilla.org` kaynağına sabitlenir.
Ubuntu'nun `firefox` paketini **asla kurma**.

Ağ takılır da script Firefox'u atlarsa (çıktıda söyler), ilk açılıştan sonra
depo zaten hazır olduğu için tek komut yeter:

```bash
sudo apt update && sudo apt install -y firefox && apt policy firefox
```

Çıktıda kaynağın `packages.mozilla.org` olduğunu ve sürümün `1:1snap1`
**olmadığını** gör.

**Thunderbird** fazın en sonunda Flathub'dan kurulur. Ubuntu'nun `thunderbird`
deb'i de `2:1snap1`, yani snap kurucusu — pin onu engelliyor. En sona konması
bilinçli: bu fazın en uzun ağ adımı, koptuğunda üstündeki her şey çoktan
bitmiş oluyor ve maliyeti ilk açılıştan sonra tek komut.

ESR ayrı bir **branch** değil, ayrı bir **uygulama kimliği**:
`org.mozilla.thunderbird_esr`. Bu ayrım önemli, çünkü Flatpak profil dizini
kimliğe göre isimlendiriliyor — iki kimlik profil paylaşmaz.

Script kurulumdan hemen önce Flathub'ın gerçekten yayınladığı Thunderbird
ref'lerini listeliyor, kurulumdan sonra da `flatpak info` ile ne geldiğini
basıyor. Kimlik değişirse aşağıdaki profil notu da kendini düzeltiyor
(değişkenden türetiliyor).

> **Profil yolu — Faz 9'dan önce oku.** Faz 9 eski profili `~/.thunderbird`
> altına geri getiriyor; deb sürümü oraya bakar, **Flatpak sürümü bakmaz**.
> Varsayılan kimlikle profil şurada:
>
> ```
> ~/.var/app/org.mozilla.thunderbird_esr/.thunderbird
> ```
>
> Geri yükledikten sonra taşı:
>
> ```bash
> mkdir -p ~/.var/app/org.mozilla.thunderbird_esr
> mv ~/.thunderbird ~/.var/app/org.mozilla.thunderbird_esr/.thunderbird
> ```
>
> Atlarsan Thunderbird boş hesap listesiyle açılır ve geri yükleme çalışmamış
> gibi görünür. Script bu notu kendi çıktısında da basıyor.

### snapd GNOME Shell eklentileri

`gnome-shell-ubuntu-extensions` paketi — `ubuntu-desktop-minimal`'in sert
bağımlılığı — snapd ile konuşmak için var olan iki Shell eklentisi taşıyor ve
Ubuntu bunları varsayılan olarak **açık** getiriyor:

```
/usr/share/gnome-shell/extensions/snapd-prompting@canonical.com/
/usr/share/gnome-shell/extensions/snapd-search-provider@canonical.com/
```

Bunlar snap değil, JavaScript. snapd olmadan hiçbir şey yapmıyorlar — arama
sağlayıcı hiç snap bulmuyor, izin sorucusunun soracağı bir daemon yok. Ama her
oturumda gnome-shell'e yükleniyorlar ve Extension Manager'da görünüyorlar.

Paketi kaldıramazsın: Ubuntu Dock, DING, AppIndicators ve Tiling Assistant da
onunla gider. Faz 7 bunun yerine bir gschema override yazıp ikisini kapatıyor
(`99-nosnap-extensions.gschema.override`). Varsayılanı değiştiriyor, yani
istersen Extension Manager'dan yine açabilirsin.

Zaten kurulmuş bir sistemde elle kapatmak istersen:

```bash
gnome-extensions disable snapd-prompting@canonical.com
gnome-extensions disable snapd-search-provider@canonical.com
```

Wayland'de değişikliğin görünmesi için oturumu kapatıp açman gerekir.

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

Kartının adı görünmeli — `llvmpipe` görüyorsan sürücü yüklenmemiş demektir.

```bash
sudo findmnt --verify --verbose
```

`Success, no errors or warnings detected` olmalı — fstab'da hata varsa burada çıkar.

> Ev dizinin **boş** olacak, bu normal: `/home` şu an kurulum diskindeki taze
> `@home` subvolume'ünde. Faz 9 kullanacaksan eski dosyaların hâlâ eski
> diskinde duruyor.

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

## 12. Faz 9 — /home'u ikinci diske taşı (isteğe bağlı)

Bu faz **isteğe bağlı** ve yalnızca eski bir kurulumun diskini yeni `/home`
yapmak istiyorsan gerekli. Tek diskin varsa `MIGRATE_DISK_SERIAL`'i boş bırak
ve bu bölümü atla.

Sistem düzgün açıldıktan **sonra**. Önce eski dosyaları al:

```bash
sudo bash /root/install/phase9-migrate-home.sh restore
```

İstediklerini kopyala (script komutu yazdırıyor). `.config` ve `.cache`'i
komple kopyalama — Debian GNOME ayarlarını GNOME 50'ye taşımak masaüstünü
bozmanın klasik yoludur; ihtiyacın olan uygulamaların klasörlerini tek tek al.

Elindekilerden emin olduktan sonra masaüstünden çık:

```bash
sudo systemctl isolate multi-user.target
```

> ⚠️ Açılan metin konsoluna **`root` olarak** giriş yap, normal kullanıcınla
> değil. Kendi kullanıcınla girersen ev dizinin `/home` üzerinde açık kalır,
> script de "processes are using /home" deyip haklı olarak durur. Root
> parolasını Faz 4'te belirlemiştin.

Sonra:

```bash
bash /root/install/phase9-migrate-home.sh migrate
```

Eski disk silinir, `/home` oraya taşınır, `fstab` güncellenir (yedeği
`/etc/fstab.bak`). Kopyalama sayıları tutmazsa fstab'a dokunmaz.

> **Araç kontrolü.** `migrate` ilk iş olarak ihtiyaç duyduğu bütün komutları
> kontrol eder ve eksik varsa **hiçbir şeye dokunmadan** durur, kurulacak
> paketleri de yazar:
>
> ```
> FATAL: missing command(s): sgdisk
>        Nothing has been touched. Install and re-run:
>            sudo apt install gdisk
> ```
>
> Bu kontrol sonradan eklendi ve sebebi şu: silme sırası `wipefs -a` sonra
> `sgdisk`. `sgdisk` yoksa script ERASE yazdıktan **sonra**, bölüm tablosu
> imzaları çoktan silinmişken patlıyordu. Artık ERASE sorulmadan önce
> duruyor.
>
> `gdisk` Faz 4'te kuruluyor; bu satırdan önce kurulmuş bir sistemde yoksa
> `sudo apt install gdisk` yeterli.

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

Faz 7 `INSTALL_THUNDERBIRD="flatpak"` ile onu zaten kurmuş olmalı. Kurmadıysa
(ağ koptuysa çıktıda söyler):

```bash
flatpak install flathub org.mozilla.thunderbird_esr
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
`~/.var/app/<uygulama-kimliği>/.thunderbird` altında arar (varsayılan kimlikle
`~/.var/app/org.mozilla.thunderbird_esr/`), deb sürümü `~/.thunderbird`
altında. 8. bölümdeki taşıma komutuna bak.

### Bir şekilde snapd geldi

```bash
sudo apt purge -y snapd && sudo rm -rf /snap /var/snap /var/lib/snapd && sudo apt-mark hold snapd
```

Sonra `/etc/apt/preferences.d/nosnap.pref` dosyasının durduğunu doğrula.

---

## 14. Dosyalar

| Dosya | Nerede çalışır |
|---|---|
| `config.sh` | **Önce bunu doldur** — bütün fazlar buradan okur |
| `phase2b-partition.sh` | Live USB |
| `phase3-debootstrap.sh` | Live USB |
| `phase4-core.sh` | chroot |
| `phase6-kernel.sh` | chroot |
| `phase7-desktop.sh` | chroot |
| `phase8-bootloader.sh` | chroot |
| `verify-before-reboot.sh` | chroot — **yeniden başlatmadan önce zorunlu** |
| `phase9-migrate-home.sh` | Açılmış Ubuntu (isteğe bağlı) |
| `README.md` | Bu dosya |
| `INSTALL_NOTES.md` | Karar ve donanım özeti (kısa referans kartı) |

Faz 3, bu klasörün tamamını `/mnt/root/install/` altına kopyalar; chroot'a
girdikten sonra rehber de yanında olur.

---

## 15. Kurulum sonrası — ayarlar, eksikler, yapılmaması gerekenler

Debootstrap kurulumu bittiğinde elinde çalışan ama **çıplak** bir sistem var.
Ubuntu'nun installer'ının senin yerine yaptığı bazı şeyler burada yapılmadı;
`--no-install-recommends` bilinçli bir tercihti ama bedeli var. Bu bölüm o
bedeli ve bu donanıma özel ayarları listeliyor.

### 15.1 Eksik olanlar — muhtemelen isteyeceklerin

`--no-install-recommends` yüzünden `ubuntu-standard`'ın **Recommends** listesi
hiç kurulmadı. İçinden dördü gerçekten önemli:

| Paket | Neden |
|---|---|
| `apparmor` | **Kurulu değil.** Ubuntu'nun varsayılan zorunlu erişim denetimi. Paketlerin AppArmor profilleri diskte duruyor ama uygulayacak kimse yok. Masaüstünde ilk sıraya koyardım. |
| `ufw` | Güvenlik duvarı. NAT arkasındaysan hayati değil, yine de bir satır. |
| `update-manager-core` | Bu olmadan **`do-release-upgrade` komutu yok**. Sürüm atlamayı planlıyorsan gerekli. |
| `command-not-found` | "komut bulunamadı, şu paketi kur" önerisi. Konfor. |

```bash
sudo apt install apparmor ufw update-manager-core command-not-found
sudo systemctl enable --now apparmor
sudo ufw enable
```

Güvenlik güncellemelerinin otomatik inmesini istersen (masaüstünde mantıklı;
her apt işleminden önce zaten snapshot alınıyor):

```bash
sudo apt install unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

### 15.2 Bu kuruluma özel — btrfs bakımı

Kök btrfs ve tek disk. İki ayar:

```bash
sudo apt install btrfsmaintenance
```

Haftalık `scrub` (sessiz veri bozulmasını yakalar, tek diskte **tespit** eder
ama onaramaz — yine de bozulmayı fark etmen değerli) ve periyodik `balance`
zamanlayıcıları kurar. Elle yapmak istersen ayda bir:

```bash
sudo btrfs scrub start / && sudo btrfs scrub status /
sudo btrfs filesystem usage /
```

> **Bilinçli tekrar:** fstab'da `discard=async` var **ve** `fstrim.timer`
> etkin. İkisi aynı işi yapıyor. Zararı yok, ama birini seçmek istersen genel
> tavsiye `discard=async`'i bırakıp `sudo systemctl disable fstrim.timer`
> demek. Bu repo ikisini de bırakıyor çünkü hangisinin bu SSD'de daha iyi
> davrandığı ölçmeden bilinmez.

VM imajı, veritabanı ya da büyük torrent dosyası tutacaksan o dizinde CoW'u
kapat — btrfs'te bu dosyalar aksi halde parçalanır:

```bash
mkdir -p ~/VMs && chattr +C ~/VMs
```

`chattr +C` **boş** dizinde çalışır; içi doluyken uygulamak mevcut dosyaları
etkilemez.

`/var/log` ayrı subvolume'de ama journald varsayılan olarak dosya sisteminin
%10'una kadar büyüyebilir. Sınırlamak istersen:

```bash
echo -e "[Journal]\nSystemMaxUse=500M" | sudo tee /etc/systemd/journald.conf.d/size.conf
sudo systemctl restart systemd-journald
```

### 15.3 Grafik ve zram doğrulaması

AMD ve Intel'de sürücü tarafında yapılacak bir şey yok — Mesa 26 kutudan
çalışıyor. Doğrula:

```bash
glxinfo -B | grep -E "OpenGL renderer|OpenGL version"
vulkaninfo --summary | head -20
```

Masaüstü makinesindeysen güç profilini sabitlemek mantıklı (dizüstünde
`balanced` bırak):

```bash
powerprofilesctl set performance
powerprofilesctl get
```

zram zaten ayarlı (`vm.swappiness=180`, `page-cluster=0` — sıkıştırılmış RAM
swap'ı için doğru değerler, diske swap'ın tersi; boyut RAM'in yarısı, 8 GiB
tavanla). Baskı altında ne olduğunu görmek istersen:

```bash
swapon --show && zramctl
cat /proc/pressure/memory
oomctl | head -20
```

`systemd-oomd` etkin ve agresif davranabilir. Bir uygulaman durup dururken
kapanıyorsa suçlu odur: `journalctl -u systemd-oomd -b`.

VRR monitörün varsa önce **Ayarlar → Ekranlar**'a bak; orada yoksa GNOME'un
deneysel bayrağı:

```bash
gsettings set org.gnome.mutter experimental-features "['variable-refresh-rate', 'scale-monitor-framebuffer']"
```

(İkincisi kesirli ölçekleme içindir; ihtiyacın yoksa listeden çıkar.)

### 15.4 Yazılım — snap'siz dünyada nereden ne kurulur

| İhtiyaç | Yol |
|---|---|
| Firefox | Zaten kurulu, Mozilla APT deposundan — varsayılan `firefox-esr`. `apt policy firefox firefox-esr` ile kaynağı ve kanalı doğrula |
| Thunderbird | Faz 7'de Flathub'dan kurulu. **Profil yolu** için 8. bölümdeki nota bak |
| Chromium | Flathub `org.chromium.Chromium` |
| Steam / oyun | Flathub `com.valvesoftware.Steam` |
| GNOME eklentileri | **Extension Manager** (kurulu). Tarayıcıdan kurmak istersen `sudo apt install gnome-browser-connector` |
| Mağaza | GNOME Software'de Flathub çalışıyor; `gnome-software-plugin-flatpak` kurulu, snap eklentisi kasıtlı olarak yok |

İlk açılışta Flathub metadata'sı henüz inmemiş olabilir:

```bash
flatpak update --appstream
```

### 15.5 Ubuntu Pro

Attach edeceksen otomatik servis açmayı kapat — `livepatch` snap gerektiriyor
ve pin yüzünden hata verir:

```bash
sudo pro attach <TOKEN> --no-auto-enable
sudo pro enable esm-infra esm-apps
```

`livepatch`'i hiç açma. Taze bir 26.04'te `esm-infra` 2031'e kadar boş durur;
bugünkü gerçek faydası `esm-apps` (universe paketleri için güvenlik desteği).

### 15.6 **Yapma** — bu sistemi bozan şeyler

| Yapma | Neden |
|---|---|
| `apt install firefox / thunderbird / chromium-browser` | Ubuntu arşivindeki üçü de `Pre-Depends: snapd` taşıyan snap kurucusu. Pin reddedecek |
| `pro enable livepatch` | `canonical-livepatch` sadece snap olarak var, `apt-get install snapd` deneyip hata verir |
| `APT::Snapshots::MaxAge` ayarlamak | Kök `noatime` bağlı; atime tabanlı temizlik hata verir **ve** otomatik temizliği kapatır |
| `libsnapd-glib-2-1` / `gir1.2-snapd-2` kaldırmak | Bunlar snapd değil, GLib binding'i. `libpipewire-0.3-modules` sert bağımlı — kaldırırsan **sesi öldürürsün** |
| `/etc/apt/preferences.d/nosnap.pref` silmek | Tek koruma katmanı bu |
| `EFI/BOOT/BOOTX64.EFI` silmek | Anakart NVRAM girdisini unutursa açılışı kurtaran dosya |
| Rastgele PPA eklemek | `apt policy snapd` çıktısını her PPA'dan sonra kontrol et |

### 15.7 Aylık rutin

```bash
sudo apt update && sudo apt full-upgrade     # öncesinde otomatik snapshot alınır
sudo apt-btrfs-snapshot list                 # snapshot gerçekten alınmış mı
apt policy snapd                             # Candidate: (none)
sudo btrfs scrub start /                     # btrfsmaintenance kurduysan gereksiz
flatpak update
```

Bir upgrade sistemi bozarsa 11. bölümdeki geri dönüş adımları.
