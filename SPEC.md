# ictara.sh — Refactor Şartnamesi (SPEC)

> **Claude Code için talimat:** Bu dizinde mevcut, çalışan bir `ictara.sh` dosyası var.
> **Sıfırdan yazma.** O dosyayı referans al, içindeki çalışan tarama mantığını ve
> özellikle kullanıcının SOAP/VMware komutunu **birebir koru**, ve aşağıda tarif edilen
> modüler klasör yapısına + "istihbarat zinciri" mimarisine **refactor et.**
>
> Amaç: kodu bölmek, adımları birbirine bağlamak (her adım bir öncekinin çıktısını
> beslesin, körlemesine taramak yok), ve profesyonel bir CLI aracı haline getirmek.

---

## 0. Bağlam (neden refactor ediyoruz)

`ictara.sh` — yetkili iç ağ sızma testlerinde kullanılan, nmap + NSE + netexec tabanlı
bir keşif/tarama aracı. Kullanıcı (profesyonel bir penetration tester) Nexpose'un ücretsiz
lisansı iptal edilince bunu yazdı. `tara.sh` adlı dış-ağ aracının iç-ağ kardeşi.

**Mevcut sorun:** Araç 10 adımdan oluşuyor ama adımlar birbirini beslemiyor. Her adım
`-iL canli_hostlar.txt` ile TÜM canlı host'lara gidiyor — örn. MSSQL taraması 1433 portu
kapalı host'lara bile gidiyor. Adım 2 (port tarama) portları buluyor ama sonraki adımlar
bu bilgiyi kullanmıyor. Büyük ağda bu yavaş ve gereksiz.

**Çözüm:** Faz tabanlı istihbarat zinciri (aşağıda) + modüler kod yapısı.

---

## 1. Hedef Klasör Yapısı

```
ictara/
├── ictara.sh              # ana giris noktasi (launcher) — her yerden calisabilir
├── lib/
│   ├── core.sh            # renkler, log_summary, info/ok/warn/die, yardimci fns
│   ├── discovery.sh       # FAZ 1: host discovery + envanter (IP/MAC/vendor/hostname)
│   ├── portmap.sh         # FAZ 2: port haritasi uretimi + hosts_with_port()
│   ├── modules.sh         # FAZ 3: tum tarama adimlari (SMB, SNMP, DB, VMware, vuln...)
│   └── report.sh          # FAZ 4: HTML rapor + opsiyonel PDF
├── conf/
│   └── ports.conf         # nis port listesi + port->modul eslemesi
├── install.sh             # /usr/local/bin'e kurar (tara.sh gibi global calisma)
└── README.md              # kullanim + kurulum
```

### Terminalden çalışma gereksinimi (KRİTİK)
Araç `tara.sh` gibi terminalden tek komutla çalışmalı. İki senaryo da desteklenmeli:

1. **Kurulumsuz:** `sudo ./ictara.sh -t 10.0.0.0/24 --auto` — klasörün içinden.
   - `ictara.sh` kendi konumunu `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`
     ile bulmalı ve `lib/*.sh` + `conf/ports.conf`'u oradan `source` etmeli.
2. **Kurulumlu:** `install.sh` çalıştırıldıktan sonra her yerden `sudo ictara ...`.
   - `install.sh`: ana scripti `/usr/local/bin/ictara`'ya, `lib/` ve `conf/`'u
     `/usr/local/share/ictara/`'ya kopyalar.
   - `ictara.sh` önce `/usr/local/share/ictara/lib` var mı bakmalı, varsa oradan yükler;
     yoksa `SCRIPT_DIR/lib`'den (kurulumsuz mod). Bu mantık sağlam kurgulanmalı.

### Opsiyonel: standalone build
`build.sh` (opsiyonel, istersen ekle): `lib/*.sh` dosyalarını sırayla birleştirip tek
`ictara-standalone.sh` üretir (USB'ye atıp taşımak için). Zorunlu değil, nice-to-have.

---

## 2. Mimari: İstihbarat Zinciri (Faz Tabanlı)

Veri akışı: **FAZ 1 → FAZ 2 → FAZ 3 → FAZ 4.** Her faz bir sonrakini besler.

### FAZ 1 — Keşif & Envanter  (`discovery.sh`)
- Girdi: IP bloğu/CIDR (`-t`) veya hedef listesi (`-l`).
- `nmap -sn` ile host discovery (mevcut koddaki `-PR -PE -PS... -PA...` yaklaşımı korunacak).
- **YENİ:** Her canlı host için topla ve envantere yaz: **IP + MAC + vendor + hostname**
  - MAC + vendor: `nmap -sn` çıktısındaki `MAC Address: XX:XX:... (Vendor)` satırından parse et.
    - **NOT:** MAC sadece aynı L2 segmentte görünür (ARP). Router arkasındaki host'ta MAC
      gelmez — o durumda MAC/vendor alanına `-` yaz, hata verme, devam et.
  - hostname: ters DNS (`nmap -R` veya discovery sırasında) + NetBIOS (`nbstat` NSE, port 137).
    Hangisi dolu gelirse onu yaz; ikisi de boşsa `-`.
- **Çıktı dosyaları:**
  - `envanter.txt` — insan okuması için, hizalı tablo:
    ```
    IP              MAC                  VENDOR            HOSTNAME
    192.168.1.10    00:0C:29:AB:CD:EF    VMware            DC01
    192.168.1.20    -                    -                 -
    ```
  - `canli_hostlar.txt` — sadece IP listesi (FAZ 2 için).
- Canlı host yoksa: uyar, dur (mevcut davranış korunur).

### FAZ 2 — Port Haritası  (`portmap.sh`)
- Girdi: `canli_hostlar.txt`.
- Tek kapsamlı tarama: `nmap -sS -sV -Pn -n --open` ile.
- **Port kapsamı (KULLANICI KARARI):** `--top-ports 1000` **+ zorla dahil edilen niş portlar.**
  - nmap `--top-ports` ve `-p` birlikte verilemez. Çözüm (tercih sırasıyla):
    - (a) `conf/ports.conf`'taki niş portları, nmap'in top-1000 portlarıyla birleştirip
      tek `-p <birlesik_liste>` ver. top-1000 port listesi
      `nmap --top-ports 1000 -sL -oG -` benzeri bir yöntemle veya statik bir listeden alınabilir;
      pratik yol: top-1000'i ayrı, niş portları ayrı tara ve sonuçları birleştir.
    - (b) Daha basit ve güvenilir: `nmap --top-ports 1000` taramasını yap, AYRICA
      `nmap -p <nis_portlar>` taramasını yap, iki `.gnmap` çıktısını birleştirip tek
      port haritası üret. **Bu (b) yöntemi tercih edilsin — daha az kırılgan.**
  - Amaç: ESXi 5480/5988/5989, Cassandra 9042, Memcached 11211 gibi top-1000'de
    olmayabilecek portlar **kesinlikle** haritada olsun.
- **Çıktı: Port Haritası** — hem makine-okunur hem insan-okunur:
  - `port_haritasi.txt` (insan):
    ```
    192.168.1.10 -> 139,445,1433,3389
    192.168.1.20 -> 22,80,443
    ```
  - Ayrıca ham `.gnmap` korunur (fonksiyonlar oradan da okuyabilir).
- **Kritik yardımcı fonksiyon:**
  ```bash
  # Belirtilen portu ACIK olan IP'leri (port haritasindan) stdout'a dondur
  hosts_with_port() {
      local port="$1"
      # port_haritasi.txt veya 02 gnmap'ten o portu acik olan IP'leri cikar
      # sort -V -u ile uniq don
  }
  ```
  Birden fazla port için: `hosts_with_ports 1433 3306 5432` → birleşik uniq liste döndüren
  bir varyant da olsun (DB adımı gibi çok-portlu adımlar için).

### FAZ 3 — Port'a Göre Hedefli Tarama  (`modules.sh`)
Her adım artık `LIVE_HOSTS` yerine **`hosts_with_port` ile üretilen hedefli listeye** gider.

**Port → Modül eşleme tablosu** (`conf/ports.conf`'ta tanımlı olmalı, modüller buradan okur):

| Modül (fonksiyon)   | Tetikleyen portlar                                  |
|---------------------|-----------------------------------------------------|
| step_smb            | 445, 139                                            |
| step_shares         | 445                                                 |
| step_snmp           | 161 (udp — not: FAZ 2 TCP; SNMP için ayrı `-sU -p161` taraması gerekir, bunu adım kendi içinde yapsın VEYA FAZ 2'ye küçük bir UDP top-ports eklensin. Basitlik için: step_snmp canlı host listesine `-sU -p161` atmaya devam etsin, port haritasına bağımlı olmasın — UDP'yi TCP haritasından bilemeyiz.) |
| step_cleartext      | 21, 23, 69, 512, 513, 514, 5900, 5901               |
| step_db             | 1433,1521,3306,5432,27017,27018,6379,11211,9200,9300,5984,9042,50000,3050,8086 |
| step_vmware         | 443, 902, 903, 5480, 5988, 5989                     |
| step_vuln           | 445, 3389, 139                                       |

**Her adımın davranışı:**
1. İlgili port(lar) için `hosts_with_port` ile hedef IP listesi üret.
2. **Liste boşsa (KULLANICI KARARI):** adımı ÇALIŞTIRMA, ekrana + rapora
   **"[Adım X] açık <servis> portu bulunamadı, atlandı"** yaz. ("atla + rapora yaz" kararı.)
3. Liste doluysa: taramayı sadece o IP'lere yap, çıktıyı dosyaya + özete yaz.

**Mevcut koddan KORUNACAK adımlar (mantık aynen taşınacak, sadece hedef listesi değişecek):**
- step_smb: netexec birincil + nmap NSE (smb-protocols, security-mode, os-discovery).
  signing:False ve SMBv1:True vurgusu korunacak.
- step_shares: smb-enum-shares, smb-enum-users.
- step_snmp: snmp-brute, snmp-info, snmp-sysdescr (UDP — port haritasından bağımsız, yukarıdaki nota bak).
- step_cleartext: telnet-encryption, ftp-anon, rlogin-brute, vnc-info, http-auth.
- step_db: mevcut DB portları + NSE scriptleri + "auth'suz erişim sinyali" (redis-info vb.) vurgusu.
- step_vmware: **2 aşamalı yapı AYNEN korunacak.**
  - Aşama 1: aday tespiti (902/vmware-auth, ssl-cert O=VMware/OU=VMware Engineering, http-title, 5480/5988/5989).
  - Aşama 2: **kullanıcının SOAP `RetrieveServiceContent` curl komutu — BİREBİR korunacak**
    (fullName/version/build/apiType/apiVersion/osType/productLineId/instanceUuid parse eder).
    SOAP portu: adayın açık HTTPS portu (önce 443, yoksa 5480). curl yoksa Aşama 2 atlanır,
    uyarı basılır, Aşama 1 yine çalışır.
- step_os: netexec smb birincil + SMB'siz host'lara nmap -O fallback.
  (Not: step_os FAZ 2'den sonra çalıştığı için, SMB'li host'ları port haritasından da
  teyit edebilir; ama mevcut netexec-tabanlı mantık yeterli, korunabilir.)
- step_vuln: smb-vuln-ms17-010, ms08-067, cve2009-3103, rdp-vuln-ms12-020. `--script-args unsafe=0`.
  **Exploit ÇALIŞTIRMAZ, sadece kontrol eder — bu kural mutlak, değiştirilmeyecek.**

### FAZ 4 — Birleşik Rapor  (`report.sh`)
- Tüm adım çıktılarını + envanter + port haritasını topla.
- **HTML rapor üret** (`rapor.html`): şık, bölümlü (her faz/adım bir bölüm), kritik bulgular
  (SMBv1 açık, signing kapalı, parolasız DB, VULNERABLE host, VMware sürümleri) **kırmızı/vurgulu**.
  Başta bir "Yönetici Özeti" tablosu: kaç host, kaç kritik bulgu, hangi kategoriler.
- **PDF (KULLANICI KARARI — taşınabilirlik önemli):**
  - Makinede `wkhtmltopdf` varsa → `rapor.html`'den `rapor.pdf` üret.
  - Yoksa `pandoc` varsa → onunla dene.
  - Hiçbiri yoksa → HTML bırak + ekrana "PDF için `apt install wkhtmltopdf`" notu. **Hata verme.**
- `OZET_RAPOR.txt` (düz metin) de korunacak — mevcut `log_summary` mekanizması kalsın.

---

## 3. Çalışma Modları

### (A) Otomatik mod — `--auto`
`sudo ictara -t 10.0.0.0/24 --auto`
Sırayla: FAZ 1 → FAZ 2 → FAZ 3 (tüm adımlar, her biri port haritasından hedefli) → FAZ 4.
Kullanıcı müdahalesi yok. Her adım port yoksa atlanır + raporlanır.

### (B) Menü tabanlı manuel mod — (hedef verilir, menü açılır)
`sudo ictara -t 10.0.0.0/24`
Mevcut interaktif menü korunur AMA port haritasına bağımlı hale gelir:
- Menüde FAZ 1 ve FAZ 2'yi çalıştıran seçenekler olmalı (örn. "1) Keşif+Envanter", "2) Port Haritası").
- Bir tarama adımı (SMB, DB vs.) seçildiğinde, port haritası yoksa kullanıcıyı uyar:
  "Önce Port Haritası (FAZ 2) çalışmalı." — tıpkı mevcut `require_live_hosts` gibi
  bir `require_port_map` kontrolü ekle.
- Menüde ayrıca "A) Hepsini otomatik çalıştır" ve "R) Raporu göster/üret" olmalı.

### (C) Doğrudan hedefli mod — YENİ (KULLANICI İSTEĞİ — önemli)
Keşif fazını tamamen bypass edip, bilinen bir IP'de tek modülü çalıştırma.
`tara.sh`'teki `sudo tara <IP>` mantığının iç-ağ versiyonu.

Örnek kullanım:
```
sudo ictara -t 192.168.1.50 --only mssql          # sadece MSSQL modulu, bu IP'de
sudo ictara -t 192.168.1.50 -p 1433 --only mssql  # port da belirtilebilir
sudo ictara -t 192.168.1.50 --only vmware         # sadece VMware tespit+surum
sudo ictara -t 192.168.1.50 --only smb
```
- `--only <modul>` verildiğinde: FAZ 1/2 çalışmaz. Verilen IP(ler)e doğrudan o modül çalışır.
- `<modul>` değerleri: smb, shares, snmp, cleartext, mssql/db, vmware, vuln, os, ports.
  (modülleri `conf`'tan veya bir case tablosundan eşle.)
- `-p <port>` opsiyonel; verilmezse modülün varsayılan portu kullanılır.
- Bu mod, kullanıcının "burada SQL olduğunu biliyorum, direkt çalıştır" senaryosu. Hızlı olmalı.

---

## 4. conf/ports.conf (içerik rehberi)
Shell'den `source` edilebilir ya da parse edilebilir basit formatta olmalı. İçermeli:
- `NIS_PORTLAR="5480 5988 5989 902 903 9042 11211 9200 9300 5984 50000 3050 8086 8000 8182 9080"`
  (FAZ 2'ye zorla dahil edilecek, top-1000'de olmayabilecek portlar)
- Port→modül eşleme tablosu (modüller hangi portları tetikler).
- Modül→varsayılan port (doğrudan hedefli mod `-p` vermezse kullanılacak).

---

## 5. Sağlamlık & Güvenlik Kuralları (MUTLAK)

1. **Yetki uyarısı:** Banner'da ve README'de "sadece yetkili ağlarda / yazılı izinle kullanın"
   uyarısı korunacak. (Mevcut banner'da var.)
2. **Exploit yok:** Hiçbir modül exploit çalıştırmaz. Sadece tespit/versiyon/zafiyet-kontrolü.
   `--script-args unsafe=0` korunacak. Bu kural pazarlık konusu değil.
3. **Graceful degradation:** Bir araç (netexec, curl, wkhtmltopdf) yoksa → o özellik atlanır,
   uyarı basılır, script KIRILMAZ. nmap zorunlu (yoksa die).
4. **Root kontrolü:** SYN scan / OS tespiti root ister — mevcut `need_root` korunacak.
5. **Tek hedef, tek iş:** SOAP/curl timeout'ları (`--max-time 10`) korunacak, host'ta takılma olmasın.
6. **Çıktı dizini:** Her çalıştırma `ictara_<tarih>/` altına (veya `-o` ile verilen dizine).
   Tüm faz çıktıları, envanter, port haritası, ham nmap, HTML/PDF rapor orada toplanır.
7. **Idempotent fonksiyonlar:** `hosts_with_port` gibi fonksiyonlar dosya yoksa boş dönsün,
   hata fırlatmasın.

---

## 6. Teslim Beklentisi (Claude Code'dan)

- Yukarıdaki klasör yapısı, çalışan kod (mevcut `ictara.sh`'ten taşınmış + zincir mimarisiyle).
- `bash -n` ile tüm `.sh` dosyaları sözdizimi temiz olmalı.
- `shellcheck` uyarıları mümkün olduğunca temizlenmeli (kritik olanlar).
- README.md: kurulum (`install.sh`), 3 çalışma modu, örnek komutlar, bağımlılıklar.
- Mevcut `ictara.sh` silinmesin; `ictara.sh.bak` olarak yedeklensin veya git history'de kalsın.
- **Fonksiyonel davranış korunacak:** refactor sonrası araç, eski adımların yaptığı her şeyi
  yapmalı — sadece daha verimli (hedefli) ve daha düzenli (modüler) + yeni rapor/doğrudan-mod.

---

## 7. Denetim Noktaları (kullanıcı + ben kontrol edeceğiz)
Claude Code bitirince şunları doğrulayacağız:
- [ ] `hosts_with_port` doğru çalışıyor mu? (1433 kapalı host DB taramasına girmiyor mu?)
- [ ] Niş portlar (5480, 9042, 11211) port haritasında görünüyor mu?
- [ ] VMware SOAP komutu birebir korunmuş mu?
- [ ] Doğrudan mod (`--only mssql`) keşfi bypass edip çalışıyor mu?
- [ ] Boş adımlar "port bulunamadı" diye raporlanıyor mu?
- [ ] HTML rapor üretiliyor, PDF yoksa graceful mi?
- [ ] `install.sh` sonrası `sudo ictara` her yerden çalışıyor mu?
- [ ] Exploit çalıştıran hiçbir kod eklenmemiş mi?
