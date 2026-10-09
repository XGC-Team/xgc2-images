#!/usr/bin/env python3
"""Build the pristine upstream peers used by the existing VRPN interoperability gate."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def run(*args, cwd=None):
    subprocess.run([str(value) for value in args], cwd=cwd, check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--prefix", type=Path, required=True)
    args = parser.parse_args()
    work, prefix = args.work_dir.resolve(), args.prefix.resolve()
    if prefix == Path("/") or str(prefix).startswith(("/usr", "/lib", "/etc", "/opt")):
        parser.error("a private build prefix is required")
    lock_bytes = (Path(__file__).resolve().parent / "sources.lock.json").read_bytes()
    spec = json.loads(lock_bytes)["vrpn"]
    source, build = work / "vrpn-src", work / "vrpn-build"
    work.mkdir(parents=True, exist_ok=True)
    run("git", "clone", "--no-checkout", "--filter=blob:none", spec["url"], source)
    run("git", "checkout", "--detach", spec["commit"], cwd=source)
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if actual != spec["commit"] or subprocess.check_output(["git", "status", "--porcelain"], cwd=source):
        raise RuntimeError("pristine VRPN source revision mismatch")
    run("cmake", "-S", source, "-B", build, "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_TESTING=OFF", "-DVRPN_INSTALL=OFF",
        "-DVRPN_BUILD_CLIENTS=ON", "-DVRPN_BUILD_SERVERS=ON",
        "-DVRPN_BUILD_CLIENT_LIBRARY=ON", "-DVRPN_BUILD_SERVER_LIBRARY=ON",
        "-DVRPN_BUILD_PYTHON=OFF", "-DVRPN_BUILD_PYTHON_HANDCODED_2X=OFF",
        "-DVRPN_BUILD_PYTHON_HANDCODED_3X=OFF", "-DVRPN_BUILD_JAVA=OFF")
    run("cmake", "--build", build, "--target", "vrpn_server", "vrpn_print_devices", "--parallel", "2")
    for part in ("bin", "include", "lib"):
        (prefix / part).mkdir(parents=True, exist_ok=True)
    for name, location in (("vrpn_server", "server_src"), ("vrpn_print_devices", "client_src")):
        shutil.copy2(build / location / name, prefix / "bin" / name)
    for header in source.glob("vrpn*.h"):
        shutil.copy2(header, prefix / "include" / header.name)
    shutil.copy2(build / "vrpn_Configure.h", prefix / "include" / "vrpn_Configure.h")
    shutil.copy2(source / "quat" / "quat.h", prefix / "include" / "quat.h")
    shutil.copy2(source / "server_src" / "vrpn_Generic_server_object.h", prefix / "include" / "vrpn_Generic_server_object.h")
    for location in ("libvrpn.a", "libvrpnserver.a", "quat/libquat.a"):
        shutil.copy2(build / location, prefix / "lib" / Path(location).name)
    (prefix / "xgc2-vrpn-official.json").write_text(json.dumps({
        "source_lock_sha256": hashlib.sha256(lock_bytes).hexdigest(),
        "commit": actual, "version": spec["version"], "patched": False,
        "tools": ["vrpn_server", "vrpn_print_devices"],
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
