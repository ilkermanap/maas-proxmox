#!/bin/bash
# Copyright (C) 2026 Ilker Manap
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Creates a Gitea release and uploads the image, its checksum and the
# corresponding-source offer.
#
#   publish-release.sh <tag> <version> <dist-dir>
#
# Requires GITEA_API and GITEA_TOKEN in the environment.
set -euo pipefail

TAG="${1:?tag required}"
VERSION="${2:?version required}"
DIST="${3:?dist directory required}"

# DIST cagiranin dizinine goreli olabilir; repo kokune gecmeden once mutlaklastir.
DIST="$(cd "$DIST" && pwd)"
# make degiskenlerini okuyabilmek icin depo koku gerekiyor.
cd "$(dirname "$0")/../.."
: "${GITEA_API:?GITEA_API required}"
: "${GITEA_TOKEN:?GITEA_TOKEN required}"

REPO_URL="${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}"
RUN="${GITHUB_RUN_NUMBER:-manual}"
SHA="${GITHUB_SHA:-}"
IMAGE=$(basename "$(ls "$DIST"/maas-image-*.tar.gz)")
MAAS_ARCH=$(make -s print-var VAR=MAAS_ARCH)
PVE_MAJOR=$(make -s print-var VAR=PVE_VERSION)
IMAGE_NAME=$(make -s print-var VAR=IMAGE_NAME)

BODY=$(cat <<BODYEOF
Unofficial build of a MAAS-deployable Proxmox VE image.
**Not affiliated with or endorsed by Proxmox Server Solutions GmbH.**

- pve-manager: \`${VERSION}\`
- Built: $(date -u +%Y-%m-%dT%H:%M:%SZ), run ${RUN}
- Verify: \`sha256sum -c ${IMAGE}.sha256\`

Upload to MAAS:

\`\`\`bash
maas \$PROFILE boot-resources create name='custom/${IMAGE_NAME}' \\
    title='Proxmox VE ${PVE_MAJOR}' architecture='${MAAS_ARCH}' \\
    filetype='tgz' content@=${IMAGE}
\`\`\`

The curtin preseed from this repository must also be installed on the MAAS region
controller, otherwise deployment fails — see the README.

\`SOURCES.md\` in this release carries the corresponding-source offer required by
the GPL/AGPL licences of the packages inside the image.
BODYEOF
)

# A forced rebuild on the same day, of the same upstream version, produces the
# tag that is already published and the API answers 409. Disambiguate with the
# run number rather than overwriting a release someone may already have used.
if curl -fsS -o /dev/null -H "Authorization: token ${GITEA_TOKEN}" \
        "${GITEA_API}/releases/tags/${TAG}" 2>/dev/null; then
    TAG="${TAG}-r${RUN}"
    echo "tag already exists; publishing as ${TAG} instead"
fi

PAYLOAD=$(TAG="$TAG" VERSION="$VERSION" BODY="$BODY" SHA="$SHA" python3 -c '
import json, os
print(json.dumps({
    "tag_name": os.environ["TAG"],
    "name": "Proxmox VE %s image" % os.environ["VERSION"],
    "body": os.environ["BODY"],
    "draft": False,
    "prerelease": False,
    "target_commitish": os.environ["SHA"],
}))')

ID=$(curl -fsS -X POST \
        -H "Authorization: token ${GITEA_TOKEN}" \
        -H 'Content-Type: application/json' \
        -d "$PAYLOAD" "${GITEA_API}/releases" \
     | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
echo "release id: ${ID}"

for f in "$DIST"/*; do
    [ -f "$f" ] || continue
    echo "uploading $(basename "$f") ($(du -h "$f" | cut -f1))"
    curl -fsS -X POST \
        -H "Authorization: token ${GITEA_TOKEN}" \
        -F "attachment=@${f}" \
        "${GITEA_API}/releases/${ID}/assets?name=$(basename "$f")" >/dev/null
done

echo "published: ${REPO_URL}/releases/tag/${TAG}"
