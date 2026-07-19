#!/usr/bin/env bash
#
# Regression test for the release notes in .github/workflows/release.yml.
#
# WHY THIS EXISTS. The body said "First SLSA L2 attested release of
# capa_authgate". It was true for exactly one release, was already false
# when v0.2.0 published it, and false again for v0.2.1. The body is
# reused verbatim for every future release, so a sentence about one
# particular release is wrong by construction from the second release
# onward. That is the same bug class as v0.2.0 shipping with capa.toml
# still saying 0.1.0: a static string asserting something specific, from
# a place that gets reused.
#
# The second case here is a sibling found while sweeping for the first.
# The publisher fingerprint was written out TWICE in this one file: once
# as the value the tag signature is checked against, and once in the
# notes as the fingerprint readers are told to trust. Rotate the key,
# update the check, forget the notes, and every release page then tells
# users to verify against a key the workflow itself rejects.
#
# `capa test` runs the .capa files in this directory and ignores this
# one. Run it directly:
#
#   bash tests/test_release_body.sh
#
# Deliberately grep-based rather than YAML-parsing, so it needs nothing
# installed and runs anywhere the release does.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="${REPO_ROOT}/.github/workflows/release.yml"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

check() {
  local desc="$1" condition="$2"
  if eval "${condition}"; then ok "${desc}"; else no "${desc}"; fi
}

if [ ! -f "${WORKFLOW}" ]; then
  echo "FAIL: ${WORKFLOW} not found" >&2
  exit 1
fi

# The release-note body: everything from `body: |` to the end of its
# indented block. Comments above `body:` are workflow source, not notes,
# so they are correctly outside this region.
BODY="$(awk '
  /^[[:space:]]*body:[[:space:]]*\|/ { in_body = 1; next }
  in_body && /^[[:space:]]*[a-zA-Z_-]+:/ && !/^[[:space:]]{12}/ { in_body = 0 }
  in_body { print }
' "${WORKFLOW}")"

check "the release body is non-empty" '[ -n "${BODY}" ]'

# The defect itself.
check "no 'First ... release' claim in the body" \
  '! printf "%s" "${BODY}" | grep -qiE "\bfirst\b"'

# The generalisation. Anything that dates the notes to one release is
# the same defect wearing different words.
check "no 'initial'/'inaugural'/'debut' claim in the body" \
  '! printf "%s" "${BODY}" | grep -qiE "\b(initial|inaugural|debut)\b"'

# A literal version number in the body is a claim about one release by
# definition. The tag must be interpolated instead.
check "no hardcoded version number in the body" \
  '! printf "%s" "${BODY}" | grep -qE "[^.0-9][0-9]+\.[0-9]+\.[0-9]+"'

check "the body names the release by interpolating the tag" \
  'printf "%s" "${BODY}" | grep -qF "github.ref_name"'

# The sibling defect: one security constant, one place.
FPR_COUNT="$(grep -c "6C1D222D491FB88031E041A536CFB426101AA24B" "${WORKFLOW}")"
check "the publisher fingerprint is written exactly once (found ${FPR_COUNT})" \
  '[ "${FPR_COUNT}" = "1" ]'

check "the body reads the fingerprint from that single source" \
  'printf "%s" "${BODY}" | grep -qF "env.PINNED_FPR"'

# The claims the body DOES make must be true of every release, which
# means the workflow has to actually do these things every time.
check "every release really is attested (the body says so)" \
  'grep -qF "attest-build-provenance" "${WORKFLOW}"'

check "every release really is checked against a signed tag" \
  'grep -qF "git verify-tag" "${WORKFLOW}"'

printf '\n%s passed, %s failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" = "0" ]
