#!/usr/bin/env python3
"""Make the pinned SD1/SD2 importer propagate malformed-weight errors.

Run after resolving Swift packages, before building. The upstream reader throws
for missing tensors, but its caller uses try! and terminates the app. Keep this
one-line fix tied to the exact reviewed revision and file, rather than silently
patching future dependency versions.
"""

import argparse
import hashlib
from pathlib import Path
import subprocess
import sys


REVISION = "d473a2f148b3e7dc9b90d0b7cfccc5cda999eb66"
SOURCE = Path("Libraries/ModelOp/Sources/ModelImporter.swift")
ORIGINAL_SHA256 = "a5795dabbbddd5f1a12dd9ea58051ed684d8b4bdd601a3f2ed52ce146b697d16"
PATCHED_SHA256 = "7cbac00d5787fa33c6a3c5bd152133fafb5889b120ca2fc2d26bfbeb5c435292"
BEFORE = b"try! unetReader(stateDict, archive)"
AFTER = b"try unetReader(stateDict, archive)"


def patch_importer(checkouts: Path) -> bool:
    checkout = checkouts / "draw-things-community"
    revision = subprocess.check_output(
        ["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True
    ).strip()
    if revision != REVISION:
        raise ValueError("ModelImporter revision changed; review or remove its safety patch.")

    source = checkout / SOURCE
    original = source.read_bytes()
    digest = hashlib.sha256(original).hexdigest()
    if digest == PATCHED_SHA256:
        return False
    if digest != ORIGINAL_SHA256 or original.count(BEFORE) != 1:
        raise ValueError("ModelImporter source changed; refusing an unreviewed patch.")
    patched = original.replace(BEFORE, AFTER, 1)
    if hashlib.sha256(patched).hexdigest() != PATCHED_SHA256:
        raise ValueError("ModelImporter patch checksum does not match the reviewed result.")
    source.write_bytes(patched)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkouts", type=Path, help="SwiftPM SourcePackages/checkouts directory")
    args = parser.parse_args()
    try:
        changed = patch_importer(args.checkouts)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"ModelImporter safety patch failed: {error}", file=sys.stderr)
        return 1
    print("ModelImporter safety patch applied." if changed else "ModelImporter safety patch already applied.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
