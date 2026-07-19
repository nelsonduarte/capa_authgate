#!/usr/bin/env bash
#
# Regression test for how .github/workflows/release.yml CALLS the shared
# release guards.
#
# WHY THIS EXISTS. The guards themselves are tested where they live, in
# the compiler repository. What is NOT tested there, and cannot be, is
# whether a consumer wired them up in a way that actually gates
# anything. A `guards:` job that runs and reports failure while the
# release publishes anyway is worse than no guard at all: it produces a
# green-looking gate, a red job nobody reads, and a published artefact.
# That is the same shape as the three defects the guards exist to catch,
# verification that proves nothing about the thing it appears to cover.
#
# The wiring can break in ways that no YAML parser and no linter calls
# an error, because every one of them is a VALID workflow:
#
#   * pinning a tag or a branch instead of a commit, so the guard can be
#     edited under us;
#   * pinning a well-formed SHA that does not exist, so every release
#     fails at dispatch, or worse, resolves to something unintended;
#   * dropping `needs: guards`, so the two jobs race and the release can
#     publish before the guards finish;
#   * `continue-on-error` or a job-level `if: always()`, so the guards
#     run, fail, and block nothing.
#
# Every case below asserts one of those. Run it directly:
#
#   bash tests/test_release_wiring.sh
#
# `capa test` runs the .capa files in tests/ and ignores this one.
#
# Deliberately grep and awk based rather than YAML-parsing, matching
# tests/test_release_body.sh: it needs nothing installed and runs
# anywhere the release runs. The one check that needs the network (does
# the pinned commit exist, and does it carry the workflow file) reports
# SKIP rather than failing when `gh` is unavailable or unauthenticated,
# because an offline machine cannot answer that question and a test that
# guesses is the failure mode this whole file is about.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="${REPO_ROOT}/.github/workflows/release.yml"

GUARD_REPO="nelsonduarte/capa-language"
GUARD_PATH=".github/workflows/release-guards.yml"

PASS=0
FAIL=0
SKIP=0

ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
no()   { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf 'skip %s\n' "$1"; }

check() {
  local desc="$1" condition="$2"
  if eval "${condition}"; then ok "${desc}"; else no "${desc}"; fi
}

if [ ! -f "${WORKFLOW}" ]; then
  echo "FAIL: ${WORKFLOW} not found" >&2
  exit 1
fi

# Extract one job's block: from `  <name>:` at two-space indent up to the
# next line at that same indent level. Job-level keys sit at four spaces
# and steps deeper, so this captures the whole job and nothing after it.
job_block() {
  awk -v job="$1" '
    BEGIN { header = "^  " job ":[[:space:]]*$" }
    $0 ~ header { in_job = 1; next }
    in_job && /^  [A-Za-z_-]+:/ { in_job = 0 }
    in_job { print }
  ' "${WORKFLOW}"
}

GUARDS="$(job_block guards)"
RELEASE="$(job_block release)"

check "a guards job exists" '[ -n "${GUARDS}" ]'
check "a release job exists" '[ -n "${RELEASE}" ]'

# --- the guards are the shared ones, at a pinned commit ----------------

USES="$(printf '%s\n' "${GUARDS}" | sed -n 's/^[[:space:]]*uses:[[:space:]]*//p')"

check "the guards job calls a reusable workflow" '[ -n "${USES}" ]'

check "it calls the shared guards, not a local copy" \
  'printf "%s" "${USES}" | grep -qF "${GUARD_REPO}/${GUARD_PATH}@"'

# The pin itself. A tag is mutable and a branch more so, so anything
# that is not a full 40-hex commit SHA is refused. An abbreviated SHA is
# refused too: abbreviations can become ambiguous as a repository grows.
PIN="${USES##*@}"
check "the guards are pinned by a full 40-character commit SHA (got '${PIN}')" \
  'printf "%s" "${PIN}" | grep -qE "^[0-9a-f]{40}$"'

# --- the guards actually gate the release ------------------------------

check "the release job declares needs: guards" \
  'printf "%s" "${RELEASE}" | grep -qE "^[[:space:]]*needs:[[:space:]]*(guards|\[[[:space:]]*guards[[:space:]]*\])[[:space:]]*$"'

# `continue-on-error` on the guards job turns a failing gate into a
# passing one, which is the single most dangerous edit possible here.
check "the guards job does not set continue-on-error" \
  '! printf "%s" "${GUARDS}" | grep -qE "^[[:space:]]*continue-on-error:"'

check "the release job does not set continue-on-error" \
  '! printf "%s" "${RELEASE}" | grep -qE "^[[:space:]]*continue-on-error:"'

# A job-level `if:` on the release job can defeat `needs:` entirely:
# `if: always()` and `if: !cancelled()` both run the job after the
# guards have failed. Step-level `if:` keys sit deeper than four spaces
# and are not matched here.
check "the release job has no job-level if: that could bypass the guards" \
  '! printf "%s" "${RELEASE}" | grep -qE "^    if:"'

check "the guards job has no job-level if: that could skip it" \
  '! printf "%s" "${GUARDS}" | grep -qE "^    if:"'

# --- the guards are given enough to prove something --------------------

# An empty consumer-commands makes the clean room report success having
# run nothing. The shared guard refuses that itself; this asserts the
# caller never gets there, and that the flow covers what this package
# actually claims.
COMMANDS="$(printf '%s\n' "${GUARDS}" | awk '
  /^[[:space:]]*consumer-commands:[[:space:]]*\|/ { in_cmds = 1; next }
  in_cmds && /^[[:space:]]{0,8}[a-zA-Z_-]+:/ { in_cmds = 0 }
  in_cmds { print }
' | grep -vE '^[[:space:]]*(#.*)?$')"

check "the clean room is given consumer commands" '[ -n "${COMMANDS}" ]'

check "the consumer flow imports the publisher key first" \
  '[ "$(printf "%s\n" "${COMMANDS}" | head -1 | tr -d "[:space:]")" = "gpg--importpublisher.asc" ]'

check "the consumer flow installs dependencies" \
  'printf "%s" "${COMMANDS}" | grep -qF "capa install"'

# The nested-vendor step is what makes --check-capabilities answerable
# at all; without it the ceiling gate fails closed on a layout question.
check "the consumer flow builds the nested vendor layout" \
  'printf "%s" "${COMMANDS}" | grep -qF "tools/nest_vendor.py"'

# Both entry points, compiled AND ceiling-checked. The ceiling is this
# package's central claim, so a clean room that only compiled would be
# verifying the less interesting half.
for entry in main.capa service.capa; do
  check "the consumer flow compiles ${entry}" \
    "printf '%s' \"\${COMMANDS}\" | grep -qE '^[[:space:]]*capa --check ${entry}\$'"
  check "the consumer flow checks the capability ceiling of ${entry}" \
    "printf '%s' \"\${COMMANDS}\" | grep -qF 'capa --check-capabilities ${entry}'"
done

check "the consumer flow runs the tests" \
  'printf "%s" "${COMMANDS}" | grep -qE "^[[:space:]]*capa test[[:space:]]*$"'

# --- the guards hold no credential they could publish with -------------

GUARD_PERMS="$(printf '%s\n' "${GUARDS}" | awk '
  /^[[:space:]]*permissions:[[:space:]]*$/ { in_perms = 1; next }
  in_perms && /^    [a-zA-Z_-]+:/ { in_perms = 0 }
  in_perms { print }
' | grep -vE '^[[:space:]]*(#.*)?$')"

check "the guards job states its own permissions" '[ -n "${GUARD_PERMS}" ]'

# The workflow-level grant is write-heavy (contents, id-token,
# attestations) and a job that says nothing inherits all of it. The
# guards read; `id-token: write` in particular is the token that SIGNS
# attestations, and a guard must not be able to sign anything.
check "the guards job grants itself no write permission" \
  '! printf "%s" "${GUARD_PERMS}" | grep -qE ":[[:space:]]*write[[:space:]]*$"'

check "the guards job does not take id-token" \
  '! printf "%s" "${GUARD_PERMS}" | grep -qE "^[[:space:]]*id-token:"'

# --- the caller closes the gap the guards cannot ------------------------

# Guard 2 verifies a tarball it rebuilt from the tag, not the bytes this
# workflow uploads, because it has to run before publication. Only the
# release job holds the artefact it is about to publish, so only it can
# assert the two are the same.
check "the release job compares its tarball to the digest the guards verified" \
  'printf "%s" "${RELEASE}" | grep -qF "needs.guards.outputs.tarball-sha256"'

# --- the rehearsal predicts the release ---------------------------------

# guard-selftest.yml exists so the plumbing can be exercised on demand
# instead of one data point per tag. It is only worth having if it
# rehearses the SAME thing the release runs: a self-test pinned to a
# different guard revision, or handed a different consumer flow, reports
# success about a pipeline that is not the one which will publish.

SELFTEST="${REPO_ROOT}/.github/workflows/guard-selftest.yml"

if [ ! -f "${SELFTEST}" ]; then
  no "a dispatchable guard self-test exists (guard-selftest.yml)"
else
  ok "a dispatchable guard self-test exists (guard-selftest.yml)"

  SELF_USES="$(sed -n 's/^[[:space:]]*uses:[[:space:]]*//p' "${SELFTEST}" \
    | grep -F "${GUARD_REPO}/${GUARD_PATH}@" || true)"
  SELF_PIN="${SELF_USES##*@}"

  check "the self-test pins the SAME guard revision as the release (got '${SELF_PIN}')" \
    '[ -n "${SELF_PIN}" ] && [ "${SELF_PIN}" = "${PIN}" ]'

  # The commands are the whole substance of guard 2. Compared as a set
  # of non-blank, non-comment lines, so indentation cannot make two
  # identical flows look different.
  self_commands() {
    awk '
      /^[[:space:]]*consumer-commands:[[:space:]]*\|/ { in_cmds = 1; next }
      in_cmds && /^[[:space:]]{0,8}[a-zA-Z_-]+:/ { in_cmds = 0 }
      in_cmds { print }
    ' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -vE '^(#.*)?$'
  }

  check "the self-test runs the same consumer flow as the release" \
    '[ "$(self_commands "${SELFTEST}")" = "$(self_commands "${WORKFLOW}")" ]'

  # A rehearsal that can publish is not a rehearsal. It must hold no
  # write scope at all, and above all no id-token, which is the token
  # that signs attestations.
  check "the self-test grants no write permission anywhere" \
    '! grep -qE "^[[:space:]]*[a-z-]+:[[:space:]]*write[[:space:]]*$" "${SELFTEST}"'

  check "the self-test never takes id-token" \
    '! grep -qE "^[[:space:]]*id-token:" "${SELFTEST}"'

  # It must not be reachable from a tag push, or it becomes a second
  # release path with none of the release path's checks.
  check "the self-test is dispatch-only" \
    'grep -qE "^[[:space:]]*workflow_dispatch:" "${SELFTEST}" && ! grep -qE "^[[:space:]]*(push|release):" "${SELFTEST}"'
fi

# --- does the pin actually exist (network) ------------------------------

if ! command -v gh >/dev/null 2>&1; then
  skip "the pinned commit exists and carries ${GUARD_PATH} (gh not installed)"
elif ! gh auth status >/dev/null 2>&1; then
  skip "the pinned commit exists and carries ${GUARD_PATH} (gh not authenticated)"
elif ! printf "%s" "${PIN}" | grep -qE "^[0-9a-f]{40}$"; then
  skip "the pinned commit exists and carries ${GUARD_PATH} (no valid SHA to look up)"
else
  # Two separate facts. A commit can exist without containing the file,
  # which would be a pin that resolves and guards nothing.
  if gh api "repos/${GUARD_REPO}/commits/${PIN}" --jq .sha >/dev/null 2>&1; then
    ok "the pinned commit ${PIN} exists in ${GUARD_REPO}"
  else
    no "the pinned commit ${PIN} does not exist in ${GUARD_REPO}"
  fi

  if gh api "repos/${GUARD_REPO}/contents/${GUARD_PATH}?ref=${PIN}" --jq .sha >/dev/null 2>&1; then
    ok "${GUARD_PATH} exists at the pinned commit"
  else
    no "${GUARD_PATH} is absent at the pinned commit; the pin guards nothing"
  fi
fi

printf '\n%s passed, %s failed, %s skipped\n' "${PASS}" "${FAIL}" "${SKIP}"
[ "${FAIL}" = "0" ]
