#!/bin/bash
# Copyright (C) 2026 Ilker Manap
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Keeps the newest N releases and deletes the rest, tags included.
# Each image is ~1.5 GB, so unbounded retention fills the server.
#
#   prune-releases.sh [keep]        (default 3)
#
# Requires GITEA_API and GITEA_TOKEN in the environment.
set -euo pipefail

KEEP="${1:-3}"
: "${GITEA_API:?GITEA_API required}"
: "${GITEA_TOKEN:?GITEA_TOKEN required}"

curl -fsS -H "Authorization: token ${GITEA_TOKEN}" "${GITEA_API}/releases?limit=50" \
  | KEEP="$KEEP" python3 -c '
import json, os, sys
keep = int(os.environ["KEEP"])
for r in json.load(sys.stdin)[keep:]:
    print(r["id"], r["tag_name"])
' | while read -r id tag; do
    echo "removing old release ${tag}"
    curl -fsS -X DELETE -H "Authorization: token ${GITEA_TOKEN}" \
        "${GITEA_API}/releases/${id}" || true
    curl -fsS -X DELETE -H "Authorization: token ${GITEA_TOKEN}" \
        "${GITEA_API}/tags/${tag}" || true
done
