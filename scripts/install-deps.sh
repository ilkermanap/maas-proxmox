#!/bin/bash
#
# install-deps.sh - Ubuntu 22.04+ build host'una packer-maas bagimliliklarini kurar.
#
# Kullanim:  sudo ./scripts/install-deps.sh
#
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Bu script root olarak calistirilmali: sudo $0" >&2
    exit 1
fi

. /etc/os-release
if [ "${ID:-}" != "ubuntu" ] && [ "${ID_LIKE:-}" != "debian" ]; then
    echo "UYARI: Bu script Ubuntu/Debian icin yazildi (bulunan: ${PRETTY_NAME:-bilinmiyor})." >&2
fi

export DEBIAN_FRONTEND=noninteractive

echo "==> Temel paketler kuruluyor"
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl gpg git make parted pigz jq \
    qemu-system-x86 qemu-utils ovmf cloud-image-utils \
    libnbd-bin nbdkit fuse2fs cpu-checker

echo "==> HashiCorp APT deposu ekleniyor (packer)"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://apt.releases.hashicorp.com/gpg \
    | gpg --dearmor --yes -o /etc/apt/keyrings/hashicorp-archive-keyring.gpg
chmod 0644 /etc/apt/keyrings/hashicorp-archive-keyring.gpg
cat > /etc/apt/sources.list.d/hashicorp.list <<REPO
deb [signed-by=/etc/apt/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${UBUNTU_CODENAME:-${VERSION_CODENAME}} main
REPO

apt-get update
apt-get install -y packer

echo "==> KVM kontrolu"
if ! kvm-ok; then
    echo "HATA: KVM kullanilamiyor. VM'de nested virtualization acik mi? (Proxmox: cpu=host)" >&2
    exit 1
fi

# Build root olarak kosuyor ama kullaniciyi da kvm grubuna alalim.
TARGET_USER="${SUDO_USER:-}"
if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ]; then
    adduser "$TARGET_USER" kvm >/dev/null 2>&1 || true
fi

echo
echo "==> Hazir. Surumler:"
packer version
qemu-system-x86_64 --version | head -1
