#!/usr/bin/env bash
#
# Fail the release unless the pushed tag matches the version declared in
# capa.toml.
#
# WHY THIS EXISTS. v0.2.0 was tagged, built, attested and published while
# capa.toml still said version = "0.1.0". Everything downstream of the tag
# was correct: the signature, the tarball digest, the Rekor entry. The
# artefact simply carried the wrong label, so `capa install` on the v0.2.0
# tarball reported `capa_authgate 0.1.0`. Nothing in the release workflow
# had ever compared the two, so nothing could catch it. That tag is not
# rewritable without destroying the provenance it anchors, so v0.2.0 stays
# published with the incorrect label and this guard exists so that no later
# tag can repeat it.
#
# THIS SCRIPT IS THE GUARD, not a copy of it. release.yml invokes this
# file, so what CI runs is what you can run here:
#
#   tools/check_tag_version.sh v0.2.1 capa.toml     # passes
#   tools/check_tag_version.sh v9.9.9 capa.toml     # fails
#
# IT FAILS CLOSED. A guard that succeeds when it cannot do its job is
# worse than no guard, because it manufactures false confidence. Every
# way of not knowing is an error: no tag argument, no manifest, a manifest
# with no [package] version, an empty parse, or more than one candidate
# version line. Only an exact match exits 0.

set -euo pipefail

TAG="${1-}"
MANIFEST="${2-capa.toml}"

if [ -z "${TAG}" ]; then
  echo "ERROR: no tag given; usage: $0 <tag> [manifest]" >&2
  exit 1
fi

if [ ! -f "${MANIFEST}" ]; then
  echo "ERROR: manifest '${MANIFEST}' not found; cannot compare against tag ${TAG}" >&2
  exit 1
fi

# Read `version` from the [package] table ONLY. A bare grep would also
# match a [dependencies.*] tag/version line and could compare the tag
# against a dependency's pin, which would be a guard passing for the
# wrong reason.
VERSIONS="$(awk '
  /^[[:space:]]*\[/ { in_package = ($0 ~ /^[[:space:]]*\[package\][[:space:]]*$/); next }
  in_package && /^[[:space:]]*version[[:space:]]*=/ {
    line = $0
    sub(/^[^=]*=[[:space:]]*/, "", line)
    sub(/[[:space:]]*(#.*)?$/, "", line)
    gsub(/^["\x27]|["\x27]$/, "", line)
    print line
  }
' "${MANIFEST}")"

if [ -z "${VERSIONS}" ]; then
  echo "ERROR: no [package] version found in ${MANIFEST}; refusing to release" >&2
  exit 1
fi

COUNT="$(printf '%s\n' "${VERSIONS}" | wc -l | tr -d '[:space:]')"
if [ "${COUNT}" != "1" ]; then
  echo "ERROR: ${MANIFEST} declares ${COUNT} [package] version lines; expected exactly 1" >&2
  printf '%s\n' "${VERSIONS}" >&2
  exit 1
fi

VERSION="${VERSIONS}"
if [ -z "${VERSION}" ]; then
  echo "ERROR: [package] version in ${MANIFEST} parsed as empty; refusing to release" >&2
  exit 1
fi

if [ "${TAG}" != "v${VERSION}" ]; then
  echo "ERROR: tag ${TAG} does not match the version declared in ${MANIFEST}" >&2
  echo "       manifest says ${VERSION}, so the tag must be v${VERSION}" >&2
  echo "       fix capa.toml and tag again; do NOT rewrite a published tag" >&2
  exit 1
fi

echo "OK: tag ${TAG} matches ${MANIFEST} version ${VERSION}"
