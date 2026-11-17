#!/usr/bin/env bash
# ===================================================================
# lib/report.sh - FAZ 4: Birlesik rapor (HTML + opsiyonel PDF)
# -------------------------------------------------------------------
# Tum faz ciktilarini + envanter + port haritasini toplar, sik bir
# HTML rapor (rapor.html) uretir; kritik bulgular kirmizi vurgulu.
# wkhtmltopdf veya pandoc varsa PDF de uretir; yoksa HTML birakir (hata yok).
# OZET_RAPOR.txt (log_summary) mekanizmasi ayrica korunur.
# ===================================================================

# Bir desenin birden fazla dosyadaki toplam satir sayisini dondur.
count_in() {
    local pat="$1"; shift
    local f total=0 c
    for f in "$@"; do
        [[ -s "$f" ]] || continue
        # grep -c her zaman bir sayi basar (eslesme yoksa 0) ve eslesme yoksa
        # exit!=0 doner; cikti ataması bu exit kodunu yutar.
        c=$(grep -ciE "$pat" "$f" 2>/dev/null)
        [[ "$c" =~ ^[0-9]+$ ]] || c=0
        total=$((total + c))
    done
    echo "$total"
}

# Bir dosyayi HTML bolumu olarak bas (opsiyonel kritik-satir vurgusu).
section_file() {
    local title="$1" file="$2" hl="$3"
    echo "<h2>$(printf '%s' "$title" | html_escape)</h2>"
    if [[ -s "$file" ]]; then
        echo '<pre>'
        if [[ -n "$hl" ]]; then
            html_escape < "$file" | sed -E "s@^.*(${hl}).*\$@<span class=\"crit\">&</span>@I"
        else
            html_escape < "$file"
        fi
        echo '</pre>'
    else
        echo '<p class="skip">Bu adim calismadi veya acik port bulunamadi (atlandi).</p>'
    fi
}

# Envanteri HTML tablosu olarak bas (.envanter.tsv'den).
inventory_table() {
    if [[ ! -s "$ENVANTER_TSV" ]]; then
        echo '<p class="skip">Envanter yok (FAZ 1 calismadi).</p>'; return
    fi
    echo '<table><thead><tr><th>IP</th><th>MAC</th><th>VENDOR</th><th>HOSTNAME</th></tr></thead><tbody>'
    local ip mac ven host
    tail -n +2 "$ENVANTER_TSV" | while IFS=$'\t' read -r ip mac ven host; do
        printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
            "$(printf '%s' "$ip"   | html_escape)" \
            "$(printf '%s' "$mac"  | html_escape)" \
            "$(printf '%s' "$ven"  | html_escape)" \
            "$(printf '%s' "$host" | html_escape)"
    done
    echo '</tbody></table>'
}

# Port haritasini HTML tablosu olarak bas.
portmap_table() {
    if [[ ! -s "$PORT_MAP" ]]; then
        echo '<p class="skip">Port haritasi yok (FAZ 2 calismadi).</p>'; return
    fi
    echo '<table><thead><tr><th>IP</th><th>Acik Portlar</th></tr></thead><tbody>'
    local line ip ports
    while IFS= read -r line; do
        ip="${line%% -> *}"; ports="${line#* -> }"
        printf '<tr><td>%s</td><td>%s</td></tr>\n' \
            "$(printf '%s' "$ip"    | html_escape)" \
            "$(printf '%s' "$ports" | html_escape)"
    done < "$PORT_MAP"
    echo '</tbody></table>'
}

# Atlanan adimlar kutusu
skipped_box() {
    [[ ${#SKIPPED_STEPS[@]} -eq 0 ]] && return
    echo '<div class="skipbox"><strong>Atlanan adimlar (acik port yok):</strong><ul>'
    local s
    for s in "${SKIPPED_STEPS[@]}"; do
        echo "<li>$(printf '%s' "$s" | html_escape)</li>"
    done
    echo '</ul></div>'
}

# PDF uret (graceful): once wkhtmltopdf, sonra pandoc, yoksa HTML birak.
make_pdf() {
    local html="$1" pdf="$OUTDIR/rapor.pdf"
    if command -v wkhtmltopdf >/dev/null 2>&1; then
        if wkhtmltopdf -q "$html" "$pdf" >/dev/null 2>&1 && [[ -s "$pdf" ]]; then
            ok "PDF rapor -> $pdf (wkhtmltopdf)"; return
        fi
        warn "wkhtmltopdf PDF uretemedi - HTML raporu kullanin."
    fi
    if command -v pandoc >/dev/null 2>&1; then
        if pandoc "$html" -o "$pdf" >/dev/null 2>&1 && [[ -s "$pdf" ]]; then
            ok "PDF rapor -> $pdf (pandoc)"; return
        fi
        warn "pandoc ile PDF uretilemedi (PDF motoru eksik olabilir) - HTML yeterli."
    fi
    warn "PDF uretilemedi; HTML rapor hazir. PDF icin: apt install wkhtmltopdf"
}

# FAZ 4 - HTML raporu uret
generate_report() {
    info "FAZ 4: Birlesik rapor uretiliyor..."
    local html="$OUTDIR/rapor.html"
    local now; now=$(date '+%Y-%m-%d %H:%M:%S')
    local target_disp="${TARGET:-$TARGET_LIST}"

    # --- Sayilar / kritik bulgular ---
    local hostcount portcount smbv1 nosign vulns authdb vmware critsum
    hostcount=$(wc -l < "$LIVE_HOSTS" 2>/dev/null | tr -d ' '); [[ -z "$hostcount" ]] && hostcount=0
    portcount=$(wc -l < "$PORT_MAP"   2>/dev/null | tr -d ' '); [[ -z "$portcount" ]] && portcount=0
    smbv1=$(count_in 'SMBv1:True|SMBv1 ACIK'                 "$OUTDIR"/04_smb_nxc.txt "$OUTDIR"/04_smb_nmap.txt)
    nosign=$(count_in 'signing:False'                        "$OUTDIR"/04_smb_nxc.txt)
    vulns=$(count_in 'VULNERABLE'                            "$OUTDIR"/10_vuln_nse.txt)
    authdb=$(count_in 'uptime_in_seconds|redis-info|mongodb-info|memcached-info' "$OUTDIR"/08_databases.txt)
    vmware=$(count_in '^\[' "$OUTDIR"/09_vmware_surumler.txt)
    critsum=$((smbv1 + nosign + vulns + authdb))

    # --- HTML yaz ---
    {
    cat <<'HEAD'
<!DOCTYPE html>
<html lang="tr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ictara - Ic Ag Tarama Raporu</title>
<style>
  :root{
    --bg:#0f1419; --panel:#1b2330; --panel2:#232d3d; --ink:#e6edf3; --muted:#9fb0c3;
    --line:#30404f; --accent:#2d7dd2; --accent2:#4aa3df; --crit:#ff5a5a; --ok:#49d17a;
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--ink);
    font:14px/1.55 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;}
  .wrap{max-width:1080px;margin:0 auto;padding:28px 20px 64px;}
  header.top{border-bottom:2px solid var(--line);padding-bottom:16px;margin-bottom:24px;}
  header.top h1{margin:0 0 4px;font-size:26px;letter-spacing:.5px;}
  header.top .sub{color:var(--muted);font-size:13px;}
  .warnbar{margin:14px 0 24px;padding:10px 14px;border:1px solid #6b3b3b;
    background:#2a1b1b;color:#ffbcbc;border-radius:8px;font-size:12.5px;}
  h2{margin:34px 0 10px;font-size:18px;border-left:4px solid var(--accent2);
    padding-left:10px;color:#dce8f5;}
  .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin:8px 0 6px;}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:14px 16px;}
  .card .n{font-size:28px;font-weight:700;}
  .card .l{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.5px;}
  .card.crit .n{color:var(--crit);}
  .card.good .n{color:var(--ok);}
  table{width:100%;border-collapse:collapse;margin:8px 0 6px;font-size:13px;}
  th,td{border:1px solid var(--line);padding:7px 10px;text-align:left;vertical-align:top;}
  th{background:var(--panel2);color:#cfe0f0;font-weight:600;}
  tr:nth-child(even) td{background:#192231;}
  pre{background:#0c1118;border:1px solid var(--line);border-radius:8px;
    padding:12px 14px;overflow:auto;font-size:12.5px;white-space:pre-wrap;word-break:break-word;}
  .crit{color:var(--crit);font-weight:700;}
  .skip{color:var(--muted);font-style:italic;}
  .skipbox{background:#201a12;border:1px solid #5a4a2a;border-radius:8px;padding:10px 14px;margin:10px 0;color:#e9d9b8;}
  .catbl td.n{text-align:right;font-weight:700;width:90px;}
  footer{margin-top:40px;border-top:1px solid var(--line);padding-top:14px;color:var(--muted);font-size:12px;}
  @media print{ body{background:#fff;color:#111} .wrap{max-width:none}
    .card,table th,pre{background:#f4f6f8;color:#111} .crit{color:#c00} }
</style>
</head>
<body><div class="wrap">
HEAD

    printf '<header class="top"><h1>ictara &mdash; Ic Ag Tarama Raporu</h1>'
    printf '<div class="sub">Hedef: <b>%s</b> &nbsp;|&nbsp; Tarih: %s &nbsp;|&nbsp; Cikti: %s</div></header>\n' \
        "$(printf '%s' "$target_disp" | html_escape)" "$now" "$(printf '%s' "$OUTDIR" | html_escape)"

    echo '<div class="warnbar">Bu rapor yalnizca YETKILI sizma testleri icindir. Arac exploit CALISTIRMAZ; yalnizca tespit/surum/zafiyet-kontrolu yapar.</div>'

    # Yonetici ozeti - kartlar
    echo '<h2>Yonetici Ozeti</h2><div class="cards">'
    printf '<div class="card"><div class="n">%s</div><div class="l">Canli Host</div></div>' "$hostcount"
    printf '<div class="card"><div class="n">%s</div><div class="l">Portlu Host</div></div>' "$portcount"
    printf '<div class="card %s"><div class="n">%s</div><div class="l">Kritik Bulgu</div></div>' \
        "$([[ $critsum -gt 0 ]] && echo crit || echo good)" "$critsum"
    printf '<div class="card %s"><div class="n">%s</div><div class="l">Zafiyetli (NSE)</div></div>' \
        "$([[ $vulns -gt 0 ]] && echo crit || echo good)" "$vulns"
    echo '</div>'

    # Kritik bulgu kategorileri
    echo '<table class="catbl"><thead><tr><th>Kategori</th><th>Adet</th><th>Aciklama</th></tr></thead><tbody>'
    printf '<tr><td>SMBv1 acik</td><td class="n">%s</td><td>Eski/zafiyetli SMB (EternalBlue yuzeyi)</td></tr>' "$smbv1"
    printf '<tr><td>SMB signing kapali</td><td class="n">%s</td><td>NTLM relay saldirisina acik</td></tr>' "$nosign"
    printf '<tr><td>Korumasiz DB sinyali</td><td class="n">%s</td><td>Auth''suz Redis/Mongo/Memcached vb.</td></tr>' "$authdb"
    printf '<tr><td>Zafiyetli host (NSE)</td><td class="n">%s</td><td>ms17-010 / smb-vuln* / rdp-vuln</td></tr>' "$vulns"
    printf '<tr><td>VMware/ESXi surum</td><td class="n">%s</td><td>SOAP ile tespit edilen VMware ornegi</td></tr>' "$vmware"
    echo '</tbody></table>'

    skipped_box

    # FAZ 1 - Envanter
    echo '<h2>FAZ 1 &mdash; Kesif &amp; Envanter</h2>'
    inventory_table

    # FAZ 2 - Port haritasi
    echo '<h2>FAZ 2 &mdash; Port Haritasi</h2>'
    portmap_table

    # FAZ 3 - adimlar
    echo '<h2>FAZ 3 &mdash; Hedefli Tarama Adimlari</h2>'
    if [[ -s "$OUTDIR/03_os_detect_nxc.txt" || -s "$OUTDIR/03_os_detect_nmap.txt" || -s "$OUTDIR/03_os_detect.txt" ]]; then
        [[ -s "$OUTDIR/03_os_detect_nxc.txt" ]]  && section_file "OS Tespiti (netexec)"       "$OUTDIR/03_os_detect_nxc.txt"  'signing:False|SMBv1:True'
        [[ -s "$OUTDIR/03_os_detect_nmap.txt" ]] && section_file "OS Tespiti (nmap fallback)"  "$OUTDIR/03_os_detect_nmap.txt" ''
        [[ -s "$OUTDIR/03_os_detect.txt" ]]      && section_file "OS Tespiti (nmap)"           "$OUTDIR/03_os_detect.txt"      ''
    else
        echo '<h2>OS Tespiti</h2><p class="skip">Bu adim calismadi.</p>'
    fi
    section_file "SMB / SMBv1 (netexec)"     "$OUTDIR/04_smb_nxc.txt"  'signing:False|SMBv1:True'
    section_file "SMB / SMBv1 (nmap NSE)"    "$OUTDIR/04_smb_nmap.txt" 'SMBv1|signing|disabled'
    section_file "SMB Share / CIFS"          "$OUTDIR/05_shares.txt"   'Anonymous|WRITE|READ'
    section_file "SNMP"                       "$OUTDIR/06_snmp.txt"     'community|valid credentials'
    section_file "Telnet / Clear-text"       "$OUTDIR/07_cleartext.txt" 'telnet|ftp-anon|Anonymous|rlogin|vnc'
    section_file "Veritabani / Surumler"     "$OUTDIR/08_databases.txt" 'uptime_in_seconds|redis-info|mongodb-info|memcached-info|open'
    section_file "VMware - Aday Tarama"      "$OUTDIR/09_vmware_tarama.txt" 'VMware|ESXi|vmware-auth|O=VMware'
    section_file "VMware - SOAP Surumler"    "$OUTDIR/09_vmware_surumler.txt" 'fullName|version|build|VMware|ESXi'
    section_file "Hizli Zafiyet NSE"         "$OUTDIR/10_vuln_nse.txt" 'VULNERABLE|State: VULNERABLE'

    echo '<footer>ictara ic-ag recon &mdash; otomatik uretilmis rapor. Ham nmap ciktilari ve OZET_RAPOR.txt ayni dizindedir.</footer>'
    echo '</div></body></html>'
    } > "$html"

    ok "HTML rapor -> $html"
    make_pdf "$html"
    log_summary "FAZ 4 - RAPOR" "HTML: $html  ($hostcount host, $critsum kritik bulgu)"
}
