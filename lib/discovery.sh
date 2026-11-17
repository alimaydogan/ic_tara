#!/usr/bin/env bash
# ===================================================================
# lib/discovery.sh - FAZ 1: Kesif & Envanter
# -------------------------------------------------------------------
# Girdi : -t <CIDR/IP> veya -l <liste>
# Cikti : canli_hostlar.txt (sadece IP)  +  envanter.txt (IP/MAC/vendor/host)
# Mantik: mevcut `nmap -sn -PR -PE -PS.. -PA..` yaklasimi KORUNUR; ustune
#         her canli host icin MAC + vendor + hostname envantere yazilir.
# ===================================================================

# Envanteri olustur: kesif ciktisi + reverse-DNS + NetBIOS kaynaklarindan.
# MAC yalnizca ayni L2 segmentte (ARP) gorunur; router arkasinda '-' yazilir.
build_inventory() {
    local disc_txt="$1" resolve_txt="$2" nbstat_txt="$3"
    declare -A MAC VEN DNS NB

    # --- MAC + vendor: kesif normal ciktisindan ("MAC Address: .. (Vendor)") ---
    local ip mac ven name host
    while IFS=$'\t' read -r ip mac ven; do
        [[ -n "$ip" ]] && { MAC["$ip"]="$mac"; VEN["$ip"]="$ven"; }
    done < <(awk '
        /^Nmap scan report for/ { ip=$NF; gsub(/[()]/,"",ip) }
        /^MAC Address:/ {
            m=$3; v="-"
            if (match($0,/\(.*\)/)) v=substr($0,RSTART+1,RLENGTH-2)
            print ip"\t"m"\t"v
        }' "$disc_txt" 2>/dev/null)

    # --- Hostname (A): reverse DNS  (nmap -sL -R: "for NAME (IP)") ---
    while IFS=$'\t' read -r ip name; do
        [[ -n "$ip" ]] && DNS["$ip"]="$name"
    done < <(awk '/Nmap scan report for/ && /\(/ {
            ip=$NF; gsub(/[()]/,"",ip); print ip"\t"$5 }' "$resolve_txt" 2>/dev/null)

    # --- Hostname (B): NetBIOS (nbstat NSE, 137/udp) ---
    while IFS=$'\t' read -r ip name; do
        [[ -n "$ip" ]] && NB["$ip"]="$name"
    done < <(awk '
        /^Nmap scan report for/ { ip=$NF; gsub(/[()]/,"",ip) }
        /NetBIOS name:/ {
            s=$0; sub(/.*NetBIOS name:[ ]*/,"",s); sub(/,.*/,"",s); gsub(/[ \t]/,"",s)
            if (s!="" && s!="<unknown>") print ip"\t"s
        }' "$nbstat_txt" 2>/dev/null)

    # --- Birlestir: her canli IP icin tek satir ---
    printf 'IP\tMAC\tVENDOR\tHOSTNAME\n' > "$ENVANTER_TSV"
    while read -r ip; do
        [[ -z "$ip" ]] && continue
        mac="${MAC[$ip]:--}";  [[ -z "$mac" ]] && mac="-"
        ven="${VEN[$ip]:--}";  [[ -z "$ven" ]] && ven="-"
        host="${DNS[$ip]:-}"
        [[ -z "$host" ]] && host="${NB[$ip]:-}"
        [[ -z "$host" ]] && host="-"
        printf '%s\t%s\t%s\t%s\n' "$ip" "$mac" "$ven" "$host" >> "$ENVANTER_TSV"
    done < "$LIVE_HOSTS"

    # Insan okunur hizali tablo
    if command -v column >/dev/null 2>&1; then
        column -t -s $'\t' "$ENVANTER_TSV" > "$ENVANTER" 2>/dev/null || cp "$ENVANTER_TSV" "$ENVANTER"
    else
        cp "$ENVANTER_TSV" "$ENVANTER"
    fi
}

# FAZ 1 - Host discovery + envanter
step_discovery() {
    info "FAZ 1: Kesif & Envanter - canli IP'ler araniyor..."
    local out="$OUTDIR/01_host_discovery"
    local tgt; tgt="$(target_args)"

    # --ping verildiyse ek ICMP prob turleri (timestamp/netmask) eklenir.
    local extra_ping=""
    [[ "${PING_SCAN:-0}" -eq 1 ]] && { extra_ping="-PP -PM"; info "  (--ping: ek ICMP timestamp/netmask problari aktif)"; }

    # -sn: port taramasiz host up mi? ARP (ayni L2) + ICMP + TCP SYN/ACK.
    # ic agda ARP cok guvenilir, firewall bunu kolay engelleyemez.
    # shellcheck disable=SC2086
    nmap -sn -PR -PE -PS21,22,23,80,135,139,443,445,3389 -PA80,443 $extra_ping \
        -n --max-retries 2 $tgt -oG "${out}.gnmap" -oN "${out}.txt" >/dev/null 2>&1

    # Canli IP'leri ayikla -> canli_hostlar.txt (FAZ 2 girdisi)
    grep "Up$" "${out}.gnmap" 2>/dev/null | awk '{print $2}' | sort -V -u > "$LIVE_HOSTS"

    local count; count=$(wc -l < "$LIVE_HOSTS" 2>/dev/null || echo 0)
    if [[ "$count" -eq 0 ]]; then
        warn "Canli host bulunamadi. Firewall ICMP/ARP'i engelliyor olabilir."
        warn "Ipucu: subnet'i kontrol et ya da hedefi dogrula."
        log_summary "FAZ 1 - KESIF & ENVANTER (0 canli host)" ""
        return
    fi
    ok "$count canli host bulundu -> $LIVE_HOSTS"

    # --- Envanter zenginlestirme: hostname icin reverse-DNS + NetBIOS ---
    info "  -> Envanter: MAC/vendor (ARP) + hostname (reverse-DNS + NetBIOS)..."
    local resolve="$OUTDIR/.01_resolve.txt"
    local nbstat="$OUTDIR/.01_nbstat.txt"
    # Reverse DNS (tarama yok, sadece PTR cozumleme)
    nmap -sL -R -iL "$LIVE_HOSTS" -oN "$resolve" >/dev/null 2>&1 || : > "$resolve"
    # NetBIOS adi (137/udp) - zaman sinirli, kirilmaz
    nmap -sU -Pn -n -p137 --script nbstat --max-retries 1 --host-timeout 20s \
        -iL "$LIVE_HOSTS" -oN "$nbstat" >/dev/null 2>&1 || : > "$nbstat"

    build_inventory "${out}.txt" "$resolve" "$nbstat"

    ok "Envanter -> $ENVANTER"
    echo -e "${C_DIM}$(sed 's/^/     /' "$ENVANTER")${C_RST}"

    log_summary "FAZ 1 - KESIF & ENVANTER ($count canli host)" "$(cat "$ENVANTER" 2>/dev/null)"
}
