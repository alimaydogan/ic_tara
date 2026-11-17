#!/usr/bin/env bash
#
# install.sh - ictara'yi sisteme kurar (tara.sh gibi her yerden 'sudo ictara').
#   /usr/local/bin/ictara            <- ana script (launcher)
#   /usr/local/share/ictara/lib/     <- lib/*.sh
#   /usr/local/share/ictara/conf/    <- conf/*.conf
#
# Kullanim:
#   sudo ./install.sh              # kur
#   sudo ./install.sh --uninstall  # kaldir
# -------------------------------------------------------------------
set -euo pipefail

# PREFIX ve DESTDIR ortam degiskenleriyle override edilebilir (standart).
#   sudo ./install.sh
#   sudo PREFIX=/opt ./install.sh
#   DESTDIR=/tmp/stage PREFIX=/usr/local ./install.sh   (paketleme/test)
PREFIX="${PREFIX:-/usr/local}"
DESTDIR="${DESTDIR:-}"
BINDIR="$DESTDIR$PREFIX/bin"
SHAREDIR="$DESTDIR$PREFIX/share/ictara"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# DESTDIR verildiyse (staging/test) root sart degil; gercek kurulum/kaldirmada gerekir.
if [[ -z "$DESTDIR" && $EUID -ne 0 ]]; then
    echo "[!] Root gerekiyor: sudo ./install.sh   (veya DESTDIR=... ile staging)" >&2
    exit 1
fi

if [[ "${1:-}" == "--uninstall" ]]; then
    rm -f  "$BINDIR/ictara"
    rm -rf "$SHAREDIR"
    echo "[+] ictara kaldirildi ($BINDIR/ictara, $SHAREDIR)."
    exit 0
fi

# Kaynak dogrulamasi
[[ -f "$SRC/ictara.sh" ]]      || { echo "[!] ictara.sh bulunamadi ($SRC)" >&2; exit 1; }
[[ -d "$SRC/lib"  ]]           || { echo "[!] lib/ bulunamadi ($SRC)"  >&2; exit 1; }
[[ -d "$SRC/conf" ]]           || { echo "[!] conf/ bulunamadi ($SRC)" >&2; exit 1; }
[[ -f "$SRC/lib/core.sh" ]]    || { echo "[!] lib/core.sh bulunamadi ($SRC)" >&2; exit 1; }

# Bagimlilik preflight - dosyalari KOPYALAMADAN ONCE, ictara ile ayni ortak
# fonksiyon (lib/core.sh:preflight_deps) kullanilir. Eksikleri (onayla) kurar.
# preflight set -e/-u'dan bagimsiz tasarlandi; gecici olarak gevsetiyoruz.
# shellcheck source=lib/core.sh
source "$SRC/lib/core.sh" || { echo "[!] core.sh yuklenemedi" >&2; exit 1; }
set +e +u
preflight_deps "install" || true
set -e -u

# Dizinler
install -d "$BINDIR" "$SHAREDIR/lib" "$SHAREDIR/conf"

# lib + conf
install -m 0644 "$SRC"/lib/*.sh    "$SHAREDIR/lib/"
install -m 0644 "$SRC"/conf/*.conf "$SHAREDIR/conf/"

# Ana script -> /usr/local/bin/ictara  (uzantisiz, calistirilabilir)
install -m 0755 "$SRC/ictara.sh" "$BINDIR/ictara"

echo "[+] Kuruldu:"
echo "      calistirilabilir : $BINDIR/ictara"
echo "      lib + conf       : $SHAREDIR"
echo ""
echo "    Artik her yerden calisir:  sudo ictara -t 10.0.0.0/24 --auto"
echo "    Kaldirmak icin          :  sudo ./install.sh --uninstall"
