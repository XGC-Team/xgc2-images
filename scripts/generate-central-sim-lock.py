#!/usr/bin/env python3
"""Regenerate the central-sim package lock from source product metadata.

The lock is a consumer file, not an APT publication artifact. Its versions
come from each owning product's .xgc2/product.yml (source-bound metadata), and
every resulting focal version is checked against a supplied focal Packages
index before the lock is written.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

import yaml


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def load_packages(path: Path) -> set[tuple[str, str]]:
    records: set[tuple[str, str]] = set()
    for block in path.read_text(encoding="utf-8").split("\n\n"):
        package = re.search(r"^Package: (.+)$", block, re.MULTILINE)
        version = re.search(r"^Version: (.+)$", block, re.MULTILINE)
        if package and version:
            records.add((package.group(1), version.group(1)))
    return records


def source_versions(devops_root: Path, catalog: dict[str, Any]) -> dict[str, str]:
    versions: dict[str, str] = {}
    for product in catalog.get("products", []):
        source = product.get("_source")
        apt_packages = product.get("apt", {}).get("packages", [])
        if not source or not apt_packages:
            continue
        product_file = devops_root / source
        metadata = yaml.safe_load(product_file.read_text(encoding="utf-8"))
        apt_versions = metadata.get("release", {}).get("apt_versions", {})
        version = apt_versions.get("focal") or metadata.get("version")
        if not isinstance(version, str) or not version:
            raise SystemExit(f"{product_file}: no focal/version identity")
        for package in apt_packages:
            previous = versions.setdefault(package, version)
            if previous != version:
                raise SystemExit(
                    f"{package}: conflicting source versions {previous} and {version}"
                )
    return versions


def rewrite(lock: Path, versions: dict[str, str], packages: set[tuple[str, str]], write: bool) -> list[str]:
    lines = lock.read_text(encoding="utf-8").splitlines()
    changed: list[str] = []
    seen: set[str] = set()
    lock_packages = {
        line.split("#", 1)[0].strip().split("=", 1)[0]
        for line in lines
        if "=" in line and not line.lstrip().startswith("#")
    }
    for index, line in enumerate(lines):
        body = line.split("#", 1)[0].strip()
        if not body or "=" not in body:
            continue
        package, current = body.split("=", 1)
        if package not in versions:
            continue
        wanted = versions[package]
        if (package, wanted) not in packages:
            raise SystemExit(f"{package}={wanted}: absent from focal Packages")
        seen.add(package)
        if current != wanted:
            lines[index] = line.replace(f"{package}={current}", f"{package}={wanted}", 1)
            changed.append(f"{package}: {current} -> {wanted}")
    missing = sorted(package for package in lock_packages if package in versions and package not in seen)
    if missing:
        raise SystemExit("lock packages without source metadata: " + ", ".join(missing))
    if write:
        lock.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return changed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--catalog", type=Path, required=True,
                        help="devops/catalog/generated/products.json")
    parser.add_argument("--devops-root", type=Path, required=True)
    parser.add_argument("--packages", type=Path, required=True,
                        help="focal/main/binary-amd64 Packages index")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    versions = source_versions(args.devops_root, load_json(args.catalog))
    packages = load_packages(args.packages)
    changed = rewrite(args.lock, versions, packages, write=not args.check)
    for line in changed:
        print(line)
    return 1 if args.check and changed else 0


if __name__ == "__main__":
    raise SystemExit(main())
