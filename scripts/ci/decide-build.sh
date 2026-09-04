#!/bin/bash
# Copyright (C) 2026 Ilker Manap
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Decides whether a rebuild is worth doing, and prints the decision as
# key=value lines suitable for $GITHUB_OUTPUT.
#
#   decide-build.sh [max-age-days]     (default 30)
#
# A rebuild happens when any of these is true:
#
#   1. pve-manager in the repository differs from the published image
#   2. proxmox-default-kernel differs — kernel security fixes do not bump
#      pve-manager, and those are the ones that matter most
#   3. the newest release is older than max-age-days — Debian base security
#      updates bump neither of the above, so without a floor an image could
#      sit unchanged for months
#
# Requires GITEA_API and GITEA_TOKEN in the environment.
set -euo pipefail
cd "$(dirname "$0")/../.."

MAX_AGE_DAYS="${1:-30}"
: "${GITEA_API:?GITEA_API required}"
: "${GITEA_TOKEN:?GITEA_TOKEN required}"

SUITE=$(make -s print-var VAR=DEBIAN_SERIES)
COMP=$(make -s print-var VAR=PVE_REPO)
URI=$(make -s print-var VAR=PVE_REPO_URI)
ARCH=$(make -s print-var VAR=ARCH)

# Newest version of each package we care about, in one pass over the index.
PKGS=$(curl -fsS "${URI}/dists/${SUITE}/${COMP}/binary-${ARCH}/Packages.gz" | gunzip)
newest() {
    printf '%s\n' "$PKGS" \
      | awk -v want="$1" '$1=="Package:" && $2==want {p=1; next} p && $1=="Version:" {print $2; p=0}' \
      | sort -V | tail -1
}
UP_PVE=$(newest pve-manager)
UP_KERNEL=$(newest proxmox-default-kernel)
[ -n "$UP_PVE" ]    || { echo "pve-manager not found in ${URI} ${SUITE}/${COMP}" >&2; exit 1; }
[ -n "$UP_KERNEL" ] || { echo "proxmox-default-kernel not found" >&2; exit 1; }

echo "upstream: pve-manager=${UP_PVE} proxmox-default-kernel=${UP_KERNEL}" >&2

# What the newest published release actually contains. image-info.txt is a few
# hundred bytes and is published with every release, so this needs no guessing
# from tag names.
LATEST=$(curl -fsS -H "Authorization: token ${GITEA_TOKEN}" "${GITEA_API}/releases?limit=1")
INFO_URL=$(printf '%s' "$LATEST" | python3 -c '
import json, sys
r = json.load(sys.stdin)
if r:
    for a in r[0].get("assets", []):
        if a["name"] == "image-info.txt":
            print(a["browser_download_url"]); break
')
CREATED=$(printf '%s' "$LATEST" | python3 -c '
import json, sys
r = json.load(sys.stdin); print(r[0]["created_at"] if r else "")')

PREV_PVE="" PREV_KERNEL=""
if [ -n "$INFO_URL" ]; then
    INFO=$(curl -fsSL "$INFO_URL" || true)
    PREV_PVE=$(printf '%s' "$INFO"    | awk -F= '$1=="pve-manager"{print $2}')
    PREV_KERNEL=$(printf '%s' "$INFO" | awk -F= '$1=="proxmox-default-kernel"{print $2}')
fi
echo "published: pve-manager=${PREV_PVE:-<none>} proxmox-default-kernel=${PREV_KERNEL:-<none>}" >&2

AGE_DAYS=99999
if [ -n "$CREATED" ]; then
    AGE_DAYS=$(CREATED="$CREATED" python3 -c '
import datetime, os
c = datetime.datetime.fromisoformat(os.environ["CREATED"].replace("Z", "+00:00"))
print((datetime.datetime.now(datetime.timezone.utc) - c).days)')
    echo "newest release is ${AGE_DAYS} day(s) old" >&2
fi

BUILD=no
REASON="up to date"
if [ -z "$PREV_PVE" ]; then
    BUILD=yes; REASON="no published image yet"
elif [ "$UP_PVE" != "$PREV_PVE" ]; then
    BUILD=yes; REASON="pve-manager ${PREV_PVE} -> ${UP_PVE}"
elif [ "$UP_KERNEL" != "$PREV_KERNEL" ]; then
    BUILD=yes; REASON="kernel ${PREV_KERNEL} -> ${UP_KERNEL}"
elif [ "$AGE_DAYS" -ge "$MAX_AGE_DAYS" ]; then
    BUILD=yes; REASON="image is ${AGE_DAYS} days old (limit ${MAX_AGE_DAYS}) — picking up Debian updates"
fi
echo "decision: ${BUILD} (${REASON})" >&2

printf 'build=%s\n'   "$BUILD"
printf 'tag=%s\n'     "pve-${UP_PVE}-$(date -u +%Y%m%d)"
printf 'version=%s\n' "$UP_PVE"
printf 'kernel=%s\n'  "$UP_KERNEL"
printf 'reason=%s\n'  "$REASON"
