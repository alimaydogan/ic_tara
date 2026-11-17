#!/usr/bin/env bash
# ===================================================================
# lib/core.sh - ortak cekirdek: renkler, log, yardimci fonksiyonlar
# -------------------------------------------------------------------
# Bu dosya ictara.sh tarafindan `source` edilir. Tek basina
# calistirilmaz. Tum fonksiyonlar paylasilan global degiskenleri
# (OUTDIR, LIVE_HOSTS, PORT_MAP, SUMMARY, TARGET, ...) kullanir.
# ===================================================================

# ----------------------- Renkler -----------------------
if [[ -t 1 ]]; then
    C_RST='\033[0m'; C_R='\033[1;31m'; C_G='\033[1;32m'
    C_Y='\033[1;33m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_DIM='\033[2m'
else
    C_RST=''; C_R=''; C_G=''; C_Y=''; C_B=''; C_C=''; C_DIM=''
fi

# ----------------------- Temel ciktilar -----------------------
die()  { echo -e "${C_R}[!] $*${C_RST}" >&2; exit 1; }
info() { echo -e "${C_B}[*]${C_RST} $*"; }
ok()   { echo -e "${C_G}[+]${C_RST} $*"; }
warn() { echo -e "${C_Y}[!]${C_RST} $*"; }

# ----------------------- Banner & yardim -----------------------
banner() {
    echo -e "${C_C}"
    cat <<'EOF'
   _      _
  (_)    | |
   _  ___| |_ __ _ _ __ __ _
  | |/ __| __/ _` | '__/ _` |
  | | (__| || (_| | | | (_| |
  |_|\___|\__\__,_|_|  \__,_|   ic-ag recon
EOF
    echo -e "${C_RST}${C_DIM}  sadece YETKILI aglarda / yazili izinle kullanin${C_RST}\n"
}

usage() {
    banner
    cat <<EOF
Kullanim: sudo ${SCRIPT_NAME} [secenekler]

  -t, --target <IP|CIDR>   Hedef subnet veya tek IP (orn: 10.0.0.0/24)
  -l, --list <dosya>       Satir satir hedef iceren dosya
      --auto               Tum fazlari sirayla otomatik calistir (FAZ 1->4)
      --only <modul>       Kesfi BYPASS et, verilen IP'de tek modul calistir
                           moduller: smb shares snmp cleartext db mssql
                                     vmware vuln os ports
  -p, --port <port>        (--only ile) taranacak port; verilmezse modulun
                           varsayilan portu kullanilir
      --ping               Host discovery'de ping kullan (-Pn KAPAT)
      --top-ports <N>      FAZ 2 top-ports sayisi (default 1000)
      --full-ports         FAZ 2'de tum TCP portlari (-p-) - yavas
  -o, --output <dizin>     Cikti dizini (default: ictara_<tarih>)
  -h, --help               Bu yardimi goster

Calisma modlari:
  (A) Otomatik : sudo ${SCRIPT_NAME} -t 10.0.0.0/24 --auto
  (B) Menu     : sudo ${SCRIPT_NAME} -t 10.0.0.0/24
  (C) Dogrudan : sudo ${SCRIPT_NAME} -t 192.168.1.50 --only mssql
                 sudo ${SCRIPT_NAME} -t 192.168.1.50 -p 1433 --only mssql
                 sudo ${SCRIPT_NAME} -t 192.168.1.50 --only vmware

Istihbarat zinciri (FAZ 1 -> FAZ 2 -> FAZ 3 -> FAZ 4):
  FAZ 1  Kesif & Envanter  - canli IP + MAC + vendor + hostname
  FAZ 2  Port Haritasi     - acik portlar (top-1000 + nis portlar)
  FAZ 3  Hedefli Tarama    - her adim sadece ilgili portu acik host'lara gider
  FAZ 4  Birlesik Rapor    - HTML (+PDF) + OZET_RAPOR.txt

Bu arac EXPLOIT CALISTIRMAZ; sadece tespit/surum/zafiyet-kontrolu yapar.
EOF
}

# ----------------------- Ortam kontrolleri -----------------------
need_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Root gerekiyor (OS tespiti, SYN scan vs icin). 'sudo ${SCRIPT_NAME} ...' ile calistir."
    fi
}

# ===================================================================
# BAGIMLILIK YONETIMI (preflight) - TOPLU kontrol + (onayla) kurulum
# -------------------------------------------------------------------
# Ilke: adim adim degil, EN BASTA toplu. Hem './ictara.sh' (tarama oncesi)
# hem './install.sh' (kurulum oncesi) ayni `preflight_deps`'i cagirir.
# Sessiz kurulum YOK: onay yalnizca interaktifse ([[ -t 0 && -t 1 ]]) sorulur.
# ===================================================================

# Zorunlu + opsiyonel arac anahtarlari (tablo).
REQUIRED_DEPS=(nmap)
OPTIONAL_DEPS=(netexec curl pdf)

# Bir bagimlilik sistemde var mi? (0 = var)
dep_present() {
    case "$1" in
        nmap)    command -v nmap >/dev/null 2>&1 ;;
        curl)    command -v curl >/dev/null 2>&1 ;;
        netexec) command -v nxc >/dev/null 2>&1 || command -v netexec >/dev/null 2>&1 \
                 || command -v crackmapexec >/dev/null 2>&1 || command -v cme >/dev/null 2>&1 ;;
        # PDF icin wkhtmltopdf VEYA pandoc yeterli
        pdf)     command -v wkhtmltopdf >/dev/null 2>&1 || command -v pandoc >/dev/null 2>&1 ;;
        *)       return 1 ;;
    esac
}

# Insan okunur aciklama (yoksa ne duser).
dep_desc() {
    case "$1" in
        nmap)    echo "nmap (ZORUNLU - tarama motoru)" ;;
        curl)    echo "curl (VMware SOAP surum tespiti; yoksa Asama 2 atlanir)" ;;
        netexec) echo "netexec (SMB/OS tespiti; yoksa nmap NSE'ye fallback)" ;;
        pdf)     echo "wkhtmltopdf (PDF rapor; yoksa HTML yine uretilir)" ;;
        *)       echo "$1" ;;
    esac
}

# Paket yoneticisi ile kurulacak paket adi (netexec = pipx, pkg bos).
dep_pkg() {
    case "$1" in
        nmap) echo "nmap" ;;
        curl) echo "curl" ;;
        pdf)  echo "wkhtmltopdf" ;;
        *)    echo "" ;;   # netexec vb. -> ozel yol
    esac
}

# Mevcut paket yoneticisini tespit et (tasinabilirlik).
detect_pkg_mgr() {
    if   command -v apt-get >/dev/null 2>&1; then echo "apt"
    elif command -v dnf     >/dev/null 2>&1; then echo "dnf"
    elif command -v yum     >/dev/null 2>&1; then echo "yum"
    elif command -v pacman  >/dev/null 2>&1; then echo "pacman"
    elif command -v zypper  >/dev/null 2>&1; then echo "zypper"
    else echo ""; fi
}

# Elle kurulum komutunu (string) dondur - kurulamadiginda/reddedildiginde gosterilir.
manual_cmd() {
    local key="$1" pm="$2" pkg; pkg="$(dep_pkg "$key")"
    if [[ "$key" == "netexec" ]]; then echo "pipx install netexec"; return; fi
    case "$pm" in
        apt)    echo "sudo apt-get install -y $pkg" ;;
        dnf)    echo "sudo dnf install -y $pkg" ;;
        yum)    echo "sudo yum install -y $pkg" ;;
        pacman) echo "sudo pacman -S $pkg" ;;
        zypper) echo "sudo zypper install -y $pkg" ;;
        *)      echo "$pkg (paket yoneticinizle kurun)" ;;
    esac
}

# Tek bir bagimliligi kur (0 = basari). Kullanici girdisi kurulum komutuna GIRMEZ.
install_dep() {
    local key="$1" pm="$2" pkg; pkg="$(dep_pkg "$key")"

    # netexec -> pipx/pip (paket yoneticisinden bagimsiz)
    if [[ "$key" == "netexec" ]]; then
        if command -v pipx >/dev/null 2>&1; then
            pipx install netexec >/dev/null 2>&1 && return 0
        elif command -v pip3 >/dev/null 2>&1; then
            pip3 install netexec >/dev/null 2>&1 && return 0
        elif command -v pip >/dev/null 2>&1; then
            pip install netexec >/dev/null 2>&1 && return 0
        else
            warn "    netexec icin pipx/pip bulunamadi."
        fi
        return 1
    fi

    [[ -z "$pm" ]] && return 1
    local -a cmd
    case "$pm" in
        apt)    cmd=(apt-get install -y "$pkg") ;;
        dnf)    cmd=(dnf install -y "$pkg") ;;
        yum)    cmd=(yum install -y "$pkg") ;;
        pacman) cmd=(pacman -S --noconfirm "$pkg") ;;
        zypper) cmd=(zypper install -y "$pkg") ;;
        *)      return 1 ;;
    esac
    if "${cmd[@]}" >/dev/null 2>&1; then return 0; fi
    return 1
}

# ---------------------------------------------------------------
# preflight_deps <mod>   mod = "run" (tarama oncesi) | "install"
# TUM araclari TEK seferde kontrol eder; eksikleri topluca gosterir;
# interaktifse tek onayla kurar; zorunlu hala eksikse run'da die eder.
# Basari (zorunlular tamam) -> 0.
# ---------------------------------------------------------------
preflight_deps() {
    local mode="${1:-run}"
    local -a miss_req=() miss_opt=()
    local d

    # 1) TOPLU kontrol
    for d in "${REQUIRED_DEPS[@]}"; do dep_present "$d" || miss_req+=("$d"); done
    for d in "${OPTIONAL_DEPS[@]}"; do dep_present "$d" || miss_opt+=("$d"); done

    if [[ ${#miss_req[@]} -eq 0 && ${#miss_opt[@]} -eq 0 ]]; then
        ok "Bagimlilik kontrolu: tum araclar hazir."
        return 0
    fi

    # 2) Eksikleri TOPLUCA goster
    warn "Eksik bagimliliklar:"
    local x
    if [[ ${#miss_req[@]} -gt 0 ]]; then
        for x in "${miss_req[@]}"; do echo -e "    ${C_R}ZORUNLU  :${C_RST} $(dep_desc "$x")"; done
    fi
    if [[ ${#miss_opt[@]} -gt 0 ]]; then
        for x in "${miss_opt[@]}"; do echo -e "    ${C_Y}OPSIYONEL:${C_RST} $(dep_desc "$x")"; done
    fi

    local pm; pm="$(detect_pkg_mgr)"
    local interactive=0
    [[ -t 0 && -t 1 ]] && interactive=1

    # 3) Onay (tek sefer, adim adim degil)
    local do_install=0
    if [[ $interactive -eq 1 ]]; then
        local ans=""
        read -rp "  Eksik araclar simdi kurulsun mu? [E/h] " ans || ans=""
        case "${ans,,}" in
            ""|e|evet|y|yes) do_install=1 ;;
            *)               do_install=0 ;;
        esac
    else
        info "Interaktif degil (stdin terminal degil) - otomatik kurulum yapilmayacak."
    fi

    # 4) Kurulum denemesi (onaylandiysa)
    if [[ $do_install -eq 1 ]]; then
        [[ -z "$pm" ]] && warn "Paket yoneticisi tespit edilemedi - yalnizca pipx (netexec) denenecek."
        local k
        for k in "${miss_req[@]}" "${miss_opt[@]}"; do
            if [[ "$k" != "netexec" && -z "$pm" ]]; then
                warn "  $k: paket yoneticisi yok -> elle: $(manual_cmd "$k" "$pm")"
                continue
            fi
            info "  Kuruluyor: $k ..."
            if install_dep "$k" "$pm"; then
                ok "    $k kuruldu."
            else
                warn "    $k kurulamadi -> elle: $(manual_cmd "$k" "$pm")"
            fi
        done
    elif [[ $interactive -eq 1 ]]; then
        info "Kurulum atlandi (kullanici reddetti)."
    fi

    # 5) Tekrar kontrol (gercekten kuruldu mu?)
    miss_req=(); miss_opt=()
    for d in "${REQUIRED_DEPS[@]}"; do dep_present "$d" || miss_req+=("$d"); done
    for d in "${OPTIONAL_DEPS[@]}"; do dep_present "$d" || miss_opt+=("$d"); done

    # 6a) Opsiyonel hala eksik -> uyar ama DEVAM (fallback bozulmaz)
    if [[ ${#miss_opt[@]} -gt 0 ]]; then
        for x in "${miss_opt[@]}"; do
            warn "Opsiyonel eksik: $(dep_desc "$x") - ozellik dusecek, akis devam eder."
        done
    fi

    # 6b) Zorunlu hala eksik
    if [[ ${#miss_req[@]} -gt 0 ]]; then
        local cmds=""
        for x in "${miss_req[@]}"; do cmds+="$(manual_cmd "$x" "$pm")  "; done
        if [[ "$mode" == "install" ]]; then
            warn "ZORUNLU eksik: ${miss_req[*]}  ->  ${cmds}"
            warn "  Dosyalar yine de kurulacak; nmap'i sonra kurmalisiniz."
            return 0
        fi
        die "ZORUNLU bagimlilik(lar) eksik: ${miss_req[*]}  ->  ${cmds}"
    fi

    ok "Bagimlilik kontrolu tamam."
    return 0
}

# Geriye donuk uyum: eski check_deps cagrilari preflight'a yonlendirilir.
check_deps() { preflight_deps "run"; }

# netexec (nxc) ya da eski crackmapexec (cme) binary'sini bul.
# Ikisi de yoksa bos doner -> cagiran taraf nmap'e fallback eder.
NXC_BIN=""
detect_nxc() {
    if command -v nxc >/dev/null 2>&1; then
        NXC_BIN="nxc"
    elif command -v netexec >/dev/null 2>&1; then
        NXC_BIN="netexec"
    elif command -v crackmapexec >/dev/null 2>&1; then
        NXC_BIN="crackmapexec"
    elif command -v cme >/dev/null 2>&1; then
        NXC_BIN="cme"
    else
        NXC_BIN=""
    fi
    echo "$NXC_BIN"
}

# ----------------------- Ozet rapor (duz metin) -----------------------
# Ozet raporuna bir blok ekle (mevcut mekanizma korunur).
log_summary() {
    local title="$1"; shift
    {
        echo ""
        echo "==================================================================="
        echo "  $title"
        echo "  $(date '+%Y-%m-%d %H:%M:%S')"
        echo "==================================================================="
    } >> "$SUMMARY"
    [[ -n "$*" ]] && echo "$*" >> "$SUMMARY"
}

# ----------------------- Hedef yardimcilari -----------------------
# nmap -iL icin hedef kaynagini dondur (kesif fazi icin).
target_args() {
    if [[ -n "$TARGET_LIST" ]]; then
        echo "-iL $TARGET_LIST"
    else
        echo "$TARGET"
    fi
}

# Dogrudan mod (--only): verilen IP(ler)i satir satir stdout'a bas.
direct_targets() {
    if [[ -n "$TARGET_LIST" ]]; then
        sed '/^[[:space:]]*$/d' "$TARGET_LIST"
    elif [[ -n "$TARGET" ]]; then
        echo "$TARGET"
    fi
}

# ----------------------- On kosul kontrolleri -----------------------
# Canli host listesi olustu mu? (FAZ 1 calisti mi)
require_live_hosts() {
    if [[ ! -s "$LIVE_HOSTS" ]]; then
        warn "Once FAZ 1 (Kesif & Envanter) calismali - canli host listesi yok."
        return 1
    fi
    return 0
}

# Port haritasi olustu mu? (FAZ 2 calisti mi)
require_port_map() {
    if [[ ! -s "$PORT_MAP" ]]; then
        warn "Once Port Haritasi (FAZ 2) calismali. Menuden '2' secin."
        return 1
    fi
    return 0
}

# ----------------------- Adim atlama (hedefli tarama) -----------------
# Ilgili port acik host yoksa: adimi calistirma, ekrana + rapora yaz.
SKIPPED_STEPS=()
skip_step() {
    local label="$1" service="$2"
    warn "[$label] acik ${service} portu bulunamadi, atlandi."
    log_summary "$label - ATLANDI" "Acik ${service} portu bulunamadi; adim calistirilmadi."
    SKIPPED_STEPS+=("${label} -> acik ${service} portu yok")
}

# Dogrudan/hedefli modda bir modul icin hedef IP dosyasi hazirla.
#   DIRECT=1  -> verilen IP(ler) (port haritasindan bagimsiz)
#   DIRECT=0  -> hosts_with_ports <tetik portlari...> (port haritasindan)
# Donus: 0 = hedef(ler) var (dosya dolu), 1 = bos (adim atlanmali).
prep_targets() {
    local tf="$1"; shift
    local targets
    if [[ "${DIRECT:-0}" -eq 1 ]]; then
        targets="$(direct_targets)"
    else
        targets="$(hosts_with_ports "$@")"
    fi
    printf '%s\n' "$targets" | sed '/^[[:space:]]*$/d' > "$tf"
    [[ -s "$tf" ]]
}

# ----------------------- HTML kacis -----------------------
# stdin'deki metni HTML-guvenli hale getir (rapor icin).
html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}
