#!/usr/bin/env bash
#
# ictara.sh - Ic Ag Recon / Tarama Araci  (launcher / ana giris noktasi)
# -------------------------------------------------------------------
# tara.sh'in ic-ag kardesi. Nexpose/Nessus olmadan, nmap + NSE + netexec
# ile ic agda en sik karsilasilan bulgulari FAZ tabanli bir istihbarat
# zinciriyle toplar:
#
#   FAZ 1  Kesif & Envanter  (lib/discovery.sh)  -> canli IP + MAC/vendor/host
#   FAZ 2  Port Haritasi     (lib/portmap.sh)    -> acik portlar + hosts_with_port
#   FAZ 3  Hedefli Tarama    (lib/modules.sh)    -> her adim ilgili porta gider
#   FAZ 4  Birlesik Rapor    (lib/report.sh)     -> HTML (+PDF) + OZET_RAPOR.txt
#
# Calisma modlari:
#   (A) Otomatik : sudo ictara -t 10.0.0.0/24 --auto
#   (B) Menu     : sudo ictara -t 10.0.0.0/24
#   (C) Dogrudan : sudo ictara -t 192.168.1.50 --only mssql   (kesfi bypass)
#
# ONEMLI: Bu arac sadece YETKILI oldugun aglarda (yazili izinle) kullanilir.
#         Hicbir modul EXPLOIT CALISTIRMAZ; sadece tespit/surum/zafiyet-kontrol.
# -------------------------------------------------------------------

set -o pipefail

# ----------------------- Global degiskenler -----------------------
TARGET=""              # subnet veya tek IP (-t)
TARGET_LIST=""         # hedef dosyasi (-l)
AUTO=0                 # otomatik mod (--auto)
PING_SCAN=0            # --ping (bilgi amacli; discovery -sn kullanir)
OUTDIR=""              # cikti dizini (-o)
LIVE_HOSTS=""          # FAZ 1 ciktisi: canli IP listesi
PORT_MAP=""            # FAZ 2 ciktisi: IP -> acik portlar
ENVANTER=""            # FAZ 1: insan okunur envanter tablosu
ENVANTER_TSV=""        # FAZ 1: makine okunur envanter (rapor icin)
SUMMARY=""             # OZET_RAPOR.txt (log_summary)
TOP_PORTS="--top-ports 1000"
DIRECT=0               # --only ile dogrudan hedefli mod
ONLY_MODULE=""         # --only <modul>
ONLY_PORT=""           # -p <port> (dogrudan mod)
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# ----------------------- lib / conf yukleme -----------------------
# Sibling lib/ varsa (kurulumsuz / gelistirme) onu kullan; yoksa kurulu
# paylasim dizininden (install.sh -> /usr/local/share/ictara). Bu sayede
# hem './ictara.sh' hem de her yerden 'sudo ictara' calisir.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${ICTARA_HOME:-}" && -f "$ICTARA_HOME/lib/core.sh" ]]; then
    # Ozel kurulum konumu (opsiyonel override)
    LIB_DIR="$ICTARA_HOME/lib";                 CONF_DIR="$ICTARA_HOME/conf"
elif [[ -f "$SCRIPT_DIR/lib/core.sh" ]]; then
    # Kurulumsuz / gelistirme: scriptin yanindaki lib/
    LIB_DIR="$SCRIPT_DIR/lib";                 CONF_DIR="$SCRIPT_DIR/conf"
elif [[ -f /usr/local/share/ictara/lib/core.sh ]]; then
    # Kurulumlu: install.sh -> /usr/local/share/ictara
    LIB_DIR="/usr/local/share/ictara/lib";     CONF_DIR="/usr/local/share/ictara/conf"
else
    echo "[!] lib/core.sh bulunamadi ('$SCRIPT_DIR/lib' veya '/usr/local/share/ictara/lib')." >&2
    echo "    Depo icinden './ictara.sh' calistirin ya da 'sudo ./install.sh' ile kurun." >&2
    exit 1
fi

# shellcheck source=lib/core.sh
source "$LIB_DIR/core.sh"      || { echo "[!] core.sh yuklenemedi" >&2; exit 1; }
# shellcheck source=conf/ports.conf
source "$CONF_DIR/ports.conf"  || { echo "[!] ports.conf yuklenemedi" >&2; exit 1; }
# shellcheck source=lib/discovery.sh
source "$LIB_DIR/discovery.sh" || die "discovery.sh yuklenemedi"
# shellcheck source=lib/portmap.sh
source "$LIB_DIR/portmap.sh"   || die "portmap.sh yuklenemedi"
# shellcheck source=lib/modules.sh
source "$LIB_DIR/modules.sh"   || die "modules.sh yuklenemedi"
# shellcheck source=lib/report.sh
source "$LIB_DIR/report.sh"    || die "report.sh yuklenemedi"

# ----------------------- AUTO mod (istihbarat zinciri) -----------------------
run_auto() {
    info "OTOMATIK MOD - istihbarat zinciri: FAZ 1 -> FAZ 2 -> FAZ 3 -> FAZ 4\n"
    step_discovery
    if [[ ! -s "$LIVE_HOSTS" ]]; then
        warn "Canli host yok; sonraki fazlar atlaniyor."
        generate_report
        finish
        return
    fi
    step_portmap
    step_os
    step_smb
    step_shares
    step_snmp
    step_cleartext
    step_db
    step_vmware
    step_vuln
    generate_report
    finish
}

# ----------------------- Dogrudan hedefli mod (--only) -----------------------
run_only() {
    DIRECT=1
    local m="${ONLY_MODULE,,}"
    info "DOGRUDAN MOD - modul='${m}'  hedef='${TARGET:-$TARGET_LIST}'${ONLY_PORT:+  port=${ONLY_PORT}}"
    info "  (FAZ 1/2 bypass edildi - verilen IP'ye dogrudan modul calisiyor)\n"
    case "$m" in
        smb)       [[ -z "$ONLY_PORT" ]] && ONLY_PORT="$DEF_smb";       step_smb ;;
        shares)    [[ -z "$ONLY_PORT" ]] && ONLY_PORT="$DEF_shares";    step_shares ;;
        snmp)      [[ -z "$ONLY_PORT" ]] && ONLY_PORT="$DEF_snmp";      step_snmp ;;
        cleartext) [[ -z "$ONLY_PORT" ]] && ONLY_PORT="$DEF_cleartext"; step_cleartext ;;
        db)        [[ -z "$ONLY_PORT" ]] && ONLY_PORT="$DEF_db";        step_db ;;
        mssql)     [[ -z "$ONLY_PORT" ]] && ONLY_PORT="$DEF_mssql";     step_db ;;
        vmware)    step_vmware ;;   # portlar sabit (aday taramasi + SOAP)
        vuln)      step_vuln ;;     # portlar sabit (139/445/3389)
        os)        step_os ;;       # nmap -O / netexec
        ports)     step_portmap ;;  # tek host'ta port haritasi
        *) die "Bilinmeyen modul: '$m'  (gecerli: smb shares snmp cleartext db mssql vmware vuln os ports)" ;;
    esac
    echo ""
    ok "Bitti (dogrudan mod). Ciktilar: ${C_Y}${OUTDIR}/${C_RST}"
    ok "Ozet rapor         : ${C_Y}${SUMMARY}${C_RST}"
}

# ----------------------- Interaktif menu (port haritasina bagli) -------------
menu_scan() { require_port_map   || return; "$1"; }   # port haritasi gerektiren adimlar
menu_live() { require_live_hosts || return; "$1"; }   # sadece canli host gerektiren (os/snmp)

interactive_menu() {
    local choice yn lc pc
    while true; do
        lc=$(wc -l < "$LIVE_HOSTS" 2>/dev/null || echo 0)
        pc=$(wc -l < "$PORT_MAP"   2>/dev/null || echo 0)
        echo ""
        echo -e "${C_C}=============== ICTARA MENU ===============${C_RST}"
        echo -e "  Hedef   : ${C_Y}${TARGET:-$TARGET_LIST}${C_RST}"
        echo -e "  Canli   : ${C_G}${lc}${C_RST} host   Portlu: ${C_G}${pc}${C_RST}   Cikti: ${C_DIM}${OUTDIR}${C_RST}"
        echo -e "${C_C}------------------------------------------${C_RST}"
        echo "  1) FAZ 1: Kesif & Envanter (canli IP + MAC/vendor/host)"
        echo "  2) FAZ 2: Port Haritasi (acik portlar)"
        echo -e "${C_DIM}  --- FAZ 3: hedefli adimlar (port haritasi gerekir) ---${C_RST}"
        echo "  3) OS tespiti"
        echo "  4) SMB / SMBv1 kontrolu"
        echo "  5) SMB share / CIFS (anonim paylasim)"
        echo "  6) SNMP community kontrolu"
        echo "  7) Telnet / clear-text servisler"
        echo "  8) Veritabani portlari + surum"
        echo "  9) VMware / ESXi / vCenter + surum"
        echo " 10) Hizli zafiyet NSE (ms17-010 vs)"
        echo -e "${C_C}------------------------------------------${C_RST}"
        echo "  A) HEPSINI sirayla calistir (FAZ 1->4)"
        echo "  R) FAZ 4: Raporu uret (HTML/PDF) + ozeti goster"
        echo "  Q) Cik"
        echo -e "${C_C}==========================================${C_RST}"
        read -rp "  Secim > " choice
        echo ""
        case "${choice,,}" in
            1)  step_discovery ;;
            2)  step_portmap ;;
            3)  menu_live step_os ;;
            4)  menu_scan step_smb ;;
            5)  menu_scan step_shares ;;
            6)  menu_live step_snmp ;;
            7)  menu_scan step_cleartext ;;
            8)  menu_scan step_db ;;
            9)  menu_scan step_vmware ;;
            10) menu_scan step_vuln ;;
            a)  run_auto ;;
            r)  generate_report
                if [[ -s "$SUMMARY" ]]; then
                    read -rp "  Duz metin ozeti (OZET_RAPOR.txt) goster? [e/H] " yn
                    [[ "${yn,,}" == "e" ]] && less "$SUMMARY"
                fi ;;
            q)  finish; exit 0 ;;
            *)  warn "Gecersiz secim." ;;
        esac
    done
}

# ----------------------- Bitis -----------------------
finish() {
    echo ""
    ok "Bitti. Tum ciktilar: ${C_Y}${OUTDIR}/${C_RST}"
    ok "HTML rapor         : ${C_Y}${OUTDIR}/rapor.html${C_RST}"
    ok "Ozet rapor         : ${C_Y}${SUMMARY}${C_RST}"
    echo -e "${C_DIM}  (her adimin ham nmap ciktisi 0X_*.txt, envanter.txt ve port_haritasi.txt da ayni dizinde)${C_RST}"
}

# ----------------------- Arg parse -----------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--target)    TARGET="$2"; shift 2 ;;
            -l|--list)      TARGET_LIST="$2"; shift 2 ;;
            --auto)         AUTO=1; shift ;;
            --only)         ONLY_MODULE="$2"; shift 2 ;;
            -p|--port)      ONLY_PORT="$2"; shift 2 ;;
            --ping)         PING_SCAN=1; shift ;;
            --top-ports)    TOP_PORTS="--top-ports $2"; shift 2 ;;
            --full-ports)   TOP_PORTS="-p-"; shift ;;
            -o|--output)    OUTDIR="$2"; shift 2 ;;
            -h|--help)      usage; exit 0 ;;
            *)              die "Bilinmeyen secenek: $1  ('--help' ile bak)" ;;
        esac
    done
}

# ----------------------- Main -----------------------
main() {
    parse_args "$@"
    banner
    need_root
    # Bagimlilik preflight: TUM araclar tek seferde kontrol edilir, eksikler
    # (interaktifse) topluca onayla kurulur; zorunlu (nmap) eksik+kurulamazsa durur.
    # --auto olsa bile stdin terminalse sorulur; terminal degilse sorulmadan,
    # zorunlu-eksikse durularak devam (preflight_deps icinde ele alinir).
    preflight_deps "run"

    # Hedef yoksa interaktif olarak sor (dogrudan modda da hedef sart)
    if [[ -z "$TARGET" && -z "$TARGET_LIST" ]]; then
        if [[ -n "$ONLY_MODULE" ]]; then
            die "--only icin hedef gerekir: 'sudo ${SCRIPT_NAME} -t <IP> --only ${ONLY_MODULE}'"
        fi
        read -rp "  Hedef subnet/IP (orn 10.0.0.0/24) > " TARGET
        [[ -z "$TARGET" ]] && die "Hedef girilmedi."
    fi

    # Hedef dosyasi verildiyse var mi kontrol
    if [[ -n "$TARGET_LIST" && ! -s "$TARGET_LIST" ]]; then
        die "Hedef dosyasi bulunamadi veya bos: $TARGET_LIST"
    fi

    # Cikti dizini + sabit dosya yollari
    [[ -z "$OUTDIR" ]] && OUTDIR="ictara_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$OUTDIR" || die "Cikti dizini olusturulamadi: $OUTDIR"
    LIVE_HOSTS="$OUTDIR/canli_hostlar.txt"
    PORT_MAP="$OUTDIR/port_haritasi.txt"
    ENVANTER="$OUTDIR/envanter.txt"
    ENVANTER_TSV="$OUTDIR/.envanter.tsv"
    SUMMARY="$OUTDIR/OZET_RAPOR.txt"
    : > "$LIVE_HOSTS"
    {
        echo "ICTARA - Ic Ag Tarama Ozet Raporu"
        echo "Tarih   : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Hedef   : ${TARGET:-$TARGET_LIST}"
        if [[ -n "$ONLY_MODULE" ]]; then
            echo "Mod     : DOGRUDAN (--only ${ONLY_MODULE})"
        else
            echo "Mod     : $([[ $AUTO -eq 1 ]] && echo OTOMATIK || echo INTERAKTIF)"
        fi
    } > "$SUMMARY"

    ok "Cikti dizini: $OUTDIR"

    # Mod secimi
    if [[ -n "$ONLY_MODULE" ]]; then
        run_only
    elif [[ $AUTO -eq 1 ]]; then
        run_auto
    else
        interactive_menu
    fi
}

main "$@"
