#!/usr/bin/env python3
"""Execute the unmodified-path entrypoint in disposable Linux chroots.

Run as root: python3 -m unittest discover -s onboard-baseline/tests -v
Requires Python 3.8+, Bash, util-linux runuser, coreutils, getent, ldd and pam_permit.so.
No Docker, network, apt, host account changes or host /etc writes. The real
runuser changes uid/gid; install-agent, the Agent, PAM policy and ROS setup
are test fixtures. These tests do NOT prove DEB compatibility, production PAM
policy or Agent/Core handshake. Use only an isolated Linux test runner.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ENTRYPOINT = Path(__file__).resolve().parents[1] / "image-entrypoint.sh"
ROBOT = "robot"
UID = 1234
GID = 1234
DATA = "/var/lib/xgc2-agent"
MANAGED = "/var/lib/xgc2-managed"
AGENT = "/usr/lib/xgc2/xgc-agent"
INSTALLER = "/opt/xgc2/onboard-baseline/onboard-baseline.sh"

# Deliberately records entry before attempting any user writes. A failed Agent
# process must not be mistaken for the entrypoint rejecting invalid inputs.
AGENT_FIXTURE = r'''#!/bin/bash
set -eu
printf 'started\n' > "$XGC_AGENT_DATA_DIR/agent-started"
printf 'UID=%s\nGID=%s\nWHOAMI=%s\nCWD=%s\n' "$(id -u)" "$(id -g)" "$(whoami)" "$PWD"
env
printf 'home\n' > "$HOME/home-probe"
printf 'workspace\n' > "$XGC_AGENT_MANAGED_ROOT/workspace-probe"
exit "${TEST_AGENT_EXIT:-0}"
'''
INSTALLER_FIXTURE = r'''#!/bin/bash
set -eu
printf '%s\n' "$@" >> /install-calls
printf '%s\n' "$ONBOARD_BASELINE_AGENT_DEB" >> /install-debs
[[ -r "$ONBOARD_BASELINE_AGENT_DEB" ]] || exit 44
[[ ${TEST_INSTALL_EXIT:-0} == 0 ]] || exit "$TEST_INSTALL_EXIT"
[[ ${TEST_INSTALL_NO_BINARY:-0} == 0 ]] || exit 0
cp /fixtures/agent /usr/lib/xgc2/xgc-agent
'''
PACKAGE_ENV = '''XGC_AGENT_ID=agent-01
XGC_AGENT_DISPLAY_NAME="Package Agent"
XGC_AGENT_GRPC_ADDR=:9090
XGC_AGENT_ADVERTISED_ENDPOINT=127.0.0.1:9090
XGC_CORE_ENDPOINT=127.0.0.1:9092
XGC_AGENT_DATA_DIR=/var/lib/xgc2-agent
XGC_AGENT_MANAGED_ROOT=/var/lib/xgc2-managed
XGC_PROCESS_DEFINITION_PLUGINS=/usr/share/xgc2-agent/process-definitions
'''


def write(root, path, content, mode=0o644):
    dest = root / path.lstrip("/")
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(content, encoding="utf-8")
    dest.chmod(mode)
    return dest


def copy_binary(root, path):
    """Copy a system ELF and ldd-resolved libraries, retaining loader paths."""
    path = Path(path)
    dest = root / str(path).lstrip("/")
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, dest)
    result = subprocess.run(["ldd", str(path)], capture_output=True, text=True,
                            check=True, timeout=10)
    for lib in re.findall(r"(/[^\s()]+)", result.stdout):
        target = root / lib.lstrip("/")
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(lib, target)


class EntrypointTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # This is an explicit environment requirement, not a silently green skip.
        if os.geteuid() != 0:
            raise RuntimeError("run this suite as root in an isolated Linux test runner")
        cls.base_tmp = tempfile.TemporaryDirectory(prefix="w07-entrypoint-base-")
        cls.addClassCleanup(cls.base_tmp.cleanup)
        cls.base = Path(cls.base_tmp.name)
        cls.base.chmod(0o755)
        commands = ["bash", "env", "id", "getent", "cut", "install", "chmod",
                    "runuser", "test", "whoami", "cp", "true"]
        for command in commands:
            source = shutil.which(command)
            if source is None:
                raise RuntimeError("missing required executable: " + command)
            copy_binary(cls.base, source)
        # /bin/bash is used by the actual entrypoint's user-directory check.
        if not (cls.base / "bin/bash").exists():
            copy_binary(cls.base, "/bin/bash")
        modules = list(Path("/lib").glob("*/security/pam_permit.so"))
        modules += list(Path("/usr/lib").glob("*/security/pam_permit.so"))
        if not modules:
            raise RuntimeError("pam_permit.so is required for the isolated PAM fixture")
        pam = modules[0]
        copy_binary(cls.base, pam)
        # The PAM fixture permits only this chroot's root-runuser test. It is not
        # installed on the host and does not model production authentication.
        write(cls.base, "/etc/pam.d/runuser", "".join(
            "%s required %s\n" % (kind, pam) for kind in ("auth", "account", "session")))
        write(cls.base, "/etc/passwd", "root:x:0:0:root:/root:/bin/bash\n"
              "robot:x:1234:1234:Robot:/home/robot:/bin/bash\n")
        write(cls.base, "/etc/group", "root:x:0:\nrobot:x:1234:\n")
        write(cls.base, "/etc/nsswitch.conf", "passwd: files\ngroup: files\n")
        write(cls.base, "/etc/xgc2/agent.env", PACKAGE_ENV)
        write(cls.base, "/entrypoint.sh", ENTRYPOINT.read_text(encoding="utf-8"), 0o755)
        write(cls.base, "/fixtures/agent", AGENT_FIXTURE, 0o755)
        write(cls.base, AGENT, AGENT_FIXTURE, 0o755)
        write(cls.base, INSTALLER, INSTALLER_FIXTURE, 0o755)
        write(cls.base, "/run/xgc2-install/xgc2-agent.deb", "local DEB fixture\n")
        write(cls.base, "/dev/null", "", 0o666)
        home = cls.base / "home/robot"
        home.mkdir(parents=True)
        os.chown(home, UID, GID)
        home.chmod(0o750)
        # Any accidental automatic install/build/systemd path fails loudly.
        for command in ("apt", "apt-get", "dpkg", "systemctl", "git", "make", "cmake", "cargo"):
            write(cls.base, "/usr/bin/" + command,
                  "#!/bin/bash\nprintf 'forbidden: %s\\n' \"$0\" >&2\nexit 97\n", 0o755)
        result = subprocess.run(["chroot", str(cls.base), "true"], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError("chroot is unavailable: " + result.stderr)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="w07-entrypoint-case-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "root"
        shutil.copytree(self.base, self.root)
        # copytree preserves mode, but not ownership.
        os.chown(self.root / "home/robot", UID, GID)
        self.env = {
            "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
            "ONBOARD_BASELINE_USER": ROBOT,
            "XGC_AGENT_ID": "xgc2e-experiment-a-robot",
            "XGC_CORE_ENDPOINT": "172.28.40.251:19102",
            "XGC_AGENT_ADVERTISED_ENDPOINT": "172.28.40.101:9090",
        }

    def launch(self, args=(), userspec=None):
        command = ["chroot"]
        if userspec:
            command.append("--userspec=" + userspec)
        return subprocess.run(command + [str(self.root), "/bin/bash", "/entrypoint.sh", *args],
                              env=self.env, text=True, capture_output=True, timeout=10)

    def success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)

    def rejected(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)
        self.assertFalse((self.root / DATA.lstrip("/") / "agent-started").exists(),
                         "Agent was launched before validation failed")

    def first_install(self):
        (self.root / AGENT.lstrip("/")).unlink()
        self.env["ONBOARD_BASELINE_AGENT_DEB"] = "/run/xgc2-install/xgc2-agent.deb"

    def test_existing_agent_runs_as_robot_with_writable_home_and_workspace(self):
        values = self.success(self.launch())
        for key, expected in {"UID": str(UID), "GID": str(GID), "WHOAMI": ROBOT,
                              "HOME": "/home/robot", "USER": ROBOT, "LOGNAME": ROBOT,
                              "CWD": DATA, "ROS_HOME": "/home/robot/.ros",
                              "ROS_LOG_DIR": "/home/robot/.ros/log"}.items():
            self.assertEqual(values[key], expected, key)
        for path in ("/home/robot/home-probe", MANAGED + "/workspace-probe"):
            self.assertEqual((self.root / path.lstrip("/")).stat().st_uid, UID)
        self.assertFalse((self.root / "install-calls").exists())

    def test_first_install_delegates_then_second_entry_skips_installer_without_deb(self):
        self.first_install()
        self.env["ONBOARD_BASELINE_PROFILE"] = "fs150-focal-noetic"
        values = self.success(self.launch())
        self.assertEqual((self.root / "install-calls").read_text(),
                         "install-agent\n--profile\nfs150-focal-noetic\n")
        self.assertEqual((self.root / "install-debs").read_text(),
                         "/run/xgc2-install/xgc2-agent.deb\n")
        self.assertEqual(values["XGC_AGENT_ID"], self.env["XGC_AGENT_ID"])
        self.assertEqual(values["XGC_CORE_ENDPOINT"], "172.28.40.251:19102")
        (self.root / "run/xgc2-install/xgc2-agent.deb").unlink()
        self.env["TEST_INSTALL_EXIT"] = "98"
        self.success(self.launch())
        self.assertEqual((self.root / "install-calls").read_text().count("install-agent"), 1)

    def test_world_install_does_not_require_a_robot_profile(self):
        self.first_install()
        self.env["XGC_AGENT_ID"] = "xgc2e-experiment-a-world"
        self.success(self.launch())
        self.assertEqual((self.root / "install-calls").read_text(), "install-agent\n")

    def test_missing_agent_without_deb_never_installs(self):
        (self.root / AGENT.lstrip("/")).unlink()
        self.rejected(self.launch(), "xgc2-agent is not installed")
        self.assertFalse((self.root / "install-calls").exists())

    def test_installer_failure_propagates_without_launch(self):
        self.first_install()
        self.env["TEST_INSTALL_EXIT"] = "42"
        result = self.launch()
        self.assertEqual(result.returncode, 42)
        self.assertFalse((self.root / DATA.lstrip("/") / "agent-started").exists())

    def test_installer_success_without_binary_is_rejected(self):
        self.first_install()
        self.env["TEST_INSTALL_NO_BINARY"] = "1"
        self.rejected(self.launch(), "xgc2-agent is not installed")

    def test_missing_deb_file_fails_without_launch(self):
        self.first_install()
        (self.root / "run/xgc2-install/xgc2-agent.deb").unlink()
        result = self.launch()
        self.assertEqual(result.returncode, 44)
        self.assertFalse((self.root / DATA.lstrip("/") / "agent-started").exists())

    def test_systemd_host_refuses_container_start(self):
        (self.root / "run/systemd/system").mkdir(parents=True)
        self.rejected(self.launch(), "systemd is running")
        self.assertFalse((self.root / "install-calls").exists())

    def test_explicit_command_remains_passthrough(self):
        self.env = {"PATH": self.env["PATH"]}
        (self.root / AGENT.lstrip("/")).unlink()
        result = self.launch(("/bin/bash", "-c", "printf 'diagnostic'; exit 23"))
        self.assertEqual(result.returncode, 23)
        self.assertEqual(result.stdout, "diagnostic")
        self.assertFalse((self.root / "install-calls").exists())

    def test_unknown_robot_user_fails(self):
        self.env["ONBOARD_BASELINE_USER"] = "missing-robot"
        self.rejected(self.launch(), "missing-robot")

    def test_nonroot_entrypoint_fails_explicitly(self):
        self.rejected(self.launch(userspec="1234:1234"), "entrypoint requires root")

    def test_package_placeholder_is_not_a_container_identity(self):
        del self.env["XGC_AGENT_ID"]
        self.rejected(self.launch(), "agent-01")

    def test_explicit_empty_identity_does_not_fall_back_to_package(self):
        self.env["XGC_AGENT_ID"] = ""
        self.rejected(self.launch(), "XGC_AGENT_ID")

    def test_empty_core_endpoint_is_rejected(self):
        self.env["XGC_CORE_ENDPOINT"] = ""
        self.rejected(self.launch(), "XGC_CORE_ENDPOINT")

    def test_empty_advertised_endpoint_is_rejected(self):
        self.env["XGC_AGENT_ADVERTISED_ENDPOINT"] = ""
        self.rejected(self.launch(), "XGC_AGENT_ADVERTISED_ENDPOINT")

    def test_configured_conffile_can_supply_identity_without_caller_overrides(self):
        write(self.root, "/etc/xgc2/agent.env", PACKAGE_ENV.replace("agent-01", "configured-agent"))
        for key in ("XGC_AGENT_ID", "XGC_CORE_ENDPOINT", "XGC_AGENT_ADVERTISED_ENDPOINT"):
            del self.env[key]
        self.assertEqual(self.success(self.launch())["XGC_AGENT_ID"], "configured-agent")

    def test_caller_values_survive_conffile_and_ros_setup(self):
        overrides = {
            "XGC_AGENT_ID": "xgc2e-experiment-b-same-asset",
            "XGC_CORE_ENDPOINT": "172.28.42.251:29102",
            "XGC_PROCESS_DEFINITION_PLUGINS": "/opt/robot/catalog",
            "XGC_ADAPTER_CUSTOM_ENDPOINT": "caller-value",
            "XGC_AGENT_IDENTITY_KEY": DATA + "/identity.key",
            "ROS_MASTER_URI": "http://172.28.43.100:11311",
            "ROS_IP": "172.28.43.101",
            "GAZEBO_MASTER_URI": "http://172.28.43.100:11345",
        }
        assignments = "".join("export %s=package-value\n" % key for key in overrides)
        write(self.root, "/etc/xgc2/agent.env", PACKAGE_ENV + assignments)
        write(self.root, "/opt/ros/test/setup.bash", assignments)
        self.env.update(overrides, ROS_DISTRO="test")
        values = self.success(self.launch())
        for key, value in overrides.items():
            self.assertEqual(values[key], value, key)

    def test_explicit_empty_catalog_is_preserved(self):
        self.env["XGC_PROCESS_DEFINITION_PLUGINS"] = ""
        self.assertEqual(self.success(self.launch())["XGC_PROCESS_DEFINITION_PLUGINS"], "")

    def test_home_not_owned_by_robot_is_not_silently_reowned(self):
        home = self.root / "home/robot"
        os.chown(home, 0, 0)
        home.chmod(0o755)
        self.rejected(self.launch(), "/home/robot")
        self.assertEqual(home.stat().st_uid, 0)

    def test_custom_ros_directory_must_be_searchable_not_only_writable(self):
        custom = self.root / "custom-ros"
        custom.mkdir()
        os.chown(custom, UID, GID)
        custom.chmod(0o600)
        self.env.update(ROS_HOME="/custom-ros", ROS_LOG_DIR="/custom-ros")
        self.rejected(self.launch(), "/custom-ros")
        self.assertEqual(custom.stat().st_mode & 0o777, 0o600)

    def test_custom_missing_ros_directory_fails_with_path(self):
        self.env.update(ROS_HOME="/missing-ros", ROS_LOG_DIR="/missing-ros/log")
        self.rejected(self.launch(), "/missing-ros")
        self.assertFalse((self.root / "missing-ros").exists())

    def test_agent_failure_is_not_reported_as_success(self):
        self.env["TEST_AGENT_EXIT"] = "17"
        self.assertEqual(self.launch().returncode, 17)


if __name__ == "__main__":
    unittest.main(verbosity=2)
