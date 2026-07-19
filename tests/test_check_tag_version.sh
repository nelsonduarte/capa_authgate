#!/usr/bin/env bash
#
# Regression test for tools/check_tag_version.sh, the release guard that
# would have caught v0.2.0 shipping with capa.toml still saying 0.1.0.
#
# `capa test` runs the .capa files in this directory and ignores this one,
# because the guard is shell rather than Capa. Run it directly:
#
#   bash tests/test_check_tag_version.sh
#
# The point of the negative cases is that a guard is only worth what its
# FAILURES are worth. Asserting it says OK on the happy path proves almost
# nothing; a `true` would pass that. So every case below except the first
# asserts a NON-zero exit, including the case where the only 0.2.1 in the
# manifest belongs to a dependency, which is how this guard could most
# plausibly have passed for the wrong reason.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="${REPO_ROOT}/tools/check_tag_version.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0
FAIL=0

# expect <want_exit> <description> <args...>
expect() {
  local want="$1" desc="$2"
  shift 2
  local out got
  out="$(bash "${GUARD}" "$@" 2>&1)"
  got=$?
  if [ "${got}" = "${want}" ]; then
    PASS=$((PASS + 1))
    printf 'ok   %s (exit %s)\n' "${desc}" "${got}"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s: wanted exit %s, got %s\n%s\n' "${desc}" "${want}" "${got}" "${out}"
  fi
}

printf '[package]\nname = "capa_authgate"\nversion = "0.2.1"\ncapa = ">=1.17.0"\n' \
  > "${WORK}/good.toml"
printf '[package]\nname = "capa_authgate"\nversion = "0.1.0"\n' \
  > "${WORK}/stale.toml"
printf '[package]\nname = "capa_authgate"\ncapa = ">=1.17.0"\n' \
  > "${WORK}/noversion.toml"
printf '[package]\nname = "capa_authgate"\nversion = ""\n' \
  > "${WORK}/empty.toml"
printf '[package]\nname = "x"\nversion = "0.2.1"\nversion = "9.9.9"\n' \
  > "${WORK}/dup.toml"
printf '[package]\nname = "x"\n\n[dependencies.capa_jwt]\nversion = "0.2.1"\n' \
  > "${WORK}/deponly.toml"
printf '[package]\nname = "x"\nversion = "0.2.1"  # trailing comment\n' \
  > "${WORK}/comment.toml"

expect 0 "matching tag and version"                 v0.2.1 "${WORK}/good.toml"
expect 0 "version with a trailing comment"          v0.2.1 "${WORK}/comment.toml"
expect 1 "the real v0.2.0 defect: tag ahead of manifest" v0.2.0 "${WORK}/stale.toml"
expect 1 "tag behind the manifest"                  v0.1.0 "${WORK}/good.toml"
expect 1 "tag without the v prefix"                 0.2.1  "${WORK}/good.toml"
expect 1 "missing manifest"                         v0.2.1 "${WORK}/absent.toml"
expect 1 "empty tag (unset GITHUB_REF_NAME)"        ""     "${WORK}/good.toml"
expect 1 "manifest with no [package] version"       v0.2.1 "${WORK}/noversion.toml"
expect 1 "version present but empty"                v0.2.1 "${WORK}/empty.toml"
expect 1 "two [package] version lines"              v0.2.1 "${WORK}/dup.toml"
expect 1 "only a DEPENDENCY declares the version"   v0.2.1 "${WORK}/deponly.toml"

# The guard as the release actually invokes it, against the real manifest.
expect 0 "live capa.toml against its own tag" \
  "v$(awk '/^\[/{p=($0~/^\[package\]/)} p&&/^version/{gsub(/[" ]/,"");sub(/^version=/,"");print}' "${REPO_ROOT}/capa.toml")" \
  "${REPO_ROOT}/capa.toml"
expect 1 "live capa.toml against a wrong tag" v9.9.9 "${REPO_ROOT}/capa.toml"

printf '\n%s passed, %s failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" = "0" ]
