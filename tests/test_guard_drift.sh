#!/usr/bin/env bash
#
# Drift check for the vendored copy of release guard 1.
#
# WHY A LOCAL COPY EXISTS AT ALL. CI runs the guard from the compiler
# repository, pinned by commit SHA in .github/workflows/release.yml, and
# that pinned copy is the one that gates a release. But a guard you can
# only run by pushing a tag is a guard you cannot rehearse, so
# tools/check_tag_version.sh is kept here as well, purely so that it and
# tests/test_check_tag_version.sh run offline on a laptop.
#
# WHY THIS TEST EXISTS. A second copy of a security guard is the exact
# thing the shared workflow was created to abolish: N copies drift, and a
# drifted copy still reports success. The local copy was ALREADY drifting
# before this test was written, having been forked before the shared guard
# gained its third argument, so the two printed different messages and
# accepted different arguments while looking interchangeable. The copy is
# therefore held BYTE-IDENTICAL to the pinned canonical guard, and this
# test is what holds it there. Nothing local may be added to that file,
# not even a comment saying it is a copy; that is what this header is for.
#
# Run it directly:
#
#   bash tests/test_guard_drift.sh
#
# `capa test` runs the .capa files in tests/ and ignores this one.
#
# It reports SKIP rather than failing when `gh` is missing or
# unauthenticated, matching tests/test_release_wiring.sh: an offline
# machine cannot fetch the canonical bytes, and a test that guesses at
# them is the failure mode this file is about. The pin itself is still
# checked offline, because a malformed pin means there is no canonical
# revision to compare against and that is knowable without the network.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="${REPO_ROOT}/.github/workflows/release.yml"
LOCAL="${REPO_ROOT}/tools/check_tag_version.sh"

GUARD_REPO="nelsonduarte/capa-language"
GUARD_FILE="tools/check_tag_version.sh"

PASS=0
FAIL=0
SKIP=0

ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
no()   { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf 'skip %s\n' "$1"; }

if [ ! -f "${WORKFLOW}" ]; then
  echo "FAIL: ${WORKFLOW} not found" >&2
  exit 1
fi

if [ -f "${LOCAL}" ]; then
  ok "a local copy of the guard exists at tools/${GUARD_FILE##*/}"
else
  no "tools/${GUARD_FILE##*/} not found; either restore it or drop this test"
  printf '\n%s passed, %s failed, %s skipped\n' "${PASS}" "${FAIL}" "${SKIP}"
  exit 1
fi

# The revision to compare against is not a constant in this file: it is
# whatever release.yml pins, so bumping the pin retargets the comparison
# and a stale local copy goes red at the bump rather than silently later.
PIN="$(sed -n 's|^[[:space:]]*uses:[[:space:]]*'"${GUARD_REPO}"'/\.github/workflows/release-guards\.yml@||p' "${WORKFLOW}")"
PIN="${PIN%%[[:space:]]*}"

if printf '%s' "${PIN}" | grep -qE '^[0-9a-f]{40}$'; then
  ok "release.yml pins a full 40-character guard revision (${PIN})"
else
  no "release.yml does not pin a full 40-character guard revision (got '${PIN}')"
  printf '\n%s passed, %s failed, %s skipped\n' "${PASS}" "${FAIL}" "${SKIP}"
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  skip "the local guard is byte-identical to the pinned canonical one (gh not installed)"
elif ! gh auth status >/dev/null 2>&1; then
  skip "the local guard is byte-identical to the pinned canonical one (gh not authenticated)"
else
  CANON="$(mktemp)"
  trap 'rm -f "${CANON}"' EXIT
  if gh api "repos/${GUARD_REPO}/contents/${GUARD_FILE}?ref=${PIN}" \
       --jq .content 2>/dev/null | base64 -d > "${CANON}" && [ -s "${CANON}" ]; then
    # Compare with CRs stripped from both sides. A checkout on Windows can
    # carry them, and a line-ending difference is not drift in the guard's
    # behaviour, which is what this test is about.
    if diff -u <(tr -d '\r' < "${CANON}") <(tr -d '\r' < "${LOCAL}") > "${CANON}.diff"; then
      ok "the local guard is byte-identical to ${GUARD_REPO}@${PIN}:${GUARD_FILE}"
    else
      no "the local guard has DRIFTED from ${GUARD_REPO}@${PIN}:${GUARD_FILE}"
      echo "     the pinned copy is what CI runs; make the local one match it, or"
      echo "     delete the local copy and this test if it is no longer wanted:"
      sed 's/^/     /' "${CANON}.diff"
    fi
    rm -f "${CANON}.diff"
  else
    no "could not fetch ${GUARD_FILE} at ${PIN}; the pin may not carry the guard"
  fi
fi

# --- the pin, audited BY CONTENT ---------------------------------------
#
# Everything above concerns the one guard file this repository also keeps
# a runnable copy of. This part covers every file the guards execute, and
# it exists because "we ran the revision you pinned" was previously
# established by a value the platform handed the guards rather than by
# anything observable about the files. Two revisions that are
# byte-identical are indistinguishable by such a value, and two that are
# NOT identical are exactly the case that must be caught.
#
# So: .github/guard-pins.sha256 records the digest of each guard file at
# the revision this repository audited, and this refetches and compares.
# A pin bumped without re-auditing goes red on the revision line; a pin
# whose bytes are not the audited bytes goes red on a digest. Neither
# outcome depends on anything the guards say about themselves.

PINS="${REPO_ROOT}/.github/guard-pins.sha256"

if [ ! -f "${PINS}" ]; then
  no "the audited guard digests are recorded (.github/guard-pins.sha256)"
else
  ok "the audited guard digests are recorded (.github/guard-pins.sha256)"

  AUDITED_REV="$(awk '$1 == "revision" { print $2; exit }' "${PINS}")"

  check_rev() {
    if [ -z "${AUDITED_REV}" ]; then
      no "guard-pins.sha256 names no revision; it cannot describe anything"
      return 1
    fi
    if [ "${AUDITED_REV}" != "${PIN}" ]; then
      no "the audited revision is not the pinned one"
      echo "     release.yml pins        ${PIN}"
      echo "     guard-pins.sha256 names ${AUDITED_REV}"
      echo "     re-read the diff between them, then re-record the digests"
      return 1
    fi
    ok "the audited revision is the one release.yml pins"
    return 0
  }

  if check_rev; then
    # One digest line per guard file: "<sha256>  <path>".
    ENTRIES="$(grep -E '^[0-9a-f]{64}[[:space:]]+[^[:space:]]+' "${PINS}" || true)"

    if [ -z "${ENTRIES}" ]; then
      no "guard-pins.sha256 records no digests; it would pass having checked nothing"
    elif ! command -v gh >/dev/null 2>&1; then
      skip "every guard file matches its audited digest (gh not installed)"
    elif ! gh auth status >/dev/null 2>&1; then
      skip "every guard file matches its audited digest (gh not authenticated)"
    else
      while read -r want path; do
        [ -z "${path}" ] && continue
        got="$(gh api "repos/${GUARD_REPO}/contents/${path}?ref=${PIN}" \
                 --jq .content 2>/dev/null | base64 -d | sha256sum | cut -d' ' -f1)"
        if [ -z "${got}" ]; then
          no "${path} could not be fetched at ${PIN}; the pin may not carry it"
        elif [ "${got}" = "${want}" ]; then
          ok "${path} matches its audited digest"
        else
          no "${path} at ${PIN} is NOT the audited file"
          echo "     audited ${want}"
          echo "     fetched ${got}"
        fi
      done <<< "${ENTRIES}"
    fi
  fi
fi

printf '\n%s passed, %s failed, %s skipped\n' "${PASS}" "${FAIL}" "${SKIP}"
[ "${FAIL}" = "0" ]
