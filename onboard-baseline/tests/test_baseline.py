#!/usr/bin/env python3
"""Offline shell-boundary tests, NOT evidence of a working ROS image/robot.

Only a temporary copy's absolute OS/ROS paths and clean PATH are redirected.
External package/ROS commands are explicit fakes; Bash control flow is real.
Run: python3 -m unittest discover -s onboard-baseline/tests -v
"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get("BASELINE_UNDER_TEST", REPO / "onboard-baseline.sh"))
BASELINES = json.loads((REPO / "baselines.json").read_text())
PROFILES = BASELINES["profiles"]

# These commands cannot install software, access hardware, or connect to ROS.
FAKE = r'''
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ["TEST_ROOT"])
state_path = root / "state.json"
state = json.loads(state_path.read_text())
def log():
    with (root / "commands.jsonl").open("a") as out:
        out.write(json.dumps([name] + args) + "\n")
def save():
    state_path.write_text(json.dumps(state))
if name in ("python2", "python3"):
    if args and args[0] == "-c":
        log()
        sys.exit(int(os.environ.get("TEST_IMPORT_FAIL", "0")))
    os.execv(sys.executable, [sys.executable, "-S"] + args)
if name == "id":
    print(os.environ.get("TEST_UID", "0") if args == ["-u"] else "robot-user")
elif name == "dpkg":
    assert args == ["--print-architecture"], args
    if os.environ.get("TEST_ARCH_FAIL"): sys.exit(1)
    print(os.environ.get("TEST_ARCH", "amd64"))
elif name == "dpkg-query":
    package = args[-1]
    if package not in state["installed"]: sys.exit(1)
    fmt = args[1]
    if "Status" in fmt:
        print(state["installed"][package], end="")
        sys.exit(int(os.environ.get("TEST_QUERY_FAIL", "0")))
    elif "manual" in fmt:
        print("manual\t%s\t1.0\t%s" % (package, os.environ.get("TEST_ARCH", "amd64")))
    else:
        print("1.0", end="")
elif name == "apt-get":
    log()
    if os.environ.get("TEST_APT_FAIL") == args[0]: sys.exit(42)
    if args[0] == "install":
        for package in args[args.index("--no-install-recommends") + 1:]:
            state["installed"][package] = "install ok installed"
        save()
        p = root / "bin/python3"
        if not p.exists(): p.symlink_to("fake")
elif name == "apt-mark":
    assert args == ["showmanual"]
    print("\n".join(sorted(state["installed"])))
elif name == "install-ros-apt-source.sh":
    log()
elif name == "rosversion":
    assert args == ["-d"]
    print(os.environ.get("TEST_ROS_DISTRO", os.environ.get("ROS_DISTRO", "unset")))
elif name == "rospack":
    assert args[0] == "find"
    log()
    if os.environ.get("TEST_ROSPACK_FAIL") == args[1]: sys.exit(1)
    assert os.environ.get("TEST_SOURCED") == "1", "setup.bash was not sourced"
    assert not os.environ.get("PYTHONHOME"), "caller Python leaked"
    home = pathlib.Path(os.environ["ROS_HOME"])
    (home / "rospack_cache").write_text("cache")
    print(str(root / "ros" / os.environ["ROS_DISTRO"] / "share" / args[1]))
elif name == "ldd":
    log()
    if os.environ.get("TEST_LDD_FAIL"): sys.exit(1)
    print("libdependency.so => not found" if os.environ.get("TEST_LDD_MISSING") else "libdependency.so => /lib/libdependency.so")
elif name == "geographiclib-get-geoids":
    log()
    if os.environ.get("TEST_GEOID_DOWNLOAD_FAIL"): sys.exit(1)
    path = pathlib.Path(args[1]) / "geoids/egm96-5.pgm"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("valid-geoid")
elif name == "GeoidEval":
    log()
    assert args == ["-d", str(root / "geoids"), "-n", "egm96-5"], args
    assert sys.stdin.read() == "0 0\n"
    if (root / "geoids/egm96-5.pgm").read_text() != "valid-geoid": sys.exit(1)
    print("17.1616")
else:
    raise AssertionError("unexpected command: " + name)
'''


class BaselineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="w06-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        fake = self.bin / "fake"
        fake.write_text("#!" + sys.executable + " -S\n" + FAKE)
        fake.chmod(0o755)
        for cmd in ("python3", "python2", "id", "dpkg", "dpkg-query", "apt-get",
                    "apt-mark", "rosversion", "rospack", "ldd", "GeoidEval",
                    "geographiclib-get-geoids", "install-ros-apt-source.sh"):
            (self.bin / cmd).symlink_to("fake")
        for cmd in ("bash", "dirname", "mktemp", "rm", "sort", "cat"):
            (self.bin / cmd).symlink_to("/bin/" + cmd)
        self.script = self.root / "onboard-baseline.sh"
        text = SOURCE.read_text()
        # Deliberate fixture-only path remapping. Production gains no bypass flags.
        for old, new in (("/opt/ros/", str(self.root / "ros") + "/"),
                         ("/usr/share/GeographicLib/geoids", str(self.root / "geoids")),
                         ("/usr/share/GeographicLib", str(self.root)),
                         ("/etc/apt/", str(self.root / "etc-apt") + "/"),
                         ("/etc/xgc2/", str(self.root / "etc-xgc2") + "/"),
                         ("/usr/share/xgc2-agent/", str(self.root / "agent") + "/")):
            text = text.replace(old, new)
        text = text.replace("export PATH=/usr/sbin:/usr/bin:/sbin:/bin",
                            "export PATH=" + shlex.quote(str(self.bin) + ":/usr/bin:/bin"))
        self.script.write_text(text)
        self.script.chmod(0o755)
        self.config = self.root / "baselines.json"
        self.config.write_text(json.dumps(BASELINES))
        (self.root / "install-ros-apt-source.sh").symlink_to(self.bin / "fake")
        all_packages = {p: "install ok installed" for v in PROFILES.values() for p in v["packages"]}
        self.state = {"installed": all_packages}
        self.save()
        self.env = {"PATH": str(self.bin) + ":/usr/bin:/bin", "HOME": str(self.root / "home"),
                    "TEST_ROOT": str(self.root), "TMPDIR": str(self.root / "tmp"),
                    "ONBOARD_BASELINE_OS_RELEASE": str(self.root / "os-release")}
        (self.root / "home").mkdir()
        (self.root / "tmp").mkdir()
        for distro in ("noetic", "melodic"):
            prefix = self.root / "ros" / distro
            prefix.mkdir(parents=True)
            (prefix / "setup.bash").write_text("export ROS_DISTRO=%s\nexport TEST_SOURCED=1\n" % distro)
            for name in ("rosout/rosout", "mavros/mavros_node", "libmavros_plugins.so", "libmavros_extras.so"):
                path = prefix / "lib" / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("fixture ELF; ldd is mocked")
                path.chmod(0o755)
        (self.root / "geoids").mkdir()
        self.geoid = self.root / "geoids/egm96-5.pgm"
        self.geoid.write_text("valid-geoid")
        self.os_for("fs150-focal-noetic")

    def save(self):
        (self.root / "state.json").write_text(json.dumps(self.state))

    def os_for(self, profile, os_id="ubuntu"):
        p = PROFILES[profile]
        (self.root / "os-release").write_text('ID=%s\nVERSION_CODENAME=%s\nVERSION_ID="%s"\n' %
                                             (os_id, p["ubuntuCodename"], p["ubuntuVersionId"]))

    def run_script(self, *args, code=0, **env):
        result = subprocess.run(["/bin/bash", str(self.script)] + list(args), env=dict(self.env, **env),
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result

    def commands(self, name=None):
        path = self.root / "commands.jsonl"
        rows = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [r for r in rows if name is None or r[0] == name]

    def test_all_profiles_both_architectures_clean_noninteractive(self):
        for profile in PROFILES:
            self.os_for(profile)
            for arch in ("amd64", "arm64"):
                with self.subTest(profile=profile, arch=arch):
                    self.run_script("check", "--profile", profile, TEST_ARCH=arch, TEST_UID="1000")
        self.assertFalse(self.commands("apt-get"))

    def test_unknown_profile_fails_before_mutation(self):
        self.run_script("apply", "--profile", "not-a-profile", code=2)
        self.assertFalse(self.commands())

    def test_malformed_or_partial_profile_is_not_evaled(self):
        for content in ("{", '{"profiles": {}}', '{"profiles": {"broken": {"ubuntuCodename": "focal"}}}'):
            self.config.write_text(content)
            self.run_script("apply", "--profile", "broken", code=2)
        self.assertFalse(self.commands())

    def test_empty_packages_are_rejected(self):
        doc = json.loads(self.config.read_text())
        doc["profiles"]["fs150-focal-noetic"]["packages"] = []
        self.config.write_text(json.dumps(doc))
        self.run_script("apply", "--profile", "fs150-focal-noetic", code=2)

    def test_missing_option_value_is_usage_error(self):
        for args in (("check", "--profile"), ("check", "--profile", "--user", "robot"),
                     ("install-agent", "--user"), ("manualdiff", "--before")):
            with self.subTest(args=args): self.run_script(*args, code=2)

    def test_wrong_os_version_or_id(self):
        self.os_for("scout-bionic-melodic")
        self.run_script("apply", "--profile", "fs150-focal-noetic", code=3)
        self.os_for("fs150-focal-noetic", os_id="debian")
        self.run_script("apply", "--profile", "fs150-focal-noetic", code=3)
        self.assertFalse(self.commands())

    def test_missing_os_fields_cannot_use_inherited_values(self):
        (self.root / "os-release").write_text("ID=ubuntu\n")
        self.run_script("apply", "--profile", "fs150-focal-noetic", code=3,
                        VERSION_ID="20.04", VERSION_CODENAME="focal")

    def test_unsupported_or_unreadable_architecture(self):
        self.run_script("apply", "--profile", "fs150-focal-noetic", code=3, TEST_ARCH="armhf")
        self.run_script("apply", "--profile", "fs150-focal-noetic", code=3, TEST_ARCH_FAIL="1")
        self.assertFalse(self.commands())

    def test_missing_and_half_configured_packages(self):
        for status in (None, "install ok unpacked", "install reinstreq half-installed"):
            self.state["installed"].pop("curl", None)
            if status: self.state["installed"]["curl"] = status
            self.save()
            self.run_script("check", "--profile", "fs150-focal-noetic", code=4)
        self.assertFalse(self.commands("apt-get"))

    def test_dpkg_query_failure_is_not_installed(self):
        self.run_script("check", "--profile", "fs150-focal-noetic", code=4, TEST_QUERY_FAIL="1")

    def test_installed_held_packages_are_not_reinstalled(self):
        self.state["installed"]["curl"] = "hold ok installed"
        self.save()
        self.run_script("apply", "--profile", "fs150-focal-noetic")
        self.assertFalse(self.commands("apt-get"))

    def test_setup_is_required(self):
        (self.root / "ros/noetic/setup.bash").unlink()
        self.run_script("check", "--profile", "fs150-focal-noetic", code=4)

    def test_broken_setup_and_nonexecutable_runtime(self):
        setup = self.root / "ros/noetic/setup.bash"
        original = setup.read_text()
        setup.write_text("return 1\n")
        self.run_script("check", "--profile", "fs150-focal-noetic", code=4)
        setup.write_text(original)
        for name in ("rosout/rosout", "mavros/mavros_node"):
            path = self.root / "ros/noetic/lib" / name
            path.chmod(0o644)
            self.run_script("check", "--profile", "fs150-focal-noetic", code=4)
            path.chmod(0o755)

    def test_wrong_ros_distro_is_rejected(self):
        self.run_script("check", "--profile", "fs150-focal-noetic", code=4, TEST_ROS_DISTRO="melodic")

    def test_missing_ros_packages_and_python_imports(self):
        for package in ("roscpp", "rospy", "roslaunch", "mavros", "mavros_extras"):
            with self.subTest(package=package):
                self.run_script("check", "--profile", "fs150-focal-noetic", code=4, TEST_ROSPACK_FAIL=package)
        self.run_script("check", "--profile", "fs150-focal-noetic", code=4, TEST_IMPORT_FAIL="1")

    def test_runtime_missing_file_or_unresolved_libraries(self):
        for key in ("TEST_LDD_FAIL", "TEST_LDD_MISSING"):
            self.run_script("check", "--profile", "fs150-focal-noetic", code=4, **{key: "1"})
        (self.root / "ros/noetic/lib/libmavros_extras.so").unlink()
        self.run_script("check", "--profile", "fs150-focal-noetic", code=4)

    def test_geoid_missing_or_corrupt_is_rejected(self):
        self.geoid.unlink()
        self.run_script("check", "--profile", "fs150-focal-noetic", code=4)
        self.geoid.write_text("not a PGM")
        self.run_script("check", "--profile", "fs150-focal-noetic", code=4)

    def test_check_does_not_use_shell_overlay_or_persist_cache(self):
        sentinel = self.root / "home/.bashrc"
        sentinel.write_text("do not modify\n")
        self.run_script("check", "--profile", "fs150-focal-noetic", ROS_DISTRO="wrong",
                        ROS_PACKAGE_PATH="/stale/overlay", CMAKE_PREFIX_PATH="/stale/overlay")
        self.assertEqual(sentinel.read_text(), "do not modify\n")
        self.assertFalse(list((self.root / "tmp").iterdir()))
        self.assertFalse((self.root / "home/.ros").exists())
        self.assertFalse(self.commands("apt-get"))

    def test_apply_requires_root(self):
        self.run_script("apply", "--profile", "fs150-focal-noetic", code=1, TEST_UID="1000")
        self.assertFalse(self.commands())

    def test_apply_installs_only_missing_then_second_apply_is_noop(self):
        self.state["installed"].pop("curl")
        self.save()
        sentinel = self.root / "etc-xgc2/agent.env"
        sentinel.parent.mkdir()
        sentinel.write_text("XGC_AGENT_ID=existing-robot\n")
        self.geoid.unlink()
        self.run_script("apply", "--profile", "fs150-focal-noetic")
        first = self.commands("apt-get")
        self.assertEqual(first, [["apt-get", "update"], ["apt-get", "install", "-y", "--no-install-recommends", "curl"]])
        self.run_script("apply", "--profile", "fs150-focal-noetic")
        self.assertEqual(self.commands("apt-get"), first)
        self.assertEqual(len(self.commands("geographiclib-get-geoids")), 1)
        self.assertEqual(sentinel.read_text(), "XGC_AGENT_ID=existing-robot\n")

    def test_failed_apt_or_download_never_reports_applied(self):
        self.state["installed"].pop("curl")
        self.save()
        for action in ("update", "install"):
            result = self.run_script("apply", "--profile", "fs150-focal-noetic", code=42, TEST_APT_FAIL=action)
            self.assertNotIn("applied fs150", result.stdout)
        self.geoid.unlink()
        result = self.run_script("apply", "--profile", "fs150-focal-noetic", code=1, TEST_GEOID_DOWNLOAD_FAIL="1")
        self.assertNotIn("applied fs150", result.stdout)

    def test_apply_cannot_hide_runtime_load_failure(self):
        self.run_script("apply", "--profile", "fs150-focal-noetic", code=4, TEST_IMPORT_FAIL="1")

    def test_python2_bootstrap_route_only_for_apply(self):
        # python2 shim executes the JSON parser using this Python 3 interpreter.
        # This tests selection/installation flow, NOT real Python 2 compatibility.
        (self.bin / "python3").unlink()
        self.state["installed"].pop("python3")
        self.save()
        self.os_for("scout-bionic-melodic")
        self.run_script("check", "--profile", "scout-bionic-melodic", code=2, PATH=str(self.bin))
        self.run_script("apply", "--profile", "scout-bionic-melodic", PATH=str(self.bin))
        self.assertEqual(self.commands("apt-get")[-1][-1], "python3")

    def test_agent_metadata_parse_failure_is_not_masked(self):
        self.config.write_text("{}")
        self.run_script("install-agent", "--user", "robot", code=2)
        self.assertFalse(self.commands())

    def test_snapshot_and_manualdiff_preserve_existing_format(self):
        result = self.run_script("snapshot", "--profile", "fs150-focal-noetic")
        self.assertIn("profile=fs150-focal-noetic os=focal ros=noetic arch=amd64", result.stdout)
        self.assertIn("manual\tcurl\t1.0\tamd64", result.stdout)
        before, after = self.root / "before", self.root / "after"
        before.write_text(result.stdout)
        after.write_text(result.stdout)
        self.run_script("manualdiff", "--before", str(before), "--after", str(after))
        after.write_text(result.stdout + "manual\tnew-package\t1\tamd64\n")
        changed = self.run_script("manualdiff", "--before", str(before), "--after", str(after), code=1)
        self.assertIn("manualdiff removed=0 added=1", changed.stdout)
        self.assertFalse(self.commands("apt-get"))


class DockerContractTests(unittest.TestCase):
    def test_builds_apply_then_check_as_existing_robot_user(self):
        users = dict(zip(PROFILES, ("marvsmart", "agilex", "nvidia", "wheeltec")))
        for profile, user in users.items():
            with self.subTest(profile=profile):
                path = REPO.parent / "apps" / ("onboard-sim-" + profile) / "Dockerfile"
                text = path.read_text()
                self.assertIn("ENV ONBOARD_BASELINE_USER=" + user, text)
                self.assertIn("onboard-baseline.sh apply --profile " + profile, text)
                self.assertIn('runuser -u "$ONBOARD_BASELINE_USER" --', text)
                self.assertIn('onboard-baseline.sh check --profile "$ONBOARD_BASELINE_PROFILE"', text)
                self.assertNotIn("apt-get install", text)
                self.assertNotIn("install-sitl", text)


if __name__ == "__main__":
    unittest.main()
