# ictara — SPEC Eki: Bağımlılık Yönetimi (preflight)

> **Claude Code için talimat:** `alimaydogan/ic_tara` deposundaki mevcut çalışan koda
> bağımlılık yönetimi ("preflight") ekle. Mevcut mimariyi, davranışı, SOAP komutunu ve
> exploit-yok kuralını BOZMA. Bu yalnızca bir ekleme: araçların kontrolü + eksikleri
> (onayla) kurma. Aşağıdaki kurallara birebir uy.

---

## 0. Temel İlke

Bağımlılık kontrolü **ADIM ADIM DEĞİL, EN BAŞTA TOPLU** yapılır.
Yani "SMB adımı geldi, netexec var mı?" gibi dağınık kontrol YOK. Bunun yerine:
**tarama/zincir başlamadan önce TÜM gerekli araçlar bir kerede kontrol edilir,
eksikler kullanıcıya topluca sunulur, (onayla) kurulur, sonra akış başlar.**

Bu mantık iki yerde çalışır:
1. **Direkt kullanım** (`./ictara.sh ...`): çalışmadan önce preflight.
2. **Sisteme kurarken** (`./install.sh`): kurulumdan önce preflight.

İkisi de aynı ortak fonksiyonu kullanmalı (örn. `lib/core.sh` içinde `preflight_deps`),
kod tekrarı olmasın.

---

## 1. Bağımlılık Tanımları

Araçları iki sınıfta topla (tercihen `conf/ports.conf` veya `lib/core.sh` başında bir tablo):

### ZORUNLU (yoksa araç çalışamaz)
| Araç | Kontrol | apt paketi |
|------|---------|-----------|
| `nmap` | `command -v nmap` | `nmap` |

### OPSİYONEL (yoksa araç çalışır ama özellik düşer)
| Araç | Kontrol | Kurulum | Yoksa ne düşer |
|------|---------|---------|----------------|
| `netexec` (`nxc`) | `command -v nxc \|\| netexec \|\| crackmapexec \|\| cme` | `pipx install netexec` | SMB/OS için nmap NSE'ye fallback |
| `curl` | `command -v curl` | apt `curl` | VMware SOAP sürüm tespiti (Aşama 2) |
| `wkhtmltopdf` | `command -v wkhtmltopdf` | apt `wkhtmltopdf` | PDF rapor (HTML yine üretilir) |

Not: PDF için `wkhtmltopdf` VEYA `pandoc`'tan biri yeterli — ikisi de yoksa opsiyonel-eksik say.

---

## 2. Paket Yöneticisi Tespiti (taşınabilirlik)

Kör `apt` çağırma. Mevcut paket yöneticisini tespit et ve ona uygun komut üret:

```bash
detect_pkg_mgr() {
    if   command -v apt-get >/dev/null 2>&1; then echo "apt"
    elif command -v dnf     >/dev/null 2>&1; then echo "dnf"
    elif command -v yum     >/dev/null 2>&1; then echo "yum"
    elif command -v pacman  >/dev/null 2>&1; then echo "pacman"
    elif command -v zypper  >/dev/null 2>&1; then echo "zypper"
    else echo ""; fi
}
```

Kurulum komutu eşlemesi (en azından apt + dnf/yum; diğerleri best-effort):
- apt:    `apt-get install -y <paket>`
- dnf:    `dnf install -y <paket>`
- yum:    `yum install -y <paket>`
- pacman: `pacman -S --noconfirm <paket>`
- zypper: `zypper install -y <paket>`

**netexec istisnası:** apt/dnf'de genelde yok. Kurulumu `pipx install netexec`
(pipx yoksa `pip install netexec` veya uyarı). Paket yöneticisinden bağımsız ele al.

Paket yöneticisi tespit edilemezse (`""`): otomatik kurma, kullanıcıya elle kurma
komutunu söyle ve (zorunlu eksikse) dur.

---

## 3. preflight_deps — Ortak Fonksiyon (davranış)

```
preflight_deps <mod>
  mod = "run"      -> direkt kullanım / tarama öncesi
  mod = "install"  -> install.sh kurulum öncesi
```

Adımlar (TOPLU, baştan):
1. **Topla:** Zorunlu + opsiyonel tüm araçları TEK SEFERDE kontrol et.
   Eksik olanları iki listeye ayır: `MISSING_REQUIRED`, `MISSING_OPTIONAL`.
2. **Hiç eksik yoksa:** kısa "tüm bağımlılıklar tamam" bilgisi, devam.
3. **Eksik varsa:** hepsini TOPLUCA göster (adım adım değil). Örn:
   ```
   [!] Eksik bağımlılıklar:
       ZORUNLU : nmap
       OPSIYONEL: netexec (SMB/OS için), wkhtmltopdf (PDF rapor için)
   ```
4. **İnteraktif mi?** Karar: `[[ -t 0 && -t 1 ]]` (terminal var mı) VE mod/otomatik durumu.
   - **İnteraktif (kullanıcı başında):** tek bir onay sor (adım adım değil):
     `"Eksik araçlar kurulsun mu? [E/h]"`.
     - Onay (E/boş): tespit edilen paket yöneticisiyle hepsini kurmayı dene.
       Her kurulum sonucu raporlansın (kuruldu/kurulamadı).
     - Ret (h): kurma. Sonra madde 6'daki zorunlu-kontrolüne geç.
   - **İnteraktif DEĞİL** (`--auto` ama stdin terminal değil / scheduled / pipe):
     **SORMA.** Otomatik kurmaya KALKMA (kullanıcı kararı gerektirir).
     Durumu logla. Madde 6'daki zorunlu-kontrolüne geç.
     - (Kullanıcı kararı: --auto'da da önce TÜM bağımlılıklar kontrol edilsin, eksik
       varsa SORULSUN. Demek ki --auto + terminal varsa SORULUR. Yalnızca gerçekten
       başında kimse yoksa — stdin terminal değilse — sorulmadan devam edilir.)
5. **Kurulum denemesinden sonra** tekrar kontrol et (gerçekten kuruldu mu?).
6. **Zorunlu hâlâ eksikse:** `die` ile dur — net mesaj + elle kurma komutu.
   Opsiyonel hâlâ eksikse: uyar, ama DEVAM ET (araç çalışır, özellik düşer).
7. Sonuç: fonksiyon başarılıysa (zorunlular tamam) 0 döner; akış devam eder.

**ÖNEMLİ:** Bu fonksiyon tarama adımlarının İÇİNDE değil, onlardan ÖNCE bir kez çağrılır.
Modüllerin içindeki mevcut "araç yoksa fallback" mantığı (netexec→nmap NSE, curl yoksa
SOAP atla) KORUNUR — preflight onu değiştirmez, sadece başta bir kez toplu uyarı/kurulum
katmanı ekler. (Çift güvenlik: başta kurulmadıysa bile modül yine graceful davranır.)

---

## 4. Entegrasyon Noktaları

### ictara.sh (direkt kullanım / tarama)
`main()` içinde, `check_deps`'in yerini/üstünü alacak şekilde:
- `parse_args` sonrası, herhangi bir mod (auto/menu/only) BAŞLAMADAN önce:
  `preflight_deps "run"` çağrılır.
- İnteraktiflik tespiti: `--auto` olsa bile stdin bir terminalse (`[[ -t 0 ]]`) sorulur;
  terminal değilse (scheduled/pipe) sorulmadan, zorunlu-eksikse durularak devam.
- Mevcut `check_deps` fonksiyonu `preflight_deps` ile değiştirilebilir ya da onun
  içinden çağrılabilir. Davranış: artık sadece uyarmak değil, (onayla) kurmak da var.

### install.sh (sisteme kurulum)
- Dosyaları kopyalamadan ÖNCE `preflight_deps "install"` çağrılır.
  (install.sh `lib/core.sh`'i source edebilir ya da fonksiyonu ortak bir yerden alabilir.
   En temizi: `source "$SRC/lib/core.sh"` ile preflight_deps'e eriş.)
- install zaten root ve interaktif varsayılır (`sudo ./install.sh`): eksikleri topluca
  sorup (onayla) kurar, sonra dosya kurulumuna geçer.
- Kurulum sırasında zorunlu (nmap) kurulamazsa: uyar ama install'ı tamamla
  (kullanıcı sonra kurabilir) VEYA durdur — tercihen uyar + devam, çünkü araç dosyaları
  kurulsun, nmap'i kullanıcı sonra ekleyebilir. Net bir uyarı bırak.

---

## 5. Kurallar / Sınırlar (MUTLAK)

1. **Sessiz kurulum YOK:** Hiçbir paket kullanıcı onayı olmadan kurulmaz (ne direkt
   kullanımda ne install'da). Tek istisna yok. Onay interaktifse sorulur; interaktif
   değilse kurulmaz.
2. **Adım adım kontrol YOK:** Tüm bağımlılıklar tek seferde, en başta kontrol edilir.
3. **Taşınabilir:** apt dışında en az dnf/yum/pacman desteklensin; paket yöneticisi yoksa
   elle kurma komutu söylenip (zorunluysa) durulsun.
4. **Graceful:** Opsiyonel araç kurulamazsa/istenmezse araç yine çalışır (fallback).
   Modüllerin mevcut fallback mantığı korunur.
5. **netexec = pipx:** apt'tan kurmaya çalışma; pipx/pip yolu kullan, yoksa uyar.
6. **Güvenlik:** Kurulum komutları sabit paket adlarıyla çalışsın; kullanıcı girdisini
   (TARGET vb.) asla kurulum komutuna sokma. Exploit-yok ve yetki uyarısı kuralları aynen kalır.
7. **shellcheck temiz:** Eklenen kod `shellcheck -x -S warning` ile uyarısız olmalı.

---

## 6. Doğrulama (bitince kontrol edilecek)
- [ ] `preflight_deps` tüm araçları TEK seferde kontrol ediyor (adım adım değil).
- [ ] Direkt kullanımda nmap yoksa: sorup (onayla) kuruyor; ret edilirse `die`.
- [ ] Direkt kullanımda netexec/wkhtmltopdf yoksa: sorup isteyene kuruyor; istenmezse devam.
- [ ] `--auto` + terminalde: eksikler başta topluca soruluyor.
- [ ] `--auto` + stdin terminal DEĞİL (pipe/scheduled): sorulmadan, zorunlu-eksikse durarak.
- [ ] install.sh: dosya kopyalamadan önce preflight çalışıyor, eksikleri (onayla) kuruyor.
- [ ] apt yoksa dnf/yum/pacman deneniyor; hiçbiri yoksa elle komut söyleniyor.
- [ ] netexec `pipx install netexec` ile kuruluyor (apt değil).
- [ ] Opsiyonel eksik kalsa bile tarama çalışıyor (fallback bozulmamış).
- [ ] SOAP komutu + exploit-yok + mevcut mimari değişmemiş.
- [ ] `shellcheck -x -S warning *.sh lib/*.sh` temiz.
