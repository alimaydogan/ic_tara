#!/usr/bin/env bash
# ===================================================================
# lib/portmap.sh - FAZ 2: Port Haritasi + hosts_with_port()
# -------------------------------------------------------------------
# Girdi : canli_hostlar.txt
# Cikti : port_haritasi.txt  (IP -> p1,p2,p3)  + ham .gnmap
# Yontem: (b) top-1000 taramasi AYRI, nis portlar AYRI taranir; iki
#         .gnmap birlestirilip tek port haritasi uretilir (daha az kirilgan).
# ===================================================================

# Birlestirilmis .gnmap'ten "IP -> port1,port2,..." haritasi uret.
# Ayni IP birden fazla gnmap satirinda gecebilir -> portlar birlestirilir.
build_port_map() {
    local gnmap="$1"
    [[ -s "$gnmap" ]] || return 0
    awk '
        /^Host:/ {
            ip=$2
            idx=index($0, "Ports:")
            if (idx>0) {
                rest=substr($0, idx+6)
                n=split(rest, parts, ",")
                for (i=1;i<=n;i++) {
                    split(parts[i], f, "/")
                    p=f[1];  gsub(/[ \t]/,"",p)
                    st=f[2]; gsub(/[ \t]/,"",st)
                    if (st=="open" && p ~ /^[0-9]+$/) print ip, p
                }
            }
        }
    ' "$gnmap" 2>/dev/null \
      | sort -u -k1,1V -k2,2n \
      | awk '
          { if ($1!=cur) { if (cur!="") print cur" -> "ports; cur=$1; ports=$2 }
            else           ports=ports","$2 }
          END { if (cur!="") print cur" -> "ports }
        '
}

# --- KRITIK YARDIMCI: belirtilen portu ACIK olan IP'leri dondur ---
# Port haritasi yoksa BOS doner (idempotent, hata firlatmaz).
hosts_with_port() {
    local port="$1"
    [[ -z "$port" ]] && return 0
    [[ -s "$PORT_MAP" ]] || return 0
    awk -F' -> ' -v p="$port" '
        {
            n=split($2, a, ",")
            for (i=1;i<=n;i++) { if (a[i]==p) { print $1; break } }
        }
    ' "$PORT_MAP" 2>/dev/null | sort -V -u
}

# Cok portlu varyant: verilen portlardan EN AZ BIRI acik olan IP'lerin
# birlesik uniq listesi (DB gibi cok-portlu adimlar icin).
hosts_with_ports() {
    local p
    for p in "$@"; do
        hosts_with_port "$p"
    done | sort -V -u
}

# FAZ 2 - Port haritasi uretimi
step_portmap() {
    local out1="$OUTDIR/02_ports_top"
    local out2="$OUTDIR/02_ports_nis"
    local merged="$OUTDIR/02_ports_merged.gnmap"
    local host_src

    # Hedef kaynagi: dogrudan modda verilen IP, normalde canli host listesi.
    if [[ "${DIRECT:-0}" -eq 1 ]]; then
        host_src="$OUTDIR/.targets_portmap.txt"
        direct_targets > "$host_src"
        [[ -s "$host_src" ]] || { warn "Hedef yok."; return; }
        info "Port taramasi (dogrudan hedef): $(tr '\n' ' ' < "$host_src")"
    else
        require_live_hosts || return
        host_src="$LIVE_HOSTS"
        info "FAZ 2: Port Haritasi uretiliyor (top-1000 + nis portlar)..."
    fi

    # (b-1) top-1000 (veya --top-ports N / --full-ports -p-) taramasi
    # shellcheck disable=SC2086
    nmap -sS -sV -Pn -n $TOP_PORTS --open --max-retries 2 \
        -iL "$host_src" -oN "${out1}.txt" -oG "${out1}.gnmap" >/dev/null 2>&1

    # (b-2) nis portlar: top-1000'de olmayabilecek kritik portlar KESIN dahil
    local nis_csv; nis_csv="$(echo "${NIS_PORTLAR:-}" | tr -s ' ' ',' | sed 's/^,//;s/,$//')"
    if [[ -n "$nis_csv" ]]; then
        # shellcheck disable=SC2086
        nmap -sS -sV -Pn -n -p "$nis_csv" --open --max-retries 2 \
            -iL "$host_src" -oN "${out2}.txt" -oG "${out2}.gnmap" >/dev/null 2>&1
    else
        : > "${out2}.gnmap"
    fi

    # Iki gnmap'i birlestir + tek port haritasi uret
    cat "${out1}.gnmap" "${out2}.gnmap" > "$merged" 2>/dev/null
    build_port_map "$merged" > "$PORT_MAP"

    local hc; hc=$(wc -l < "$PORT_MAP" 2>/dev/null || echo 0)
    if [[ "$hc" -eq 0 ]]; then
        warn "Hicbir host'ta acik port gorunmedi (firewall / filtreli olabilir)."
    else
        ok "Port haritasi -> $PORT_MAP ($hc host'ta acik port)"
        echo -e "${C_DIM}$(sed 's/^/     /' "$PORT_MAP")${C_RST}"
    fi
    log_summary "FAZ 2 - PORT HARITASI ($hc host)" "$(cat "$PORT_MAP" 2>/dev/null)"
}
