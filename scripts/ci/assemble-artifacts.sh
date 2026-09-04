#!/bin/bash
# Copyright (C) 2026 Ilker Manap
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Moves the built image into dist/ under a release-friendly name and writes the
# checksum plus the corresponding-source offer that has to accompany a binary
# distribution of GPL/AGPL software.
#
#   assemble-artifacts.sh <pve-manager-version>
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION="${1:?pve-manager version required}"
OUT=$(make -s print-var VAR=OUTPUT)
ARCH=$(make -s print-var VAR=ARCH)
[ -f "$OUT" ] || { echo "built image not found: $OUT" >&2; exit 1; }

# Deliberately not named "proxmox-ve-*": that would look like an official
# Proxmox artifact. Proxmox asks that their trademark not be used in product
# names, so the image is named after what it is - a MAAS image.
NAME="maas-image-pve-${VERSION}-${ARCH}.tar.gz"

rm -rf dist && mkdir -p dist
mv "$OUT" "dist/${NAME}"
( cd dist && sha256sum "$NAME" > "${NAME}.sha256" )

tar xzf "dist/${NAME}" -O ./etc/pve-maas/image-info > dist/image-info.txt 2>/dev/null \
  || echo "(this image predates /etc/pve-maas/image-info)" > dist/image-info.txt

DEB_VER=$(make -s print-var VAR=DEBIAN_VERSION)
DEB_SUITE=$(make -s print-var VAR=DEBIAN_SERIES)
PVE_REPO=$(make -s print-var VAR=PVE_REPO)
PVE_URI=$(make -s print-var VAR=PVE_REPO_URI)
REPO_URL="${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}"

{
    echo "# Corresponding source"
    echo
    echo "This image is an unmodified installation of packages from the archives listed"
    echo "below. No package was patched. What is ours is the selection and the"
    echo "configuration, and that is the entire content of the repository linked below."
    echo
    echo "Written offer, per GPLv2 section 3 and GPLv3 section 6: the complete"
    echo "corresponding source for every package in this image is available from the"
    echo "archive it was installed from, at the versions recorded in the image's own"
    echo "package database (\`/var/lib/dpkg/status\`)."
    echo
    echo "| Component | Source |"
    echo "|---|---|"
    echo "| Debian ${DEB_VER} \"${DEB_SUITE}\" | <https://deb.debian.org/debian> — \`apt-get source <pkg>\` |"
    echo "| Proxmox VE (${PVE_REPO}) | <https://git.proxmox.com/> and \`deb-src ${PVE_URI}\` |"
    echo "| Build recipe | <${REPO_URL}> |"
    echo
    echo "The firmware blobs under \`/usr/lib/firmware\` are redistributed verbatim;"
    echo "their licence texts ship inside the image at"
    echo "\`/usr/share/doc/pve-firmware/licenses/\` and must not be stripped."
    echo
    echo "## Image metadata"
    echo
    echo '```'
    cat dist/image-info.txt
    echo '```'
} > dist/SOURCES.md

ls -lh dist/
