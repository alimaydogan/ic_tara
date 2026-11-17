#!/usr/bin/env bash
# ===================================================================
# lib/modules.sh - FAZ 3: Port'a gore hedefli tarama adimlari
# -------------------------------------------------------------------
# Her adim artik TUM canli host'lara degil, port haritasindan uretilen
# HEDEFLI listeye gider (hosts_with_port/hosts_with_ports). Ilgili port
# acik host yoksa adim ATLANIR ve rapora yazilir.
#
# Dogrudan mod (--only): DIRECT=1 iken port haritasi kullanilmaz; verilen
# IP(ler)e dogrudan modul calisir (bkz. prep_targets / direct_targets).
#
# KURALLAR: Exploit YOK. Sadece tespit/surum/zafiyet-kontrolu. unsafe=0.
# Tetikleyici/varsayilan portlar conf/ports.conf'tan gelir (TRIG_*/DEF_*).
# ===================================================================
# shellcheck disable=SC2154  # TRIG_*/DEF_* degiskenleri conf/ports.conf'tan source edilir

# Port haritasindan bagimsiz adimlar (os/snmp) icin hedef dosyasi hazirla.
# DIRECT=1 -> verilen IP(ler); degilse tum canli host listesi.
livehost_targets() {
    local tf="$1"
    if [[ "${DIRECT:-0}" -eq 1 ]]; then
        direct_targets > "$tf"
    else
        require_live_hosts || { : > "$tf"; return 1; }
        cp "$LIVE_HOSTS" "$tf"
    fi
    [[ -s "$tf" ]]
}

# ------------------------------------------------------------------
# OS tespiti  (port haritasindan bagimsiz: tum canli host'lara uygulanir)
# Birincil: netexec/crackmapexec 'smb' -> SMB konusan host'ta OS+signing+SMBv1.
# Fallback: nmap -O -> SMB cevabi vermeyen host'lar icin.
# ------------------------------------------------------------------
step_os() {
    info "Adim OS: Isletim sistemi tespiti..."
    local out="$OUTDIR/03_os_detect"
    local tf="$OUTDIR/.targets_os.txt"
    if ! livehost_targets "$tf"; then
        skip_step "Adim OS (OS tespiti)" "canli host"
        return
    fi
    local nxc; nxc="$(detect_nxc)"

    if [[ -n "$nxc" ]]; then
        ok "netexec bulundu ($nxc) - SMB host'lari icin birincil kaynak."
        info "  -> $nxc smb (OS / hostname / domain / signing)..."
        "$nxc" smb "$tf" 2>/dev/null | tee "${out}_nxc.txt" \
            | grep -iE "SMB|Windows|signing|SMBv1|domain"
        ok "netexec OS sonucu -> ${out}_nxc.txt"

        # SMB cevabi VERMEYEN host'lari ayikla -> nmap -O (fallback)
        local no_smb="$OUTDIR/03_os_nmap_fallback_targets.txt"
        grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' "${out}_nxc.txt" 2>/dev/null | sort -V -u > "$OUTDIR/.smb_hosts.tmp"
        grep -vxF -f "$OUTDIR/.smb_hosts.tmp" "$tf" 2>/dev/null > "$no_smb"

        if [[ -s "$no_smb" ]]; then
            local nc; nc=$(wc -l < "$no_smb")
            info "  -> SMB konusmayan $nc host var, nmap -O fallback calisiyor..."
            nmap -O -Pn -n --osscan-guess --max-retries 2 \
                -iL "$no_smb" -oN "${out}_nmap.txt" 2>/dev/null \
                | grep -E "Nmap scan report|Running|OS details"
            ok "nmap fallback OS sonucu -> ${out}_nmap.txt"
        else
            info "  -> Tum hedefler SMB cevabi verdi, nmap -O'ya gerek kalmadi."
        fi
        rm -f "$OUTDIR/.smb_hosts.tmp"

        log_summary "ADIM OS - TESPITI (netexec birincil + nmap fallback)" \
            "$(grep -iE 'SMB|Windows|signing' "${out}_nxc.txt" 2>/dev/null)
$(grep -E 'Nmap scan report|OS details|Running:' "${out}_nmap.txt" 2>/dev/null)"
    else
        warn "netexec/crackmapexec bulunamadi - nmap -O ile devam ediliyor."
        warn "  (Oneri: 'pipx install netexec' -> ic agda cok ise yarar.)"
        nmap -O -Pn -n --osscan-guess --max-retries 2 \
            -iL "$tf" -oN "${out}.txt" 2>/dev/null \
            | grep -E "Nmap scan report|Running|OS details|OS CPE|Aggressive OS"
        ok "OS tahminleri -> ${out}.txt"
        log_summary "ADIM OS - TESPITI (nmap -O)" \
            "$(grep -E 'Nmap scan report|OS details|Running:' "${out}.txt" 2>/dev/null)"
    fi
}

# ------------------------------------------------------------------
# SMB / SMBv1  (tetik: 445,139)
# Birincil: netexec smb -> SMBv1, signing, OS, domain tek satirda.
# Ek: nmap NSE (smb-protocols vs) -> nxc yoksa ana kaynak, varsa teyit.
# ------------------------------------------------------------------
step_smb() {
    info "Adim SMB: SMB / SMBv1 kontrolu (445/139)..."
    local out="$OUTDIR/04_smb"
    local tf="$OUTDIR/.targets_smb.txt"
    # shellcheck disable=SC2086  # TRIG_smb: bilincli kelime-bolme (coklu tetik portu)
    if ! prep_targets "$tf" $TRIG_smb; then
        skip_step "Adim SMB" "SMB (445/139)"
        return
    fi
    local scan_ports; scan_ports="$([[ "${DIRECT:-0}" -eq 1 ]] && echo "${ONLY_PORT:-$DEF_smb}" || echo "$DEF_smb")"
    local nxc; nxc="$(detect_nxc)"

    if [[ -n "$nxc" ]]; then
        ok "netexec ($nxc) ile SMB taramasi (signing + SMBv1 tek atista)..."
        "$nxc" smb "$tf" 2>/dev/null | tee "${out}_nxc.txt" \
            | grep -iE "SMB|signing|SMBv1"

        # signing:False -> NTLM relay'e acik (ic agda cok kritik)
        local nosign
        nosign=$(grep -iE "signing:False" "${out}_nxc.txt" 2>/dev/null)
        if [[ -n "$nosign" ]]; then
            warn "SMB signing KAPALI host(lar) (NTLM relay'e acik):"
            echo "$nosign" | sed 's/^/     /'
        fi
        # SMBv1:True -> eski/zafiyetli
        local v1
        v1=$(grep -iE "SMBv1:True" "${out}_nxc.txt" 2>/dev/null)
        if [[ -n "$v1" ]]; then
            warn "SMBv1 ACIK host(lar):"
            echo "$v1" | sed 's/^/     /'
        fi
        ok "netexec SMB sonucu -> ${out}_nxc.txt"
    else
        warn "netexec yok - sadece nmap NSE ile SMB taranacak."
    fi

    info "  -> nmap NSE (smb-protocols / security-mode / os-discovery)..."
    # shellcheck disable=SC2086
    nmap -Pn -n -p "$scan_ports" \
        --script smb-protocols,smb-security-mode,smb2-security-mode,smb2-capabilities,smb-os-discovery \
        -iL "$tf" -oN "${out}_nmap.txt" 2>/dev/null \
        | grep -E "Nmap scan report|SMBv1|2\.0|2\.1|message_signing|disabled|required|computer name|Domain" -i

    local smbv1
    smbv1=$(awk '/Nmap scan report/{ip=$NF} /SMBv1/{print ip" -> SMBv1 ACIK!"}' "${out}_nmap.txt" 2>/dev/null)
    [[ -n "$smbv1" ]] && { warn "nmap da SMBv1 gordu:"; echo "$smbv1" | sed 's/^/     /'; }

    ok "nmap SMB sonucu -> ${out}_nmap.txt"
    log_summary "ADIM SMB - SMB / SMBv1" \
        "$(grep -iE 'SMB|signing|SMBv1' "${out}_nxc.txt" 2>/dev/null)
$(grep -E 'Nmap scan report|SMBv1|message_signing|computer name|Domain name' -i "${out}_nmap.txt" 2>/dev/null)"
}

# ------------------------------------------------------------------
# SMB share / CIFS - anonim erisim  (tetik: 445)
# ------------------------------------------------------------------
step_shares() {
    info "Adim SHARES: SMB share / CIFS - anonim erisilebilir paylasimlar..."
    local out="$OUTDIR/05_shares"
    local tf="$OUTDIR/.targets_shares.txt"
    # shellcheck disable=SC2086  # TRIG_shares: bilincli kelime-bolme (coklu tetik portu)
    if ! prep_targets "$tf" $TRIG_shares; then
        skip_step "Adim SHARES" "SMB (445)"
        return
    fi
    local scan_ports; scan_ports="$([[ "${DIRECT:-0}" -eq 1 ]] && echo "${ONLY_PORT:-$DEF_shares}" || echo "$DEF_shares")"

    # shellcheck disable=SC2086
    nmap -Pn -n -p "$scan_ports" \
        --script smb-enum-shares,smb-enum-users \
        -iL "$tf" -oN "${out}.txt" 2>/dev/null \
        | grep -E "Nmap scan report|\\\\\\\\|Anonymous|READ|WRITE|share|Type:|smb-enum" -i

    ok "Share sonucu -> ${out}.txt"
    warn "READ/WRITE yetkili ya da Anonymous erisilebilir paylasimlara dikkat et."
    log_summary "ADIM SHARES - SMB SHARE / CIFS" \
        "$(grep -E 'Nmap scan report|Anonymous|READ|WRITE|\\\\|Type:' -i "${out}.txt" 2>/dev/null)"
}

# ------------------------------------------------------------------
# SNMP  (161/udp - port haritasindan BAGIMSIZ, UDP ayri taranir)
# ------------------------------------------------------------------
step_snmp() {
    info "Adim SNMP: SNMP (161/udp) - community string kontrolu..."
    local out="$OUTDIR/06_snmp"
    local tf="$OUTDIR/.targets_snmp.txt"
    if ! livehost_targets "$tf"; then
        skip_step "Adim SNMP" "canli host"
        return
    fi
    local snmp_port="161"
    [[ "${DIRECT:-0}" -eq 1 && -n "${ONLY_PORT:-}" ]] && snmp_port="$ONLY_PORT"

    # shellcheck disable=SC2086
    nmap -sU -Pn -n -p "$snmp_port" \
        --script snmp-brute,snmp-info,snmp-sysdescr \
        -iL "$tf" -oN "${out}.txt" 2>/dev/null \
        | grep -E "Nmap scan report|snmp|community|public|private|sysdescr|open" -i

    local comm
    comm=$(grep -iE "valid credentials|community" "${out}.txt" 2>/dev/null)
    if [[ -n "$comm" ]]; then
        warn "SNMP community bulgusu:"
        echo "$comm" | sed 's/^/     /'
    fi

    ok "SNMP sonucu -> ${out}.txt"
    log_summary "ADIM SNMP" \
        "$(grep -E 'Nmap scan report|snmp-brute|community|sysdescr' -i "${out}.txt" 2>/dev/null)"
}

# ------------------------------------------------------------------
# Telnet / clear-text servisler  (tetik: 21,23,69,512,513,514,5900,5901)
# ------------------------------------------------------------------
step_cleartext() {
    info "Adim CLEARTEXT: Telnet / clear-text (telnet, ftp, rlogin, vnc, http-auth)..."
    local out="$OUTDIR/07_cleartext"
    local tf="$OUTDIR/.targets_cleartext.txt"
    # shellcheck disable=SC2086  # TRIG_cleartext: bilincli kelime-bolme (coklu tetik portu)
    if ! prep_targets "$tf" $TRIG_cleartext; then
        skip_step "Adim CLEARTEXT" "clear-text servis (telnet/ftp/rlogin/vnc)"
        return
    fi
    local scan_ports; scan_ports="$([[ "${DIRECT:-0}" -eq 1 ]] && echo "${ONLY_PORT:-$DEF_cleartext}" || echo "$DEF_cleartext")"

    # shellcheck disable=SC2086
    nmap -sS -sV -Pn -n -p "$scan_ports" \
        --script telnet-encryption,ftp-anon,rlogin-brute,vnc-info,http-auth \
        --open -iL "$tf" -oN "${out}.txt" 2>/dev/null \
        | grep -E "Nmap scan report|telnet|ftp|anonymous|rlogin|vnc|open|http-auth|FTP|Anon" -i

    ok "Clear-text sonucu -> ${out}.txt"
    warn "Acik telnet/ftp-anon/rlogin ic agda yuksek riskli - raporda vurgula."
    log_summary "ADIM CLEARTEXT - TELNET / CLEAR-TEXT" \
        "$(grep -E 'Nmap scan report|telnet|ftp-anon|Anonymous|rlogin|vnc|/tcp.*open' -i "${out}.txt" 2>/dev/null)"
}

# ------------------------------------------------------------------
# Veritabani portlari + surum  (tetik: 1433,1521,3306,5432,27017,...)
# Sadece -sV + bilgi-sizdiran NSE; brute/auth DENENMEZ. unsafe=0.
# ------------------------------------------------------------------
step_db() {
    info "Adim DB: Veritabani portlari + surum tespiti..."
    local out="$OUTDIR/08_databases"
    local tf="$OUTDIR/.targets_db.txt"
    # shellcheck disable=SC2086  # TRIG_db: bilincli kelime-bolme (coklu tetik portu)
    if ! prep_targets "$tf" $TRIG_db; then
        skip_step "Adim DB (Veritabani)" "veritabani (1433/3306/5432/...)"
        return
    fi
    local db_ports; db_ports="$([[ "${DIRECT:-0}" -eq 1 ]] && echo "${ONLY_PORT:-$DEF_db}" || echo "$DEF_db")"

    # Bilgi sizdiran (auth'suz) NSE scriptleri - versiyon/config/no-auth tespiti
    local db_scripts="ms-sql-info,ms-sql-ntlm-info,ms-sql-dac,mysql-info,pgsql-brute,oracle-tns-version,oracle-sid-brute,mongodb-info,mongodb-databases,redis-info,memcached-info,couchdb-stats"
    # Not: redis-info & mongodb-info & memcached-info auth YOKSA direkt bilgi verir
    #      (yani DB'nin disariya acik / korumasiz oldugunu kanitlar).

    # shellcheck disable=SC2086
    nmap -sS -sV -Pn -n -p "$db_ports" --open \
        --script "$db_scripts" --script-args unsafe=0 \
        --version-intensity 7 --max-retries 2 \
        -iL "$tf" -oN "${out}.txt" -oG "${out}.gnmap" 2>/dev/null \
        | grep -E "Nmap scan report|open|mssql|mysql|postgres|oracle|mongo|redis|memcached|elastic|couch|cassandra|version" -i

    local found
    found=$(awk '/Nmap scan report/{ip=$NF} /\/tcp.*open/{print ip" "$1" "$3" "$4" "$5" "$6}' "${out}.txt" 2>/dev/null)
    if [[ -n "$found" ]]; then
        warn "Acik veritabani servis(ler)i bulundu:"
        echo "$found" | sed 's/^/     /'
        local noauth
        noauth=$(grep -iE "redis-info|mongodb-info|memcached-info|# Server|uptime_in_seconds|version:" "${out}.txt" 2>/dev/null)
        [[ -n "$noauth" ]] && { echo -e "${C_R}"; warn "AUTH'SUZ erisim sinyali (korumasiz DB!):"; echo "$noauth" | sed 's/^/     /'; echo -e "${C_RST}"; }
    else
        info "Acik veritabani portu gorunmedi."
    fi

    ok "Veritabani sonucu -> ${out}.txt"
    log_summary "ADIM DB - VERITABANI PORTLARI / SURUMLER" \
        "$(grep -E 'Nmap scan report|/tcp.*open|redis-info|mongodb-info|version' -i "${out}.txt" 2>/dev/null)"
}

# ------------------------------------------------------------------
# VMware / ESXi / vCenter tespiti + surum  (tetik: 443,902,903,5480,5988,5989)
# Asama 1: aday tespiti (port + ssl-cert + http-title).
# Asama 2: KULLANICININ SOAP RetrieveServiceContent komutu - BIREBIR korunur.
# ------------------------------------------------------------------
step_vmware() {
    info "Adim VMWARE: VMware / ESXi / vCenter tespiti + surum..."
    local out="$OUTDIR/09_vmware"
    local tf="$OUTDIR/.targets_vmware.txt"
    # shellcheck disable=SC2086  # TRIG_vmware: bilincli kelime-bolme (coklu tetik portu)
    if ! prep_targets "$tf" $TRIG_vmware; then
        skip_step "Adim VMWARE" "VMware (443/902/903/5480/5988/5989)"
        return
    fi
    local cand="$OUTDIR/.vmware_adaylari.txt"
    : > "$cand"

    # curl yoksa Asama 2 (SOAP) calismaz -> uyar ama Asama 1 yine calissin
    local have_curl=1
    command -v curl >/dev/null 2>&1 || { have_curl=0; warn "curl yok - sadece aday tespiti yapilacak, SOAP surum atlanacak."; }

    # --- Asama 1: aday tespiti (port + sertifika + http) ---
    info "  -> Asama 1: VMware adaylari (443/902/903/5480/5988/5989 + ssl-cert + http-title)..."
    nmap -sS -Pn -n -p443,902,903,5480,5988,5989 --open \
        --script ssl-cert,http-title \
        -iL "$tf" -oN "${out}_tarama.txt" -oG "${out}.gnmap" 2>/dev/null \
        | grep -E "Nmap scan report|902/tcp|5480/tcp|598[89]/tcp|VMware|ESXi|Subject:|Issuer:|http-title|vmware-auth" -i

    # Aday kriterleri: her host blogunda sinyal A/B/C/D'den biri tutuyorsa IP yaz
    awk '
        /Nmap scan report/              { if(ip && vm) print ip; ip=$NF; vm=0 }
        /902\/tcp +open/                { vm=1 }                         # A: vmware-auth
        /vmware-auth/                   { vm=1 }                         # A: banner
        /(O|OU)=VMware/                 { vm=1 }                         # B: sertifika issuer/subject
        /VMware Engineering/            { vm=1 }                         # B
        /(http-title|Issuer|Subject|commonName).*(VMware|ESXi)/ { vm=1 } # C: http/cert icerik
        /VMware ESXi Server httpd/      { vm=1 }                         # C: servis banner
        /5480\/tcp +open/               { vm=1 }                         # D: VCSA
        /598[89]\/tcp +open/            { vm=1 }                         # D: CIM
        END { if(ip && vm) print ip }
    ' "${out}_tarama.txt" | sort -V -u > "$cand"

    local cc; cc=$(wc -l < "$cand" 2>/dev/null || echo 0)
    if [[ "$cc" -eq 0 ]]; then
        info "  VMware adayi bulunamadi."
        ok "VMware tarama ciktisi -> ${out}_tarama.txt"
        log_summary "ADIM VMWARE (aday bulunamadi)" ""
        rm -f "$cand"
        return
    fi
    warn "$cc VMware adayi bulundu:"
    sed 's/^/     /' "$cand"

    # --- Asama 2: adaylara SOAP RetrieveServiceContent (kesin surum) ---
    if [[ $have_curl -eq 1 ]]; then
        info "  -> Asama 2: adaylara SOAP RetrieveServiceContent (kesin surum)..."
        : > "${out}_surumler.txt"
        while read -r ip; do
            [[ -z "$ip" ]] && continue
            echo -e "\n[$ip] VMware surum tespiti:" | tee -a "${out}_surumler.txt"

            # Adayin acik HTTPS portunu sec: once 443, yoksa 5480
            # (gnmap'ten o IP'nin acik portlarina bak)
            local sport=""
            if grep -qE "Host: $ip .*443/open" "${out}.gnmap" 2>/dev/null; then
                sport=443
            elif grep -qE "Host: $ip .*5480/open" "${out}.gnmap" 2>/dev/null; then
                sport=5480
            else
                sport=443   # emin olamadiysak varsayilan 443
            fi

            local resp
            resp=$(curl -sk --max-time 10 -X POST "https://$ip:$sport/sdk" \
                -H "Content-Type: text/xml" \
                -d '<?xml version="1.0"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><RetrieveServiceContent xmlns="urn:vim25"><_this type="ServiceInstance">ServiceInstance</_this></RetrieveServiceContent></soap:Body></soap:Envelope>' 2>/dev/null)

            local found=0 fld val
            for fld in fullName version build apiType apiVersion osType productLineId instanceUuid; do
                val=$(echo "$resp" | grep -oP "(?<=<$fld>)[^<]+" | head -1)
                if [[ -n "$val" ]]; then
                    printf "    %-14s: %s\n" "$fld" "$val" | tee -a "${out}_surumler.txt"
                    found=1
                fi
            done
            if [[ $found -eq 0 ]]; then
                warn "    [$ip:$sport] SOAP cevabi alinamadi (SDK kapali / farkli port olabilir)."
                echo "    (SOAP cevabi yok - port $sport)" >> "${out}_surumler.txt"
            fi
        done < "$cand"
        ok "VMware surum sonucu -> ${out}_surumler.txt"
    fi

    ok "VMware tarama ciktisi -> ${out}_tarama.txt"
    log_summary "ADIM VMWARE / ESXi / vCenter ($cc aday)" \
        "ADAYLAR:
$(cat "$cand" 2>/dev/null)

SURUMLER:
$(cat "${out}_surumler.txt" 2>/dev/null)"
    rm -f "$cand"
}

# ------------------------------------------------------------------
# Hizli zafiyet NSE  (tetik: 445,3389,139)
# EXPLOIT DENEMEZ - sadece zafiyet var mi KONTROL eder (safe). unsafe=0.
# ------------------------------------------------------------------
step_vuln() {
    info "Adim VULN: Hizli zafiyet NSE (ms17-010 / smb-vuln* vs)..."
    warn "Bu adim exploit DENEMEZ, sadece zafiyet var mi diye KONTROL eder (safe)."
    local out="$OUTDIR/10_vuln_nse"
    local tf="$OUTDIR/.targets_vuln.txt"
    # shellcheck disable=SC2086  # TRIG_vuln: bilincli kelime-bolme (coklu tetik portu)
    if ! prep_targets "$tf" $TRIG_vuln; then
        skip_step "Adim VULN" "SMB/RDP (139/445/3389)"
        return
    fi

    nmap -Pn -n -p139,445,3389 \
        --script "smb-vuln-ms17-010,smb-vuln-ms08-067,smb-vuln-cve2009-3103,rdp-vuln-ms12-020" \
        --script-args unsafe=0 \
        -iL "$tf" -oN "${out}.txt" 2>/dev/null \
        | grep -E "Nmap scan report|VULNERABLE|ms17-010|ms08-067|CVE|State:|LIKELY" -i

    local vuln
    vuln=$(grep -iE "VULNERABLE|State: VULNERABLE" "${out}.txt" 2>/dev/null)
    if [[ -n "$vuln" ]]; then
        echo -e "${C_R}"
        warn "ZAFIYETLI HOST(LAR) BULUNDU:"
        echo "$vuln" | sed 's/^/     /'
        echo -e "${C_RST}"
    fi

    ok "Zafiyet NSE sonucu -> ${out}.txt"
    log_summary "ADIM VULN - HIZLI ZAFIYET NSE" \
        "$(grep -E 'Nmap scan report|VULNERABLE|ms17-010|State:' -i "${out}.txt" 2>/dev/null)"
}
