#!/usr/bin/env python3
"""Argv smoke for build-local-image.sh. Docker is a PATH stub. No image build."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest

IMAGES = Path(__file__).resolve().parents[2]
SCRIPT = IMAGES / "onboard-baseline" / "build-local-image.sh"
DOCKERFILE = IMAGES / "apps" / "onboard-sim-fs150-focal-noetic" / "Dockerfile"

DOCKER_STUB = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["STUB_LOG"], "a") as handle:
    handle.write(json.dumps(args) + "\n")
if args[:2] == ["image", "inspect"]:
    fmt = args[args.index("--format") + 1]
    if "Os" in fmt:
        sys.stdout.write(os.environ.get("STUB_PLATFORM", "linux/amd64") + "\n")
    else:
        sys.stdout.write("tag=local id=sha256:abc\n")
    raise SystemExit(0)
if args[:1] == ["build"]:
    if "--build-context" in args:
        value = args[args.index("--build-context") + 1]
        context = value.split("=", 1)[1]
        open(os.path.join(context, "xgc2-agent.deb"), "rb").read(1)
    raise SystemExit(0)
raise SystemExit("unexpected docker argv")
'''


def write_deb(directory, package, architecture, version="0.0.0-test"):
    control = directory / "DEBIAN"
    control.mkdir(parents=True)
    (control / "control").write_text(textwrap.dedent("""\
        Package: %s
        Version: %s
        Architecture: %s
        Maintainer: test <test@example.com>
        Description: fixture package
    """ % (package, version, architecture)))
    deb = directory.parent / ("%s_%s.deb" % (package, architecture))
    subprocess.run(
        ["dpkg-deb", "--build", str(directory), str(deb)],
        check=True, capture_output=True, text=True,
    )
    shutil.rmtree(directory)
    return deb


class LocalImageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.log = self.root / "docker.jsonl"
        stub_dir = self.root / "bin"
        stub_dir.mkdir()
        stub = stub_dir / "docker"
        stub.write_text(DOCKER_STUB)
        stub.chmod(0o755)
        self.env = os.environ.copy()
        self.env.pop("ONBOARD_AGENT_DEB", None)
        self.env.pop("ONBOARD_BASELINE_AGENT_VERSION", None)
        self.env.pop("ONBOARD_BASELINE_XSIM_VERSION", None)
        self.env["PATH"] = "%s:%s" % (stub_dir, self.env.get("PATH", ""))
        self.env["STUB_LOG"] = str(self.log)
        self.env["STUB_PLATFORM"] = "linux/amd64"

    def tearDown(self):
        self.tmp.cleanup()

    def run_image(self, profile, *extra):
        return subprocess.run(
            [str(SCRIPT), profile, *extra],
            env=self.env, text=True, capture_output=True,
        )

    def builds(self):
        rows = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [row for row in rows if row[:1] == ["build"]]

    def test_dockerfile_keeps_apt_as_the_default_stage(self):
        text = DOCKERFILE.read_text()
        self.assertIn("ARG AGENT_INSTALL=apt\n", text)
        self.assertIn("FROM baseline AS apt-agent\n", text)
        self.assertIn("FROM baseline AS source-agent\n", text)
        self.assertTrue(text.rstrip().endswith("FROM ${AGENT_INSTALL}-agent"))
        script = SCRIPT.read_text()
        self.assertNotIn("Workflows", script)
        self.assertNotIn("!<arch>", script)

    def test_fs150_without_a_deb_keeps_the_apt_build(self):
        result = self.run_image("fs150-focal-noetic", "linux/amd64")
        self.assertEqual(result.returncode, 0, result.stderr)
        argv = self.builds()
        self.assertEqual(len(argv), 1)
        self.assertNotIn("AGENT_INSTALL=source", argv[0])
        self.assertNotIn("--build-context", argv[0])
        self.assertNotIn("--target", argv[0])
        self.assertIn("--build-arg", argv[0])
        self.assertIn("ONBOARD_APT_MIRROR=%s" % os.environ.get(
            "ONBOARD_APT_MIRROR", "http://mirrors.ustc.edu.cn/ubuntu"), argv[0])
        self.assertIn("installs live xgc2-agent from APT", result.stdout)

    def test_fs150_xsim_variant_selects_the_same_target_on_each_architecture(self):
        for arch in ("amd64", "arm64"):
            with self.subTest(arch=arch):
                self.env["STUB_PLATFORM"] = "linux/" + arch
                self.env["ONBOARD_BASELINE_AGENT_VERSION"] = "0.1.0-11"
                result = self.run_image("fs150-focal-noetic", "linux/" + arch, "--with-xsim")
                self.assertEqual(result.returncode, 0, result.stderr)
                argv = self.builds()[-1]
                self.assertEqual(argv[argv.index("--target") + 1], "xsim-simulation")
                self.assertEqual(argv[argv.index("-t") + 1],
                                 "onboard-sim-fs150-focal-noetic:base-local-" + arch + "-xsim")
                self.assertIn("ONBOARD_BASELINE_AGENT_VERSION=0.1.0-11", argv)
                self.assertFalse(any(arg.startswith("ONBOARD_BASELINE_XSIM_VERSION=") for arg in argv))
                self.assertNotIn("--build-context", argv)
                self.assertNotIn("XSIM_PARENT_IMAGE", " ".join(argv))

    def test_xsim_variant_without_an_explicit_platform_is_still_named_by_architecture(self):
        result = self.run_image("fs150-focal-noetic", "--with-xsim")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("onboard-sim-fs150-focal-noetic:base-local-amd64-xsim", self.builds()[0])

    def test_explicit_xsim_version_changes_only_the_simulation_build_input(self):
        for version in ("1.4.0-4", "1.4.0-5"):
            self.env["ONBOARD_BASELINE_XSIM_VERSION"] = version
            result = self.run_image("fs150-focal-noetic", "linux/amd64", "--with-xsim")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("ONBOARD_BASELINE_XSIM_VERSION=" + version, self.builds()[-1])
        result = self.run_image("fs150-focal-noetic", "linux/amd64")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(arg.startswith("ONBOARD_BASELINE_XSIM_VERSION=") for arg in self.builds()[-1]))

    def test_xsim_option_does_not_enable_other_profiles_or_sitl(self):
        for profile in ("scout-focal-noetic", "scout-bionic-melodic",
                        "wheeltec-bionic-melodic", "fs150-focal-noetic-sitl"):
            with self.subTest(profile=profile):
                result = self.run_image(profile, "--with-xsim")
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(self.log.exists())

    def test_agent_version_argument_changes_the_apt_stage_build_input(self):
        for version in ("0.1.0-12", "0.1.0-13"):
            self.env["ONBOARD_BASELINE_AGENT_VERSION"] = version
            result = self.run_image("fs150-focal-noetic", "linux/amd64")
            self.assertEqual(result.returncode, 0, result.stderr)
            argv = self.builds()[-1]
            self.assertIn("ONBOARD_BASELINE_AGENT_VERSION=" + version, argv)
            self.assertNotIn("--target", argv)
        apt_stage = DOCKERFILE.read_text().split("FROM baseline AS apt-agent\n", 1)[1].split("FROM baseline AS source-agent\n", 1)[0]
        self.assertLess(apt_stage.index("ARG ONBOARD_BASELINE_AGENT_VERSION=0.1.0-13\n"), apt_stage.index("RUN "))

    def test_agent_override_is_forwarded_only_to_the_two_focal_profiles(self):
        self.env["ONBOARD_BASELINE_AGENT_VERSION"] = "0.1.0-13"
        self.env["STUB_PLATFORM"] = "linux/arm64"
        for profile in ("fs150-focal-noetic", "scout-focal-noetic",
                        "scout-bionic-melodic", "wheeltec-bionic-melodic"):
            with self.subTest(profile=profile):
                result = self.run_image(profile, "linux/arm64")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual("ONBOARD_BASELINE_AGENT_VERSION=0.1.0-13" in self.builds()[-1],
                                 profile.endswith("focal-noetic"))
                text = (IMAGES / "apps" / ("onboard-sim-" + profile) / "Dockerfile").read_text()
                self.assertIn("ARG ONBOARD_BASELINE_AGENT_VERSION=0.1.0-13\n", text)

    def test_another_profile_without_a_deb_stays_on_apt(self):
        result = self.run_image("scout-bionic-melodic")
        self.assertEqual(result.returncode, 0, result.stderr)
        argv = self.builds()[0]
        self.assertNotIn("AGENT_INSTALL=source", argv)
        self.assertNotIn("--build-context", argv)
        self.assertIn("apps/onboard-sim-scout-bionic-melodic/Dockerfile", " ".join(argv))

    def test_explicit_deb_selects_the_source_stage(self):
        deb = write_deb(self.root / "pkg", "xgc2-agent", "amd64")
        self.env["ONBOARD_AGENT_DEB"] = str(deb)
        result = self.run_image("fs150-focal-noetic", "linux/amd64")
        self.assertEqual(result.returncode, 0, result.stderr)
        argv = self.builds()[0]
        self.assertIn("AGENT_INSTALL=source", argv)
        context = argv[argv.index("--build-context") + 1]
        self.assertTrue(context.startswith("agentdeb="))
        self.assertFalse(Path(context.split("=", 1)[1]).exists())
        self.assertIn("installs the supplied source-built Agent", result.stdout)
        self.assertNotIn("Workflows", "\n".join(argv))

    def test_package_metadata_rejects_the_wrong_agent_before_docker(self):
        cases = [
            write_deb(self.root / "other", "not-agent", "amd64"),
            write_deb(self.root / "arm", "xgc2-agent", "arm64"),
        ]
        for deb in cases:
            with self.subTest(deb=deb.name):
                self.env["ONBOARD_AGENT_DEB"] = str(deb)
                result = self.run_image("fs150-focal-noetic", "linux/amd64")
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("must be xgc2-agent for amd64", result.stderr)
                self.assertFalse(self.log.exists())
        self.env["ONBOARD_AGENT_DEB"] = str(self.root / "missing.deb")
        missing = self.run_image("fs150-focal-noetic")
        self.assertEqual(missing.returncode, 2, missing.stderr)
        self.assertIn("not a file", missing.stderr)
        self.env["ONBOARD_AGENT_DEB"] = str(write_deb(self.root / "scout-pkg", "xgc2-agent", "amd64"))
        foreign = self.run_image("wheeltec-bionic-melodic")
        self.assertEqual(foreign.returncode, 2, foreign.stderr)
        self.assertIn("only the fs150 source candidate", foreign.stderr)
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
