#!/bin/bash
# Copyright (C) 2026 Ilker Manap
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Prints the newest pve-manager version in the configured Proxmox repository.
# Used by CI to decide whether a rebuild is worth doing.
set -euo pipefail
cd "$(dirname "$0")/../.."

SUITE=$(make -s print-var VAR=DEBIAN_SERIES)
COMP=$(make -s print-var VAR=PVE_REPO)
URI=$(make -s print-var VAR=PVE_REPO_URI)
ARCH=$(make -s print-var VAR=ARCH)

VER=$(curl -fsS "${URI}/dists/${SUITE}/${COMP}/binary-${ARCH}/Packages.gz" \
      | gunzip \
      | awk '/^Package: pve-manager$/{p=1; next} p && /^Version: /{print $2; p=0}' \
      | sort -V | tail -1)

[ -n "$VER" ] || { echo "pve-manager version not found in ${URI} ${SUITE}/${COMP}" >&2; exit 1; }
printf '%s\n' "$VER"
