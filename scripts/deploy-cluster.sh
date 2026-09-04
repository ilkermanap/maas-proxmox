#!/bin/bash
# Copyright (C) 2026 Ilker Manap
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# deploy-cluster.sh - MAAS uzerinden komple bir Proxmox VE kumesi kurar.
#
# Ilk dugumu 'create' modunda deploy eder, ayaga kalkmasini bekler, sertifika
# parmak izini okur ve kalan dugumleri o parmak iziyle 'join' modunda deploy eder.
#
# NEREDE CALISTIRILIR: MAAS region controller uzerinde (ya da 'maas' CLI profili
# tanimli ve dugumlerin 8006 portuna erisebilen bir makinede).
#
# Ornek:
#   ./deploy-cluster.sh --name pve-prod --nodes pve1,pve2,pve3
#   ./deploy-cluster.sh --name pve-dr --nodes dr1,dr2 --profile admin --dry-run
#
set -euo pipefail

PROFILE=admin
CLUSTER_NAME=""
NODES=""
DISTRO_SERIES=proxmox-ve-9
ROOT_PASSWORD=""
ROOT_PASSWORD_HASH=""
THINPOOL=auto
THINPOOL_MIN_GB=16
NET_APPLY=reboot
LINK0_PREFIX=""
DEPLOY_TIMEOUT=2400
PEER_TIMEOUT=1200
SERIAL=false
DRY_RUN=false

usage() {
    # Bastaki yorum blogunu, ilk kod satirina kadar bas.
    awk 'NR>1 && /^#/{ if ($0 ~ /Copyright|SPDX/) next; sub(/^# ?/,""); print; next } \
         NR>1 && !/^#/{exit}' "$0"
    cat <<EOF

Secenekler:
  --name <ad>            Kume adi (zorunlu)
  --nodes <a,b,c>        MAAS hostname listesi; ILKI kumeyi olusturur (zorunlu)
  --profile <ad>         maas CLI profili (varsayilan: ${PROFILE})
  --distro-series <ad>   MAAS ozel imaj adi (varsayilan: ${DISTRO_SERIES})
  --root-password <p>    root@pam parolasi. Verilmezse uretilir ve ekrana yazilir.
  --thinpool <deger>     auto | off | <vg-adi>   (varsayilan: ${THINPOOL})
  --thinpool-min-gb <n>  Thin havuz icin gereken en az bos alan (varsayilan: ${THINPOOL_MIN_GB})
  --net-apply <mod>      reboot | reload | none  (varsayilan: ${NET_APPLY})
  --link0-prefix <cidr>  Corosync link0 icin ayri ag oneki, or. 10.10.20.
                         Dugumun o agdaki adresi otomatik bulunur.
  --serial               Katilan dugumleri teker teker deploy et (buyuk kumelerde)
  --dry-run              Hicbir sey deploy etme, uretilecek user-data'yi goster
  -h, --help             Bu yardim

Notlar:
  * Kume dugumunun root parolasi API dogrulamasi icin DUZ METIN olarak
    user-data'ya girer ve MAAS'ta saklanir. Kisa omurlu bir parola kullanip
    kurulumdan sonra degistirin.
  * Ayni imaj ve preseed ile birden fazla bagimsiz kume kurabilirsiniz;
    kume kimligi yalnizca bu user-data'dan gelir.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --name)            CLUSTER_NAME="$2"; shift 2 ;;
        --nodes)           NODES="$2"; shift 2 ;;
        --profile)         PROFILE="$2"; shift 2 ;;
        --distro-series)   DISTRO_SERIES="$2"; shift 2 ;;
        --root-password)   ROOT_PASSWORD="$2"; shift 2 ;;
        --thinpool)        THINPOOL="$2"; shift 2 ;;
        --thinpool-min-gb) THINPOOL_MIN_GB="$2"; shift 2 ;;
        --net-apply)       NET_APPLY="$2"; shift 2 ;;
        --link0-prefix)    LINK0_PREFIX="$2"; shift 2 ;;
        --serial)          SERIAL=true; shift ;;
        --dry-run)         DRY_RUN=true; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "Bilinmeyen secenek: $1" >&2; usage; exit 2 ;;
    esac
done

[ -n "$CLUSTER_NAME" ] || { echo "HATA: --name zorunlu" >&2; exit 2; }
[ -n "$NODES" ]        || { echo "HATA: --nodes zorunlu" >&2; exit 2; }

for c in maas jq openssl base64; do
    command -v "$c" >/dev/null || { echo "HATA: '$c' bulunamadi" >&2; exit 1; }
done

IFS=',' read -r -a NODE_LIST <<< "$NODES"
FIRST="${NODE_LIST[0]}"
JOINERS=("${NODE_LIST[@]:1}")

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mHATA: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- kimlik bilgileri
if [ -z "$ROOT_PASSWORD" ]; then
    ROOT_PASSWORD="$(openssl rand -base64 15 | tr -d '/+=' | head -c 16)"
    GENERATED=true
else
    GENERATED=false
fi
ROOT_PASSWORD_HASH="$(openssl passwd -6 "$ROOT_PASSWORD")"

# ---------------------------------------------------------------- MAAS yardimcilari
maas_get() { maas "$PROFILE" machines read hostname="$1" 2>/dev/null | jq -r ".[0].$2 // empty"; }

require_ready() {
    local h st
    for h in "${NODE_LIST[@]}"; do
        st="$(maas_get "$h" status_name)"
        [ -n "$st" ] || die "MAAS'ta '$h' adinda makine yok"
        [ "$st" = "Ready" ] || die "'$h' durumu '$st' - deploy icin 'Ready' olmali (once release edin)"
        info "$h: Ready"
    done
}

wait_status() {
    local h="$1" want="$2" timeout="$3" waited=0 st
    while [ "$waited" -lt "$timeout" ]; do
        st="$(maas_get "$h" status_name)"
        case "$st" in
            "$want")            return 0 ;;
            Failed*|Broken*)    die "'$h' durumu '$st' - MAAS olaylarina bakin" ;;
        esac
        sleep 20; waited=$((waited + 20))
    done
    die "'$h' ${timeout}s icinde '$want' durumuna gelmedi (son durum: ${st:-bilinmiyor})"
}

node_ip() { maas "$PROFILE" machines read hostname="$1" 2>/dev/null | jq -r '.[0].ip_addresses[0] // empty'; }

wait_port() {
    local ip="$1" port="$2" timeout="$3" waited=0
    while [ "$waited" -lt "$timeout" ]; do
        if timeout 4 bash -c "exec 3<>/dev/tcp/${ip}/${port}" 2>/dev/null; then return 0; fi
        sleep 10; waited=$((waited + 10))
    done
    die "${ip}:${port} ${timeout}s icinde acilmadi"
}

fingerprint_of() {
    openssl s_client -connect "$1:8006" -servername "$1" </dev/null 2>/dev/null \
        | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2
}

# Dugumun link0 oneki ile eslesen adresini MAAS'tan bul.
link0_of() {
    [ -n "$LINK0_PREFIX" ] || return 0
    maas "$PROFILE" machines read hostname="$1" 2>/dev/null \
        | jq -r --arg p "$LINK0_PREFIX" '.[0].ip_addresses[]? | select(startswith($p))' | head -1
}

# ---------------------------------------------------------------- user-data uretimi
render_userdata() {
    local mode="$1" host="$2" peer="${3:-}" fp="${4:-}" link0
    link0="$(link0_of "$host")"

    cat <<EOF
#cloud-config
# ${host} - kume '${CLUSTER_NAME}' (${mode})
# deploy-cluster.sh tarafindan uretildi
write_files:
  - path: /etc/pve-maas/conf.d/50-pve.conf
    permissions: "0600"
    owner: root:root
    content: |
      PVE_ROOT_PASSWORD_HASH='${ROOT_PASSWORD_HASH}'
      PVE_NET_APPLY=${NET_APPLY}
      PVE_THINPOOL=${THINPOOL}
      PVE_THINPOOL_MIN_GB=${THINPOOL_MIN_GB}
EOF

    if [ "$mode" = "create" ]; then
        cat <<EOF
      PVE_CLUSTER_MODE=create
      PVE_CLUSTER_NAME=${CLUSTER_NAME}
EOF
    else
        cat <<EOF
      PVE_CLUSTER_MODE=join
      PVE_CLUSTER_PEER=${peer}
      PVE_CLUSTER_PEER_PASSWORD='${ROOT_PASSWORD}'
      PVE_CLUSTER_FINGERPRINT='${fp}'
EOF
    fi
    [ -n "$link0" ] && echo "      PVE_CLUSTER_LINK0=${link0}"
    return 0
}

deploy_node() {
    local host="$1" ud="$2" sid
    sid="$(maas_get "$host" system_id)"
    maas "$PROFILE" machine deploy "$sid" \
        osystem=custom "distro_series=${DISTRO_SERIES}" \
        "user_data=$(printf '%s' "$ud" | base64 -w0)" >/dev/null
}

# ---------------------------------------------------------------- akis
log "Kume: ${CLUSTER_NAME}"
info "ilk dugum (create) : ${FIRST}"
info "katilanlar (join)  : ${JOINERS[*]:-yok}"
info "imaj               : custom/${DISTRO_SERIES}"
[ -n "$LINK0_PREFIX" ] && info "corosync link0 oneki: ${LINK0_PREFIX}"

if [ "$DRY_RUN" = true ]; then
    log "DRY RUN - hicbir sey deploy edilmiyor"
    echo "--- ${FIRST} (create) ---"
    render_userdata create "$FIRST"
    for h in "${JOINERS[@]:-}"; do
        [ -n "$h" ] || continue
        echo "--- ${h} (join) ---"
        render_userdata join "$h" "<ilk-dugumun-IP-si>" "<parmak-izi>"
    done
    echo
    echo "root@pam parolasi: ${ROOT_PASSWORD}"
    exit 0
fi

log "Makineler kontrol ediliyor"
require_ready

log "${FIRST} deploy ediliyor (kume olusturuluyor)"
deploy_node "$FIRST" "$(render_userdata create "$FIRST")"
wait_status "$FIRST" Deployed "$DEPLOY_TIMEOUT"
info "MAAS deploy tamamlandi"

FIRST_IP="$(node_ip "$FIRST")"
[ -n "$FIRST_IP" ] || die "'$FIRST' icin IP bulunamadi"
info "IP: ${FIRST_IP}"

info "Proxmox arayuzunun acilmasi bekleniyor (ag donusumu icin bir kez yeniden baslar)"
wait_port "$FIRST_IP" 8006 "$PEER_TIMEOUT"

FP="$(fingerprint_of "$FIRST_IP")"
[ -n "$FP" ] || die "'$FIRST' sertifika parmak izi okunamadi"
info "parmak izi: ${FP}"

if [ "${#JOINERS[@]}" -eq 0 ] || [ -z "${JOINERS[0]:-}" ]; then
    log "Katilacak baska dugum yok"
else
    log "Katilan dugumler deploy ediliyor"
    for h in "${JOINERS[@]}"; do
        info "deploy: $h"
        deploy_node "$h" "$(render_userdata join "$h" "$FIRST_IP" "$FP")"
        if [ "$SERIAL" = true ]; then
            wait_status "$h" Deployed "$DEPLOY_TIMEOUT"
            info "$h: MAAS deploy tamamlandi, kumeye katilmasi bekleniyor"
            sleep 60
        fi
    done
    [ "$SERIAL" = false ] && {
        for h in "${JOINERS[@]}"; do wait_status "$h" Deployed "$DEPLOY_TIMEOUT"; info "$h: deploy tamamlandi"; done
    }
fi

log "Kume durumu bekleniyor"
EXPECTED="${#NODE_LIST[@]}"
# Tum dugumlerin 8006'da yanit vermesini bekle - kume uyeligini asagidaki
# talimatla dugum uzerinden dogrulayin (bu script dugumlere SSH yapmaz).
for h in "${NODE_LIST[@]}"; do
    ip="$(node_ip "$h")"
    if [ -n "$ip" ] && wait_port "$ip" 8006 300 2>/dev/null; then
        info "$h ($ip): Proxmox arayuzu acik"
    else
        info "$h: 8006 acilmadi - 'journalctl -u pve-maas-init -b' ile bakin"
    fi
done

cat <<EOF

Kume '${CLUSTER_NAME}' kuruldu.

  Ilk dugum      : ${FIRST}  (${FIRST_IP})
  Web arayuzu    : https://${FIRST_IP}:8006/
  Kullanici      : root@pam
  Parola         : ${ROOT_PASSWORD}$([ "$GENERATED" = true ] && echo "   <- uretildi, kaydedin")

Dogrulamak icin bir dugumde:
  pvecm status        # 'Nodes: ${EXPECTED}' ve 'Quorate: Yes' bekleniyor
  pvecm nodes

Dugumler kumeye katilmadiysa ilgili dugumde:
  journalctl -u pve-maas-init -b
EOF
