#!/bin/bash
#
# verify-image.sh - Uretilen MAAS tgz imajinin beklenen icerige sahip oldugunu dogrular.
#
# Kullanim:  ./scripts/verify-image.sh build/proxmox-ve-9.tar.gz
#
set -uo pipefail

IMG="${1:-}"
[ -n "$IMG" ] && [ -f "$IMG" ] || { echo "Kullanim: $0 <imaj.tar.gz>" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Imaj: $IMG ($(du -h "$IMG" | cut -f1))"
echo "==> Icerik listesi cikariliyor..."
tar tzf "$IMG" > "$TMP/list" || { echo "HATA: arsiv okunamadi"; exit 1; }
echo "    $(wc -l < "$TMP/list") giris"

pass=0; fail=0
have()    { grep -qx "\./$1" "$TMP/list" || grep -q "^\./$1$" "$TMP/list"; }
present() { grep -q "^\./$1" "$TMP/list"; }

check() {
    local desc="$1" cond="$2"
    if eval "$cond"; then
        printf '  [ OK ] %s\n' "$desc"; pass=$((pass+1))
    else
        printf '  [FAIL] %s\n' "$desc"; fail=$((fail+1))
    fi
}

echo
echo "==> Dosya varligi kontrolleri"
check "pve-maas-init mevcut"                  'present "usr/local/sbin/pve-maas-init"'
check "pve-maas.conf mevcut"                  'present "etc/pve-maas/pve-maas.conf"'
check "systemd unit mevcut"                   'present "etc/systemd/system/pve-maas-init.service"'
check "unit multi-user.target icin etkin"     'present "etc/systemd/system/multi-user.target.wants/pve-maas-init.service"'
check "Proxmox APT deposu mevcut"             'present "etc/apt/sources.list.d/proxmox.sources"'
check "Proxmox anahtarligi mevcut"            'present "usr/share/keyrings/proxmox-archive-keyring.gpg"'
check "pveproxy ikilisi mevcut"               'present "usr/bin/pveproxy"'
check "pvecm ikilisi mevcut"                  'present "usr/bin/pvecm"'
check "pvesh ikilisi mevcut"                  'present "usr/bin/pvesh"'
check "ifupdown2 mevcut"                      'present "usr/share/ifupdown2"'
check "cloud-init mevcut"                     'present "usr/bin/cloud-init"'
check "curtin-hooks mevcut"                   'present "curtin/curtin-hooks"'

echo
echo "==> Olmamasi gerekenler"
check "pmxcfs config.db yok (dugum kimligi temiz)"  '! present "var/lib/pve-cluster/config.db"'
check "corosync yapilandirmasi yok"                 '! present "etc/corosync/corosync.conf"'
check "iSCSI initiator adi yok (dugumde uretilir)"  '! present "etc/iscsi/initiatorname.iscsi"'
check "SSH host anahtarlari yok"                    '! grep -qE "^\./etc/ssh/ssh_host_.*_key$" "$TMP/list"'
check "networking.service etkin DEGIL"              '! present "etc/systemd/system/multi-user.target.wants/networking.service"'
check "interfaces.new yok (pvenetcommit ezmesin)"   '! present "etc/network/interfaces.new"'
check "Debian cekirdegi yok"                        '! grep -qE "^\./boot/vmlinuz-.*[^e]-(cloud-)?amd64$" "$TMP/list"'

echo
echo "==> Proxmox cekirdegi"
if grep -qE '^\./boot/vmlinuz-.*-pve$' "$TMP/list"; then
    printf '  [ OK ] PVE cekirdegi: %s\n' "$(grep -oE 'vmlinuz-[^ ]*-pve' "$TMP/list" | head -1)"
    pass=$((pass+1))
else
    printf '  [FAIL] /boot altinda *-pve cekirdegi bulunamadi\n'; fail=$((fail+1))
fi

echo
echo "==> Ayiklanan dosya icerikleri"
tar xzf "$IMG" -C "$TMP" \
    ./etc/apt/sources.list.d/proxmox.sources \
    ./usr/local/sbin/pve-maas-init \
    ./etc/pve-maas/pve-maas.conf 2>/dev/null

tar xzf "$IMG" -C "$TMP" ./etc/network/interfaces 2>/dev/null
if [ -f "$TMP/etc/network/interfaces" ]; then
    echo "--- /etc/network/interfaces ---"
    sed 's/^/    /' "$TMP/etc/network/interfaces"
    if grep -qE '^\s*(auto|iface)\s+(?!lo)' "$TMP/etc/network/interfaces" 2>/dev/null \
       || grep -qE '^[[:space:]]*iface[[:space:]]+[^l ]' "$TMP/etc/network/interfaces"; then
        printf '  [FAIL] interfaces dosyasinda build VM artigi arayuz var\n'; fail=$((fail+1))
    else
        printf '  [ OK ] interfaces yalnizca loopback iceriyor\n'; pass=$((pass+1))
    fi
fi

if [ -f "$TMP/etc/apt/sources.list.d/proxmox.sources" ]; then
    echo "--- proxmox.sources ---"
    sed 's/^/    /' "$TMP/etc/apt/sources.list.d/proxmox.sources"
fi

if [ -x "$TMP/usr/local/sbin/pve-maas-init" ]; then
    printf '  [ OK ] pve-maas-init calistirilabilir\n'; pass=$((pass+1))
else
    printf '  [FAIL] pve-maas-init calistirilabilir degil\n'; fail=$((fail+1))
fi

echo
echo "==> Sonuc: ${pass} basarili, ${fail} basarisiz"
[ "$fail" -eq 0 ]
