#!/usr/bin/env python3
"""Mirror the flat `vendor/` tree into the NESTED layout that
`capa --check-capabilities` expects.

WHY THIS EXISTS. Two parts of the toolchain disagree about where a
dependency's own dependencies live, as of capa 1.18.0:

  * `capa install` reads the ROOT capa.toml only and never opens a
    vendored package's manifest, so it vendors FLAT: every package,
    however deep in the graph, lands in `vendor/<name>`. That is why
    this repository declares capa_hash and capa_url directly even
    though nothing here imports them (see capa.toml).

  * the SBOM composition behind `--check-capabilities` resolves a
    dependency of package P at `<P's dir>/vendor/<name>`, i.e. NESTED.
    It finds nothing there, and because an unanalyzable subtree cannot
    be proven within any ceiling, it FAILS CLOSED - correctly, but on
    a layout question rather than on an authority question.

So the gate can never pass for a project whose dependency graph is
more than one level deep, unless the nested copies exist. This script
makes them, by copying from the flat tree `capa install` produced. It
invents nothing: every package copied was already fetched, verified,
and pinned by `capa install`.

Usage, from the repository root:

    capa install
    python tools/nest_vendor.py
    capa --check-capabilities service.capa

`vendor/` is gitignored, so this is a build step and not a commit.
"""

import shutil
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor"


def declared_deps(pkg_dir):
    """The runtime dependency names in a package's capa.toml.
    dev-dependencies are excluded: they are never resolved for a
    package that is not the install root."""
    manifest = pkg_dir / "capa.toml"
    if not manifest.is_file():
        return []
    data = tomllib.loads(manifest.read_text(encoding="utf-8"))
    return sorted(data.get("dependencies", {}))


def main():
    if not VENDOR.is_dir():
        sys.exit("vendor/ not found: run `capa install` first")

    made = 0
    # One pass over the flat tree is enough: every package in the graph
    # is already a top-level entry there, so each one's dependencies
    # can be satisfied from it.
    for pkg_dir in sorted(p for p in VENDOR.iterdir() if p.is_dir()):
        for name in declared_deps(pkg_dir):
            src = VENDOR / name
            if not src.is_dir():
                sys.exit(
                    f"{pkg_dir.name} needs {name}, which is not in vendor/. "
                    f"Declare {name} in capa.toml and re-run `capa install`."
                )
            dst = pkg_dir / "vendor" / name
            if dst.is_dir():
                continue
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(src, dst, ignore=shutil.ignore_patterns("vendor"))
            print(f"nested {name} under vendor/{pkg_dir.name}/")
            made += 1

    print(f"nest_vendor: {made} nested copy/copies")


if __name__ == "__main__":
    main()
