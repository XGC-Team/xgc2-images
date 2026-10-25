#!/usr/bin/env python3
"""Argv smoke for build-local-image.sh. Docker is a PATH stub. No image build."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
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
    assert os.path.isfile(os.path.join(args[args.index("--build-context") + 1].split("=", 1)[1], "onboard-baseline", "baselines.json"))
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
        context = self.root / 'context/onboard-baseline'
        context.mkdir(parents=True)
        (context / 'baselines.json').write_text('{}')
        python = stub_dir / 'python3'
        python.write_text('#!/bin/sh\ncase "$1" in */scripts/tool-scripts-context.py) printf "%s\\n" "' + str(context.parent) + '";; *) exec "' + sys.executable + '" "$@";; esac\n')
        python.chmod(0o755)
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

    def test_builds_each_clean_profile_with_a_stable_tag(self):
        for profile in ('fs150-focal-noetic', 'scout-bionic-melodic', 'scout-focal-noetic', 'wheeltec-bionic-melodic'):
            result = self.run_image(profile, 'linux/amd64')
            self.assertEqual(result.returncode, 0, result.stderr)
            build = self.builds()[-1]
            self.assertIn('onboard-sim-' + profile + ':latest', build)
            self.assertIn('--pull', build)
            self.assertNotIn('--target', build)

    def test_product_inputs_cannot_contaminate_the_base(self):
        for variable in ('ONBOARD_AGENT_DEB', 'ONBOARD_BASELINE_AGENT_VERSION', 'ONBOARD_BASELINE_XSIM_VERSION'):
            self.env[variable] = 'candidate'
            result = self.run_image('fs150-focal-noetic')
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertFalse(self.log.exists())
            self.env.pop(variable)
        result = self.run_image('fs150-focal-noetic', 'linux/amd64', '--with-xsim')
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.log.exists())

    def test_rejects_wrong_architecture_after_build(self):
        self.env['STUB_PLATFORM'] = 'linux/arm64'
        result = self.run_image('fs150-focal-noetic', 'linux/amd64')
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
