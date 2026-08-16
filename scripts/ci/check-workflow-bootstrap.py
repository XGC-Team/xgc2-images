#!/usr/bin/env python3
"""Fail if product automation bootstraps OS/toolchain deps.

Product CI must run inside ghcr.io/xgc-team/xgc2-images/xgc2-build-* .
Forbidden: apt/pip toolchain installs, actions/setup-*, rustup, cargo install,
npm -g, curl|sh, and stock ubuntu:/ros: build containers.

Allowed: repo lockfile installs (pnpm install, npm ci, yarn install, bun install,
uv sync, go test) inside an image that already has the toolchain.
Allowed apt: a locally built .deb under test, apt-get -f, and already-published
XGC2 products (`xgc2-*`, `libxgc2-*`, `ros-*-xgc2-*`). High-level controllers
and estimators may install those; images and intermediate libraries may not.

xgc2-images Dockerfiles and scripts/build/ are not scanned. Product workflows,
reachable build helpers, and image lock/manifest files are scanned. The image
repository is the place to add missing distro/toolchain packages.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

FORBIDDEN_USES = (
    "actions/setup-node",
    "actions/setup-python",
    "actions/setup-go",
    "oven-sh/setup-bun",
    "astral-sh/setup-uv",
    "pnpm/action-setup",
    "bufbuild/buf-setup-action",
    "dtolnay/rust-toolchain",
    "actions-rs/toolchain",
    "rust-lang/github-actions",
)

FORBIDDEN_CONTAINER_RE = re.compile(
    r"""(?x)
    (?:
        ubuntu:(?:latest|18\.04|20\.04|22\.04|24\.04|bionic|focal|jammy|noble|\$\{[A-Za-z_][A-Za-z0-9_]*\})
        | ros:(?:melodic|noetic|humble|jazzy|foxy)
        | althack/ros2
        | ghcr\.io/sloretz/ros
        | osrf/ros
        | docker\.io/library/ros@sha256:[0-9a-f]{64}
    )
    """,
    re.IGNORECASE,
)

ALLOWED_IMAGE_RE = re.compile(
    r"ghcr\.io/xgc-team/xgc2-images/|quay\.io/skopeo/stable",
    re.IGNORECASE,
)

HOST_B_RE = re.compile(
    r"\[self-hosted[^\]]*(?:xgc-team-b|\bxgc\b[^\]]*org[^\]]*docker)",
    re.IGNORECASE,
)

PIP_RE = re.compile(
    r"(?:^|[;&|]\s*|\s)(?:python3?\s+-m\s+)?pip(?:3)?\s+install\b",
    re.IGNORECASE,
)
NPM_GLOBAL_RE = re.compile(r"npm\s+(?:i|install)\s+(?:-[^\s]*\s+)*-g\b", re.IGNORECASE)
CARGO_INSTALL_RE = re.compile(r"\bcargo\s+install\b", re.IGNORECASE)
RUSTUP_RE = re.compile(r"sh\.rustup\.rs|\brustup\s+", re.IGNORECASE)
CURL_SH_RE = re.compile(r"curl\b[^|\n]*\|\s*(?:sudo\s+)?(?:bash|sh)\b", re.IGNORECASE)
TOOLCHAIN_DOWNLOAD_RE = re.compile(
    r"(?:go\.dev/dl/go|nodejs\.org/dist/|static\.rust-lang\.org/rustup|"
    r"sh\.rustup\.rs|\bgem\s+install\s+fpm\b|\bcargo\s+install\b|"
    r"\bnpm\s+(?:i|install)\s+(?:-[^\s]*\s+)*-g\b|"
    r"Tools/setup/ubuntu\.sh)",
    re.IGNORECASE,
)
APT_INSTALL_RE = re.compile(
    r"\b(?:apt-get|apt)\s+(?:-[^\s]+\s+)*install\b",
    re.IGNORECASE,
)
AUTOMATION_SCRIPT_RE = re.compile(
    r"^(?:build|bootstrap|ci(?:_|-)|configure|fetch|install_published|prepare)",
    re.IGNORECASE,
)
LEGACY_XGC2_APT_PACKAGE_RE = re.compile(
    r"^ros-(?:melodic|noetic|\$\{ROS_DISTRO\})-"
    r"(?:scout-msgs|swarm-ros-bridge)$",
    re.IGNORECASE,
)


def logical_lines(text: str) -> list[tuple[int, str]]:
    raw = text.splitlines()
    out: list[tuple[int, str]] = []
    buf = ""
    start = 1
    for i, line in enumerate(raw, 1):
        stripped = line.rstrip()
        if not buf:
            start = i
        if stripped.endswith("\\"):
            buf += stripped[:-1] + " "
            continue
        buf += stripped
        out.append((start, buf))
        buf = ""
    if buf:
        out.append((start, buf))
    return out


def strip_comment(line: str) -> str:
    in_s = in_d = False
    for i, ch in enumerate(line):
        if ch == "'" and not in_d:
            in_s = not in_s
        elif ch == '"' and not in_s:
            in_d = not in_d
        elif ch == "#" and not in_s and not in_d:
            return line[:i]
    return line


def _apt_packages(line: str) -> list[str]:
    skip_exact = {
        "sudo",
        "apt-get",
        "apt",
        "install",
        "update",
        "clean",
        "autoclean",
        "autoremove",
        "&&",
        "||",
        "true",
        "fi",
        "then",
        "do",
        "done",
        ">/dev/null",
        "2>/dev/null",
    }
    pkgs: list[str] = []
    match = APT_INSTALL_RE.search(line)
    if not match:
        return []
    tokens = line[match.start() :].replace(",", " ").split()
    install_index = next(
        (index for index, value in enumerate(tokens) if value.lower() == "install"),
        len(tokens),
    )
    for tok in tokens[install_index + 1 :]:
        low = tok.lower()
        if low in skip_exact or low.startswith("-") or low.endswith(":") or "acquire::" in low:
            continue
        pkgs.append(tok)
    return pkgs


def _is_published_xgc2_product(pkg: str) -> bool:
    name = pkg.strip("'\";,()").split("=", 1)[0].lower()
    if name.startswith("xgc2-") or name.startswith("libxgc2-"):
        return True
    return (name.startswith("ros-") and "-xgc2-" in name) or bool(
        LEGACY_XGC2_APT_PACKAGE_RE.fullmatch(name)
    )


def apt_install_allowed(line: str) -> bool:
    pkgs = _apt_packages(line)
    if not pkgs:
        return True
    return all(
        p.strip("'\";,()").startswith("./")
        or p.strip("'\";,()").endswith(".deb")
        or "*.deb" in p
        or "/debs/" in p
        or "/workspace/out/" in p
        or p.strip("'\";,()").startswith("debs/")
        or ("deb" in p.lower() and p.strip("'\";,()").startswith("$"))
        or _is_published_xgc2_product(p)
        for p in pkgs
    )


def scan_file(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    findings: list[str] = []
    rel = str(path)
    for lineno, raw in logical_lines(text):
        line = strip_comment(raw).strip()
        if not line:
            continue
        for uses in FORBIDDEN_USES:
            if uses in line:
                findings.append(f"{rel}:{lineno}: forbidden toolchain action {uses}")
        if HOST_B_RE.search(line):
            findings.append(
                f"{rel}:{lineno}: public CI must not use Host B self-hosted runners"
            )
        if PIP_RE.search(line) and not re.search(
            r"\bpip(?:3)?\s+install\s+(?:--no-deps\s+)?\.\s+(?:--no-deps\b|$)",
            line,
            re.IGNORECASE,
        ):
            findings.append(f"{rel}:{lineno}: pip/python -m pip is toolchain bootstrap")
        if NPM_GLOBAL_RE.search(line):
            findings.append(f"{rel}:{lineno}: npm install -g is toolchain bootstrap")
        if CARGO_INSTALL_RE.search(line):
            findings.append(f"{rel}:{lineno}: cargo install is toolchain bootstrap")
        if RUSTUP_RE.search(line):
            findings.append(f"{rel}:{lineno}: rustup is toolchain bootstrap")
        if CURL_SH_RE.search(line):
            findings.append(f"{rel}:{lineno}: curl|sh toolchain bootstrap")
        if TOOLCHAIN_DOWNLOAD_RE.search(line):
            findings.append(f"{rel}:{lineno}: downloaded toolchain/upstream bootstrap")
        if APT_INSTALL_RE.search(line) and not apt_install_allowed(line):
            findings.append(f"{rel}:{lineno}: apt install of distro/toolchain packages")
        if FORBIDDEN_CONTAINER_RE.search(line) and not ALLOWED_IMAGE_RE.search(line):
            if re.search(r"\b(?:container:|docker\s+run|ubuntu_image:|image:)\b", line) or "ubuntu:" in line or "ros:" in line:
                findings.append(
                    f"{rel}:{lineno}: stock ubuntu:/ros: image; use ghcr.io/xgc-team/xgc2-images/xgc2-build-*"
                )
    return findings


def automation_files(root: Path) -> list[Path]:
    files: set[Path] = set()
    wf = root / ".github" / "workflows"
    if wf.is_dir():
        files.update(
            path
            for path in wf.iterdir()
            if path.suffix in {".yml", ".yaml"} and path.is_file()
        )
    scripts = root / ".xgc2" / "scripts"
    if scripts.is_dir():
        files.update(
            path
            for path in scripts.rglob("*")
            if path.is_file()
            and path.suffix in {".sh", ".bash"}
            and AUTOMATION_SCRIPT_RE.match(path.name)
        )
    manifest = root / "manifest"
    if manifest.is_dir():
        files.update(
            path
            for path in manifest.rglob("*")
            if path.is_file() and path.suffix in {".json", ".yml", ".yaml"}
        )
    integration_lock = root / ".xgc2" / "integration-lock.json"
    if integration_lock.is_file():
        files.add(integration_lock)
    return sorted(files)


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    files = automation_files(root)
    if not files:
        print(f"no product automation under {root}; nothing to check")
        return 0
    findings: list[str] = []
    for path in files:
        findings.extend(scan_file(path))
    if not any(
        ALLOWED_IMAGE_RE.search(path.read_text(encoding="utf-8", errors="replace"))
        for path in files
    ):
        findings.append(
            f"{root}: product automation does not reference an XGC2-owned image"
        )
    if findings:
        print("CI bootstrap gate failed. Use an XGC2 build image and delete these steps:", file=sys.stderr)
        print(
            "  container: ghcr.io/xgc-team/xgc2-images/xgc2-build-<ubuntu>-<layer>[-<ros>]:1.0.0",
            file=sys.stderr,
        )
        print(
            "Allowed: pnpm install / npm ci / yarn install / bun install / uv sync of the repo lockfile.",
            file=sys.stderr,
        )
        print(
            "Forbidden: apt of toolchain/distro packages, pip, setup-node/python/go/uv/bun, rustup, npm -g, curl|sh.",
            file=sys.stderr,
        )
        print(
            "Allowed apt: local .deb under test, and published xgc2-* / libxgc2-* / ros-*-xgc2-*.",
            file=sys.stderr,
        )
        for item in findings:
            print(item, file=sys.stderr)
        return 1
    print(f"CI bootstrap gate passed ({len(files)} automation file(s)).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
