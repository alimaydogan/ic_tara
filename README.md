# ictara — İç Ağ Recon / Tarama Aracı

`tara.sh`'in **iç-ağ kardeşi.** Nexpose/Nessus olmadan, yalnızca `nmap` + NSE +
`netexec` ile iç ağda en sık karşılaşılan bulguları **faz tabanlı bir istihbarat
zinciriyle** toplar. Her faz bir sonrakini besler; körlemesine tarama yoktur —
bir adım yalnızca ilgili portu **açık** olan host'lara gider.

> ⚠️ **Yalnızca YETKİLİ ağlarda, yazılı izinle kullanın.** Bu araç hiçbir koşulda
> **exploit çalıştırmaz**; sadece tespit / sürüm / zafiyet-**kontrolü** yapar
> (`--script-args unsafe=0`). Bu kural pazarlık konusu değildir.

---

## İstihbarat Zinciri (FAZ 1 → FAZ 2 → FAZ 3 → FAZ 4)

| Faz | Dosya | Ne yapar | Çıktı |
|-----|-------|----------|-------|
| **FAZ 1** Keşif & Envanter | `lib/discovery.sh` | `nmap -sn` ile canlı host; her host için IP + MAC + vendor + hostname | `canli_hostlar.txt`, `envanter.txt` |
| **FAZ 2** Port Haritası | `lib/portmap.sh` | top-1000 **+ niş portlar** (ESXi 5480, Cassandra 9042, Memcached 11211…) ayrı taranıp birleştirilir | `port_haritasi.txt` (`IP -> 139,445,1433`) |
| **FAZ 3** Hedefli Tarama | `lib/modules.sh` | SMB, Share, SNMP, Clear-text, DB, VMware, Vuln, OS — her biri **yalnızca** ilgili portu açık host'lara | `03..10_*.txt` |
| **FAZ 4** Birleşik Rapor | `lib/report.sh` | Yönetici özeti + kritik bulgular (kırmızı) HTML; varsa PDF | `rapor.html`, `rapor.pdf`, `OZET_RAPOR.txt` |

Çekirdek yardımcı fonksiyon **`hosts_with_port <port>`** port haritasından o portu
açık olan IP'leri döndürür; böylece örneğin 1433 kapalı bir host MSSQL taramasına
**hiç girmez.** Açık port yoksa adım **atlanır** ve rapora *"açık … portu bulunamadı"*
diye yazılır.

---

## Klasör Yapısı

```
ictara/
├── ictara.sh          # ana giris noktasi (launcher) — her yerden calisir
├── lib/
│   ├── core.sh        # renkler, log_summary, info/ok/warn/die, yardimcilar
│   ├── discovery.sh   # FAZ 1: host discovery + envanter
│   ├── portmap.sh     # FAZ 2: port haritasi + hosts_with_port()
│   ├── modules.sh     # FAZ 3: tum tarama adimlari
│   └── report.sh      # FAZ 4: HTML rapor + opsiyonel PDF
├── conf/
│   └── ports.conf     # nis port listesi + port->modul eslemesi
├── install.sh         # /usr/local/bin'e kurar
└── README.md
```

---

## Kurulum

### Kurulumsuz (klasörün içinden)
```bash
sudo ./ictara.sh -t 10.0.0.0/24 --auto
```
`ictara.sh` kendi konumunu bulur ve `lib/` + `conf/`'u oradan yükler.

### Kurulumlu (her yerden `sudo ictara`)
```bash
sudo ./install.sh                 # /usr/local/bin/ictara + /usr/local/share/ictara
sudo ictara -t 10.0.0.0/24 --auto
sudo ./install.sh --uninstall     # kaldirmak icin
```
Kurulumdan sonra `ictara.sh` önce yanındaki `lib/`'e, yoksa
`/usr/local/share/ictara/lib`'e bakar — iki senaryo da sorunsuz çalışır.

---

## Çalışma Modları

### (A) Otomatik — `--auto`
Tüm zinciri müdahalesiz çalıştırır (FAZ 1 → 2 → 3 → 4):
```bash
sudo ictara -t 10.0.0.0/24 --auto
sudo ictara -l hedefler.txt --auto -o musteri_x
```

### (B) Menü tabanlı (interaktif)
Hedef verilir, menü açılır. Bir tarama adımı seçildiğinde port haritası yoksa
*"Önce Port Haritası (FAZ 2) çalışmalı"* uyarısı gelir:
```bash
sudo ictara -t 10.0.0.0/24
```
Menüde `1) Keşif+Envanter`, `2) Port Haritası`, `A) Hepsini otomatik`,
`R) Raporu üret` seçenekleri vardır.

### (C) Doğrudan hedefli — `--only` (keşfi bypass)
Bilinen bir IP'de tek modülü hızlıca çalıştırır (FAZ 1/2 çalışmaz):
```bash
sudo ictara -t 192.168.1.50 --only mssql           # sadece MSSQL, bu IP'de
sudo ictara -t 192.168.1.50 -p 1433 --only mssql   # port da belirtilebilir
sudo ictara -t 192.168.1.50 --only vmware          # VMware tespit + SOAP surum
sudo ictara -t 192.168.1.50 --only smb
```
Modüller: `smb shares snmp cleartext db mssql vmware vuln os ports`.
`-p` verilmezse modülün `conf/ports.conf`'taki varsayılan portu kullanılır.

---

## Seçenekler

```
-t, --target <IP|CIDR>   Hedef subnet veya tek IP
-l, --list <dosya>       Satir satir hedef iceren dosya
    --auto               Tum fazlari sirayla otomatik calistir
    --only <modul>       Kesfi bypass et, verilen IP'de tek modul calistir
-p, --port <port>        (--only ile) taranacak port
    --ping               Host discovery'de ping kullan
    --top-ports <N>      FAZ 2 top-ports sayisi (default 1000)
    --full-ports         FAZ 2'de tum TCP portlari (-p-) — yavas
-o, --output <dizin>     Cikti dizini (default: ictara_<tarih>)
-h, --help               Yardim
```

---

## Port → Modül Eşlemesi (`conf/ports.conf`)

| Modül | Tetikleyen portlar |
|-------|--------------------|
| `step_smb` | 445, 139 |
| `step_shares` | 445 |
| `step_snmp` | 161/udp *(port haritasından bağımsız)* |
| `step_cleartext` | 21, 23, 69, 512, 513, 514, 5900, 5901 |
| `step_db` | 1433, 1521, 3306, 5432, 27017, 27018, 6379, 11211, 9200, 9300, 5984, 9042, 50000, 3050, 8086 |
| `step_vmware` | 443, 902, 903, 5480, 5988, 5989 |
| `step_vuln` | 445, 3389, 139 |

**Niş portlar** (top-1000'de olmayabilir, FAZ 2'ye zorla dahil edilir):
`5480 5988 5989 902 903 9042 11211 9200 9300 5984 50000 3050 8086 8000 8182 9080`

---

## Bağımlılıklar

| Araç | Zorunlu mu | Yoksa ne olur |
|------|-----------|---------------|
| `nmap` | **Evet** | Araç durur (`die`) |
| `netexec`/`nxc` (veya `crackmapexec`) | Hayır | SMB/OS için nmap NSE'ye düşülür |
| `curl` | Hayır | VMware SOAP sürüm tespiti (Aşama 2) atlanır, Aşama 1 çalışır |
| `wkhtmltopdf` **veya** `pandoc` | Hayır | PDF üretilmez; HTML + not bırakılır |

Kurulum (Debian/Kali):
```bash
sudo apt install nmap wkhtmltopdf
pipx install netexec        # onerilir
```

Root gerekir (SYN scan / OS tespiti / UDP): komutları `sudo` ile çalıştırın.

### Bağımlılık preflight (otomatik kontrol + kurulum)

Hem `./ictara.sh` (tarama öncesi) hem `./install.sh` (kurulum öncesi), **en başta
tek seferde** tüm araçları kontrol eder (adım adım değil). Eksik varsa topluca gösterir:

- **Terminalde (interaktif):** *"Eksik araçlar şimdi kurulsun mu? [E/h]"* diye **bir kez**
  sorar. Onaylarsanız, tespit edilen paket yöneticisiyle (apt / dnf / yum / pacman / zypper)
  kurar; `netexec` için `pipx install netexec` kullanılır. Hiçbir paket onaysız kurulmaz.
- **Terminal değilse** (pipe / zamanlanmış görev): **sormaz, kurmaz.** Sadece raporlar.
- `--auto` olsa bile stdin bir terminalse sorulur.
- **Zorunlu (`nmap`) eksik + kurulamadıysa:** `ictara` durur (`die`). `install.sh` ise
  dosyaları yine kurar, uyarı bırakır (nmap'i sonra eklersiniz).
- **Opsiyonel eksik kalırsa:** araç yine çalışır; ilgili özellik (netexec→nmap NSE,
  curl→SOAP atla, PDF→HTML) düşer. Modüllerin içindeki fallback mantığı korunur (çift güvenlik).

Paket yöneticisi tespit edilemezse otomatik kurmaz; elle kurulum komutunu söyler.

---

## Çıktılar (her çalıştırma `ictara_<tarih>/` altında)

```
canli_hostlar.txt     envanter.txt          port_haritasi.txt
01_host_discovery.*   02_ports_*.*          03_os_detect*.txt
04_smb_*.txt          05_shares.txt         06_snmp.txt
07_cleartext.txt      08_databases.*        09_vmware_*.txt
10_vuln_nse.txt       rapor.html  (rapor.pdf)   OZET_RAPOR.txt
```

---

## Güvenlik Notu

Bu araç bir **keşif/doğrulama** aracıdır. ms17-010 gibi zafiyetleri yalnızca
nmap'in *safe* NSE kontrolleriyle **işaretler**, sömürmez. VMware sürümü, host'un
kendi SOAP `RetrieveServiceContent` API'sinden okunur — herhangi bir zafiyet
tetiklenmez. Yalnızca kapsamı yazılı olarak onaylanmış sistemlerde kullanın.
