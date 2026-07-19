#!/usr/bin/env python3
"""Regenerate the README's capability table from real `capa --manifest`
output, so the table in the README is never a hand-written claim about
what the compiler found.

Usage, from the repository root:

    python tools/manifest_table.py

It prints a Markdown table to stdout. Paste it into README.md under
"The capability manifest".

`capa --manifest` emits a JSON document whose `functions` array covers
the whole linked program, vendored dependencies included. Only the
functions this repository actually writes or claims something about are
listed, in a fixed order, so the table is stable across runs.
"""

import json
import subprocess
import sys

# (entry point, function, note). The order is the order of the table.
ROWS = [
    ("service.capa", "verify_token", "PURE - the shared verifier, unchanged"),
    ("service.capa", "inspect_token", "PURE - unverified claims decode"),
    ("service.capa", "handle", "PURE - the whole HTTP request handler"),
    ("service.capa", "verify_endpoint", "PURE - `POST /verify`"),
    ("service.capa", "inspect_endpoint", "PURE - `POST /inspect`"),
    ("service.capa", "token_from_body", "PURE - reads attacker-supplied bytes"),
    ("service.capa", "env_or", "configuration, and only that"),
    ("service.capa", "env_int", "configuration, and only that"),
    ("service.capa", "main", "the SERVICE entry point, exactly this"),
    ("main.capa", "mint_token", "exactly, and nothing else"),
    ("main.capa", "cmd_verify", "the Clock is read here, not in the verifier"),
    ("main.capa", "main", "the CLI entry point"),
]


def manifest(path):
    proc = subprocess.run(
        ["capa", "--manifest", path], capture_output=True, text=True
    )
    if proc.returncode != 0:
        sys.exit(f"capa --manifest {path} failed:\n{proc.stderr}")
    doc = json.loads(proc.stdout)
    return {fn["source_name"]: fn for fn in doc["functions"]}


def render(caps):
    if not caps:
        return "`[]`"
    return "`{" + ", ".join(caps) + "}`"


def main():
    cache = {}
    print("| entry point | function | declared capabilities | notes |")
    print("| --- | --- | --- | --- |")
    for entry, name, note in ROWS:
        if entry not in cache:
            cache[entry] = manifest(entry)
        fn = cache[entry].get(name)
        if fn is None:
            sys.exit(f"{name} not found in the manifest of {entry}")
        print(
            f"| `{entry}` | `{name}` | {render(fn['declared_capabilities'])} | {note} |"
        )


if __name__ == "__main__":
    main()
