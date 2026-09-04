> **Not:** Kanonik dokumantasyon [README.md](README.md) (Ingilizce). Bu Turkce
> surum geride kalmis olabilir.

# maas-proxmox

MAAS ile bare-metal sunuculara deploy edilebilen **Proxmox VE** imajlari uretir.
Deploy edilen dugum ilk acilista kendini yapilandirir: `vmbr0` koprusunu kurar,
`local-lvm` thin havuzunu olusturur ve istenirse bir Proxmox kumesine otomatik katilir.

Varsayilan hedef: **Proxmox VE 9.x** (Debian 13 "trixie" tabanli).

---

## Nasil calisiyor?

```
Debian 13 cloud image (qcow2)
   │
   ├─ packer-maas / debian sablonu  (QEMU + KVM)
   │     ├─ cloud-init, netplan, curtin uyumlulugu   [upstream]
   │     ├─ disk/cpu/ram yamasi (4G -> 16G)          [bu proje]
   │     └─ customize-proxmox.sh                      [bu proje]
   │           ├─ Proxmox APT deposu + anahtarlik
   │           ├─ proxmox-default-kernel + proxmox-ve
   │           ├─ Debian cekirdegi / os-prober kaldirilir
   │           ├─ pmxcfs dugum kimligi sifirlanir
   │           └─ overlay: pve-maas-init + systemd unit + curtin-hooks
   │
   └─ proxmox-ve-9.tar.gz  ──►  maas boot-resources create
                                      │
                                      ▼
                             MAAS deploy (curtin)
                                      │
                                      ▼
                         pve-maas-init.service (ilk acilis)
                            hosts → identity → rootpw →
                            network → cluster → storage
```

Neden Proxmox ISO'su degil de Debian uzerine kurulum? MAAS imaji disk bolumlemesini,
ag yapilandirmasini, kullanici/SSH anahtarlarini ve cloud-init'i **curtin** ile kendisi
yonetir. Debian tabanli imaj bu akisa dogal olarak uyar; ISO'dan yakalanan ham disk
imaji (`dd.gz`) ise MAAS'in disk duzenini tamamen devre disi birakir.

---

## Dogrulanmis durum

**Kanonik ve ayrintili liste [README.md](README.md#verified-status) icindedir** -
neyin test edildigi ve neyin edilmedigi orada secenek secenek isaretlidir.

Ozet: iki dugumlu bir kume, MAAS 3.7.2 uzerinde, elle mudahale olmadan kuruldu
(proxmox-ve 9.2.0 / pve-manager 9.2.11 / kernel 7.0.14-15-pve). vmbr0 donusumu,
root parolasi, dugum kimligi, local-lvm thin havuzu, kume olusturma ve katilma
calisir durumda goruldu.

Test EDILMEYENLER de az degil: `PVE_CLUSTER_LINK0` (ayri corosync agi), parmak izi
otomatik kesfi, `PVE_NET_APPLY=reload`, bond/VLAN topolojileri, IPv6, arm64, BIOS
onyukleme, `pve-enterprise` deposu, `deploy-cluster.sh`'in gercek deploy yolu ve
gercek bare-metal donanim (test dugumleri sanal makineydi). Tam liste Ingilizce
dokumanda.

## Gereksinimler

**Build host** (imajin derlendigi makine):

* Ubuntu 22.04+ (24.04 LTS onerilir), x86_64
* **Nested virtualization / KVM erisimi** — VM ise CPU tipi `host` olmali
* 4+ vCPU, 8+ GB RAM, 25+ GB bos disk
* `sudo` yetkisi

**Deploy tarafi:**

* MAAS 3.2+ (custom image destegi)
* Curtin 21.0+
* Region controller uzerinde bu depodaki curtin preseed dosyasi (asagida)

---

## Hizli baslangic

```bash
# 1) Build host bagimliliklari (packer, qemu, nbdkit, ovmf, ...)
sudo ./scripts/install-deps.sh

# 2) Imaji derle  (~20-40 dk, ag hizina bagli)
sudo make image
#    -> build/proxmox-ve-9.tar.gz

# 3) MAAS curtin preseed dosyasini uret
make preseed
#    -> build/curtin_userdata_custom_amd64_generic_proxmox-ve-9

# 4) Preseed'i MAAS region controller'a kopyala
sudo make install-preseed
#    (varsayilan: /var/snap/maas/current/preseeds/ ; deb kurulumunda
#     MAAS_PRESEED_DIR=/etc/maas/preseeds kullanin)

# 5) Imaji MAAS'a yukle
make upload MAAS_PROFILE=admin
```

Ardindan MAAS arayuzunde makineyi deploy ederken OS olarak
**Custom → Proxmox VE 9** secin, ya da CLI ile:

```bash
maas $PROFILE machine deploy $SYSTEM_ID \
    osystem=custom distro_series=proxmox-ve-9 \
    user_data="$(base64 -w0 maas/examples/01-first-node.yaml)"
```

---

## Makefile degiskenleri

| Degisken | Varsayilan | Aciklama |
|---|---|---|
| `PVE_VERSION` | `9` | Proxmox VE ana surumu (imaj adinda kullanilir) |
| `DEBIAN_SERIES` | `trixie` | PVE'nin dayandigi Debian kod adi |
| `DEBIAN_VERSION` | `13` | Debian ana surum numarasi |
| `PVE_REPO` | `pve-no-subscription` | `pve-no-subscription` / `pve-enterprise` / `pve-test` |
| `PVE_EXTRA_PACKAGES` | `ifupdown2 open-iscsi chrony ...` | Imaja eklenecek ek paketler |
| `IMAGE_NAME` | `proxmox-ve-9` | MAAS'taki `custom/<ad>` ve preseed dosya adi |
| `ARCH` / `BOOT` | `amd64` / `uefi` | Mimari ve onyukleme modu |
| `DISK_SIZE` | `16G` | Build VM disk boyutu (upstream sablondaki 4G yetersiz) |
| `BUILD_CPUS` / `BUILD_MEM` | `4` / `4096` | Build VM kaynaklari |
| `DEBIAN_IMAGE_CHANNEL` | `stable` | `stable` sabit URL kullanir (packer onbellegi isabet eder); `daily` upstream varsayilani |
| `GZIP_LEVEL` | `6` | Tarball sikistirma seviyesi (upstream 9; 6 belirgin hizli, imaj ~%2-3 buyuk) |
| `APT_PROXY` | *(bos)* | Yerel APT onbellegi, or. `http://10.0.2.2:3142` - bkz. `make deps-cache` |
| `PM_REF` | `main` | Kullanilacak `canonical/packer-maas` surumu (dal, etiket ya da commit SHA) |
| `MAAS_PROFILE` | `admin` | `maas` CLI profil adi |
| `MAAS_PRESEED_DIR` | `/var/snap/maas/current/preseeds` | Preseed dizini |
| `TIMEOUT` | `3h` | Packer build zaman asimi |

### Derlemeyi hizlandirma

Sure agirlikli olarak VM icindeki paket kurulumunda geciyor. Uygulanan
optimizasyonlar (varsayilan olarak acik):

* **eatmydata** - dpkg'nin her paket icin yaptigi `fsync` cagrilari devre disi.
  Imaj derlemede guvenli, cunku build VM'inin diski zaten atilabilir.
* **initramfs erteleme** - `update-initramfs` kurulum boyunca diverte edilir ve
  en sonda yalnizca bir kez calistirilir (cekirdek + firmware + dkms
  tetikleyicileri normalde defalarca calistiriyor).
* **Kararli cloud image** - sabit URL sayesinde packer'in onbellegi isabet eder;
  `daily` her gun degistigi icin her derlemede ~350MB yeniden inerdi.
* **`GZIP_LEVEL=6`** - upstream `--best` (9) kullaniyor; 6 ile `pigz` cok
  cekirdekli calisip belirgin hizlaniyor.

Tekrarlanan derlemeler icin en buyuk ek kazanc yerel APT onbellegi:

```bash
sudo make deps-cache                                  # apt-cacher-ng kurar
sudo make image APT_PROXY=http://10.0.2.2:3142        # ~700MB indirme onbellekten
```

`10.0.2.2`, packer'in user-mode aginda build host'un adresidir. Proxy verildiginde
Debian depolari `https` yerine `http` kullanacak sekilde yeniden yazilir (onbellek
CONNECT tunelini saklayamaz); paket imzalari yine dogrulandigi icin guvenlik
kaybi yoktur.

### Yeni bir Proxmox surumune gecmek

Once ne oldugunu gorun - derleme yapmadan, saniyeler icinde:

```bash
make check-upstream
```

Depodaki guncel `proxmox-ve` / `pve-manager` surumlerini, elinizdeki imajin
kunyesiyle (`/etc/pve-maas/image-info`) yan yana gosterir.

**Durum 1 - ayni Debian tabani icinde surum yukseltmesi (9.2 -> 9.3 -> ...)**

Hicbir sey degistirmeniz gerekmez. Imajda surum sabitlemesi yok; her derleme
depodaki en guncel `proxmox-ve` paketini alir:

```bash
sudo make image && make verify && make upload
```

Imaj adi (`proxmox-ve-9`) ve preseed dosyasi ayni kaldigi icin MAAS'taki kayit
yerinde guncellenir, preseed'e dokunmaniza gerek kalmaz.

**Durum 2 - Debian tabanini degistiren ana surum (or. PVE 10 / Debian 14)**

Bu **otomatik degildir**; bu depodaki degiskenleri degistirmek tek basina yetmez.
Sebep: temel aldigimiz `canonical/packer-maas` sablonunun icinde Debian surumune
ozel sabit kosullar var -

```
debian/scripts/networking.sh:  if [ ${DEBIAN_VERSION} == '12' ] || [ ${DEBIAN_VERSION} == '13' ]
debian/scripts/setup-boot.sh:  if [ ${DEBIAN_VERSION} == '13' ]
```

Bilinmeyen bir surumde bu kosullar `else` dalina duser ve 2020 tarihli bir
cloud-init paketi kurulur; imaj sessizce bozulur. Bu yuzden ana surum gecisi
**upstream'in yeni Debian'i desteklemesini bekler**. Sirasi:

1. `canonical/packer-maas` yeni Debian'i destekliyor mu?
   (`debian/scripts/` icindeki `DEBIAN_VERSION` kosullarina bakin)
2. Proxmox anahtarligi yayinlanmis mi?
   `https://enterprise.proxmox.com/debian/proxmox-archive-keyring-<suite>.gpg`
3. Depoda paketler var mi?
   `curl -s http://download.proxmox.com/debian/pve/dists/<suite>/Release | grep Components`
4. Sonra:

```bash
sudo make image PVE_VERSION=10 DEBIAN_SERIES=forky DEBIAN_VERSION=14 PM_REF=main
make preseed PVE_VERSION=10
```

Yeni preseed dosyasinin adi da degisir (`..._proxmox-ve-10`) - MAAS'a kurmayi
unutmayin.

### Upstream surum sabitlemesi

`PM_REF`, test edilmis bir `canonical/packer-maas` commit'ine sabitlenmistir.
`main` birakmak, upstream'de yapilan bir degisikligin derlemenizi haber vermeden
bozmasi anlamina gelir. Ileri tasirken `PM_REF=main` ile derleyip **deploy ederek**
test edin, sonra yeni SHA'yi Makefile'a yazin.

---

## Dugumun ilk acilis davranisi

Imajda `pve-maas-init.service` etkin gelir. Servis su asamalari sirayla, her birini
yalnizca bir kez calistirir (`/var/lib/pve-maas/<asama>.done`):

| Asama | Ne yapar |
|---|---|
| `hosts` | `/etc/hosts` icinde `<yonetim-ip> <fqdn> <hostname>` satirini kurar (pvecm bunu sart kosar), postfix `myhostname` degerini duzeltir |
| `identity` | Dugume ozel kimlikleri yeniden uretir (iSCSI IQN) |
| `rootpw` | `root@pam` parolasini ayarlar |
| `network` | MAAS'in yapilandirdigi arayuzu `vmbr0` koprusune donusturur, cloud-init/netplan ag yapilandirmasini devre disi birakir |
| `cluster` | Kume olusturur (`create`) veya mevcut kumeye katilir (`join`) |
| `storage` | VG'deki bos alanda LVM-thin havuzu acar ve `local-lvm` olarak tanimlar |

Bir asama basarisiz olursa servis hata verir ve **sonraki acilista kaldigi yerden
devam eder**. Durum:

```bash
systemctl status pve-maas-init
journalctl -u pve-maas-init -b
ls -l /var/lib/pve-maas/
```

Yapilandirma `/etc/pve-maas/pve-maas.conf` (varsayilanlar) ve
`/etc/pve-maas/conf.d/*.conf` (cloud-init ile yazilan, ezici degerler) dosyalarindan
okunur. Tum secenekler icin [`overlay/etc/pve-maas/pve-maas.conf`](overlay/etc/pve-maas/pve-maas.conf).

### Proxmox + MAAS birlesiminin tuzaklari

Bu imaj asagidaki uc sorunu bilerek cozer. Kendi turevinizi yazacaksaniz
bunlari bozmayin:

**1. systemd siralama dongusu.** `pve-maas-init.service` icin
`After=cloud-final.service` + `WantedBy=multi-user.target` yazmak bu imajda
donguye yol aciyor ve systemd dongoyu kirmak icin *bizim* servisimizi siliyor:

```
multi-user.target: Found ordering cycle on pve-maas-init.service/start
Job pve-maas-init.service/start deleted to break ordering cycle
```

Servis sessizce hic calismaz. Cozum: unit'te cloud-init siralamasi yok;
script kendi icinde `cloud-init status --wait` ile bekliyor.

**2. `pvenetcommit.service`.** Proxmox ag degisikliklerini once
`/etc/network/interfaces.new` dosyasina yazar; `pvenetcommit` her acilista bu
dosyayi `interfaces` uzerine **tasir**. Build sirasinda olusan bir `.new`
dosyasi imajda kalirsa dugumun ilk acilisinda yapilandirmayi ezer. Hem imajda
hem de ag donusumunden sonra siliniyor.

**3. Arayuz adi uyusmazligi.** MAAS commissioning'i Ubuntu ephemeral ortaminda
yapar ve karti orada gordugu adla kaydeder (or. `enp6s18`). Deploy edilen
Debian 13 / Proxmox ise udev'in farkli isimlendirme semasi yuzunden ayni karta
`ens18` diyebilir. Bu durumda cloud-init acilista yeniden adlandirmayi dener,
`[busy]` hatasi alir ve **arayuzu kapali birakir** - dugum agini tamamen
kaybeder:

```
Failed to rename devices: [busy] Error renaming mac=... from ens18 to enp6s18
```

`curtin-hooks`, MAAS'in ag yapilandirmasindaki MAC -> ad eslemesini
`/etc/systemd/network/10-maas-<ad>.link` olarak yazar; udev karti en bastan
dogru adla olusturur ve yeniden adlandirma gerekmez.

### Ilk acilista ag sahipligi

Imaj `networking.service`'i (ifupdown2) **devre disi** ve `/etc/network/interfaces`
dosyasini yalnizca `lo` icerecek sekilde gonderir. Ilk acilista agi tamamen MAAS
yonetir (curtin'in yazdigi netplan + systemd-networkd). `pve-maas-init` ag asamasi
`vmbr0` yapilandirmasini yazdiktan sonra netplan/networkd'yi devre disi birakip
`networking.service`'i kendisi etkinlestirir.

Bu sirala onemli: ifupdown2 etkin gelirse, imajdan gelen eski arayuz tanimiyla
acilista gercek arayuzu kapatir ve dugum daha otomasyon calismadan agini kaybeder.

### Ag donusumu

`PVE_NET_APPLY=reboot` (varsayilan) ile dugum, cloud-init MAAS'a "deploy tamamlandi"
sinyalini gonderdikten **sonra** bir kez yeniden baslar ve `vmbr0` ile acilir.
Yeniden baslatma istemiyorsaniz `PVE_NET_APPLY=reload` ifupdown2'nin `ifreload -a`
komutunu kullanir.

Bond/VLAN gibi karmasik topolojilerde `PVE_NET_MANAGE=false` yapip
`/etc/network/interfaces` dosyasini cloud-init ile kendiniz yazin —
bkz. [`maas/examples/04-advanced-network.yaml`](maas/examples/04-advanced-network.yaml).

### Depolama

MAAS'in disk duzeni bir LVM VG birakiyorsa (MAAS'ta **LVM storage layout** secip
kok LV'yi kucultun), artan alanda `data` adinda bir thin havuz acilir ve `local-lvm`
olarak tanimlanir. Ayri bir disk kullanmak icin:

```
PVE_THINPOOL_DISK=/dev/sdb
PVE_THINPOOL_VG=pve
```

Bos alan `PVE_THINPOOL_MIN_GB` (varsayilan 16 GiB) altindaysa asama sessizce atlanir;
dugum yalnizca dizin tabanli `local` deposuyla calisir.

---

## Kume otomasyonu

`pvecm add` parolayi etkilesimli sorar, bu yuzden ayni isi yapan API ucu kullanilir:

```
pvesh create /cluster/config/join --hostname <peer> --password <pw> --fingerprint <fp>
```

**Ilk dugum** ([`01-first-node.yaml`](maas/examples/01-first-node.yaml)):

```yaml
PVE_CLUSTER_MODE=create
PVE_CLUSTER_NAME=pve-cluster-01
```

**Katilan dugumler** ([`02-join-node.yaml`](maas/examples/02-join-node.yaml)):

```yaml
PVE_CLUSTER_MODE=join
PVE_CLUSTER_PEER=192.0.2.11
PVE_CLUSTER_PEER_PASSWORD='...'
PVE_CLUSTER_FINGERPRINT='AA:BB:...'   # onerilir
```

Katilan dugum, hedef dugumun 8006 portu acilana kadar bekler
(`PVE_CLUSTER_WAIT`, varsayilan 900 s) ve basarisiz denemeleri tekrarlar
(`PVE_CLUSTER_RETRIES`). Katilim bittikten sonra `conf.d` icindeki parolalar
temizlenir (`PVE_CLUSTER_WIPE_SECRETS=true`).

### Birden fazla bagimsiz kume

Imaj tamamen jeneriktir - kume kimligi **yalnizca** deploy anindaki cloud-init
user-data'sindan gelir. Ayni imaj ve ayni preseed ile istediginiz kadar ayri
kume kurabilirsiniz; **yeniden derleme gerekmez**.

Elle yapmak zahmetli oldugu icin ([`scripts/deploy-cluster.sh`](scripts/deploy-cluster.sh))
tum akisi otomatiklestirir: ilk dugumu `create` ile deploy eder, ayaga kalkmasini
bekler, sertifika parmak izini okur ve kalan dugumleri o parmak iziyle `join`
modunda deploy eder.

**MAAS region controller uzerinde** calistirin (`maas` CLI profili ve dugumlerin
8006 portuna erisim gerekir):

```bash
# Once ne uretecegini gorun - hicbir sey deploy etmez
./deploy-cluster.sh --name pve-prod --nodes pve1,pve2,pve3 --dry-run

# Gercek kurulum
./deploy-cluster.sh --name pve-prod --nodes pve1,pve2,pve3

# Ikinci, tamamen bagimsiz kume - ayni imaj, ayni preseed
./deploy-cluster.sh --name pve-dr --nodes dr1,dr2,dr3
```

Listedeki **ilk dugum kumeyi olusturur**, digerleri ona katilir. Her kume kendi
root parolasini alir (vermezseniz uretilir ve ekrana yazilir).

Ayri bir corosync agi kullaniyorsaniz:

```bash
./deploy-cluster.sh --name pve-prod --nodes pve1,pve2,pve3 --link0-prefix 10.10.20.
```

Her dugumun o onekle baslayan adresi MAAS'tan bulunup `PVE_CLUSTER_LINK0` olarak
yazilir. (Bu yol henuz canli test edilmedi.)

Cok dugumlu kumelerde `--serial` ile katilanlar teker teker deploy edilir.
Varsayilan paralel moddur; es zamanli katilim denemeleri olursa `pve-maas-init`
zaten 5 kez, 30 saniye arayla tekrar dener.

**Kumeleri MAAS'ta ayirmak icin** etiket kullanmak ise yarar:

```bash
maas $PROFILE tag create name=pve-prod
maas $PROFILE tag update-nodes pve-prod add=$SYSTEM_ID
maas $PROFILE machines read tags=pve-prod | jq -r '.[].hostname'
```

### Guvenlik notlari

* Hedef dugumun **root@pam parolasi duz metin olmak zorundadir** — API dogrulamasi
  hash kabul etmez. Bu deger cloud-init user-data icinde MAAS'ta saklanir; MAAS
  user-data'ya erisimi olan herkes gorebilir. Kisa omurlu bir parola kullanip
  kurulumdan sonra degistirmeyi dusunun.
* `PVE_CLUSTER_FINGERPRINT` vermezseniz parmak izi hedef dugumden okunur (TOFU) —
  ilk baglantida MITM'e aciktir. Uretimde parmak izini onceden verin.
* Dugumun kendi `root` parolasi icin `PVE_ROOT_PASSWORD_HASH` kullanin
  (`openssl passwd -6`), duz metin `PVE_ROOT_PASSWORD` yerine.
* `PVE_ROOT_PASSWORD*` hic verilmezse root parolasi kilitli kalir: web arayuzune
  `root@pam` ile girilemez ve bu dugum baska bir dugumun katilim hedefi olamaz.

---

## Dizin yapisi

```
Makefile                         derleme / preseed / yukleme hedefleri
scripts/install-deps.sh          build host bagimliliklari
scripts/customize-proxmox.sh.in  build VM icinde calisan Proxmox kurulum sablonu
scripts/deploy-cluster.sh        MAAS uzerinden komple bir kume kurar (cok kumeli senaryolar)
scripts/verify-image.sh          uretilen imajin icerik dogrulamasi
overlay/                         imaja kopyalanan dosyalar
  usr/local/sbin/pve-maas-init   ilk acilis durum makinesi
  etc/pve-maas/pve-maas.conf     varsayilan yapilandirma (tum secenekler)
  etc/systemd/system/...         pve-maas-init.service
  curtin/curtin-hooks            curtin'in apt ile cekirdek kurmasini engeller
maas/curtin_userdata_custom.in   MAAS curtin preseed sablonu
maas/examples/*.yaml             cloud-init user-data ornekleri
build/                           uretilen dosyalar (git'e girmez)
```

---

### packer-maas uzerindeki degisiklikler

`make image`, `build/packer-maas` altina klonlanan upstream sablonda tek bir yama
yapar: `debian-cloudimg.pkr.hcl` icindeki `disk_size` (4G -> `DISK_SIZE`), `cpus` ve
`memory` degerleri. Upstream 4G ile gelir; Debian cloud image (~3G) uzerine Proxmox VE
kurulumu bu alana sigmaz. Uretilen `.tar.gz` yalnizca kullanilan dosyalari icerdigi
icin buyuk sanal disk son imaji buyutmez.

Yama her `make image` calistiginda `git checkout -f` sonrasi yeniden uygulanir;
upstream'i `PM_REF` ile bir commit SHA'ya sabitleyerek surprizleri onleyebilirsiniz.

---

## Sorun giderme

**Deploy "Failed deployment" ile bitiyor**
Preseed dosyasi dogru adla region controller'da mi? Ad, yuklenen imajin adiyla
birebir eslesmelidir: `curtin_userdata_custom_<arch>_<subarch>_<image-name>`.
`make preseed` ciktisindaki dosya adini kullanin.

**Deploy tamam ama web arayuzune girilemiyor**
`root@pam` parolasi ayarlandi mi? `journalctl -u pve-maas-init -b | grep rootpw`.
Ayrica `vmbr0` ayaga kalkmis mi: `ip -br addr`.

**Dugum kumeye katilmadi**
`journalctl -u pve-maas-init -b` ciktisina bakin. Sik nedenler: hedef dugum 8006'da
erisilemiyor, root parolasi yanlis, parmak izi eslesmiyor, ya da hedef dugumun
`/etc/hosts` kaydi eksik oldugu icin `pvecm` orada hata veriyor.
Servisi elle tekrar calistirmak icin:

```bash
rm -f /var/lib/pve-maas/cluster.done /var/lib/pve-maas/complete
systemctl start pve-maas-init
```

**Deploy "Deployed" diyor ama dugume hic erisilemiyor**
Dugumun konsoluna bakin (Proxmox'ta `qm terminal <vmid>`). Login istemi geliyorsa
sistem acilmis, sorun agda demektir. Kurtarma modunda diski inceleyin:

```bash
maas $PROFILE machine rescue-mode $SYSTEM_ID
# ephemeral ortama SSH ile baglanip:
mount /dev/vgroot/lvroot /mnt/t
cat /mnt/t/etc/network/interfaces          # vmbr0 yazilmis mi?
ls -l /mnt/t/var/lib/pve-maas/             # hangi asamalar tamamlandi?
cat /mnt/t/var/log/cloud-init-output.log   # cloud-init user-data'yi aldi mi?
journalctl -D /mnt/t/var/log/journal -u pve-maas-init
```

`/var/lib/pve-maas/` bosken ag da kapaliysa, `networking.service` ile MAAS'in
netplan yapilandirmasi cakisiyor demektir; imajda bu servis devre disi olmali.

**Dugum adi imajdaki hostname olarak gorunuyor**
Olmamasi gerekir — pmxcfs veritabani imajdan silinir ve ilk acilista guncel
hostname ile yeniden uretilir. Boyle bir durumda `/var/lib/pve-cluster/config.db`
imajda kalmis demektir; `make image` ciktisinda "Proxmox dugum kimligi sifirlaniyor"
adimini kontrol edin.

**Deploy "Installing OS" sonrasi "Configuring OS" asamasinda patliyor**
Kurulum kaydina bakin:

```bash
maas $PROFILE node-script-result download $SYSTEM_ID current-installation \
    filetype=txt filters=/tmp/install.log output=all | tail -60
```

`install_kernel -> AttributeError: 'NoneType' object has no attribute 'get'`
goruyorsaniz preseed'de `kernel: null` kullanilmis demektir. MAAS ile gelen
curtin surumlerinin bir kismi bunu desteklemez. Bu depodaki preseed bunu
kullanmaz; cekirdek kurulumu imajdaki `/curtin/curtin-hooks` ile devre disi
birakilir. Preseed'i elle duzenlediyseniz geri alin.

**Build "proxmox-ve paketi bulunamadi" diyor**
`PVE_SUITE`/`DEBIAN_SERIES` ile `PVE_REPO` uyumsuz. Depoyu dogrulayin:
`curl -s http://download.proxmox.com/debian/pve/dists/<suite>/Release | grep Components`

---

## Kaynaklar

* [canonical/packer-maas](https://github.com/canonical/packer-maas) — temel Packer sablonlari (AGPL-3.0)
* [MAAS: Build custom images](https://canonical.com/maas/docs/how-to-build-custom-images)
* [Proxmox VE: Install on Debian](https://pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_13_Trixie)
* [Proxmox VE: Cluster Manager](https://pve.proxmox.com/wiki/Cluster_Manager)
* [pvecm(1)](https://pve.proxmox.com/pve-docs/pvecm.1.html)
