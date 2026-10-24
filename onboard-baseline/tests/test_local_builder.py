#!/usr/bin/env python3
"""Source-only tests for the local project builder.

No image build, package install, or host interpreter registration.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tarfile
import tempfile
import textwrap
import time
import unittest

BASELINE = Path(__file__).resolve().parents[1]
SCRIPT = BASELINE / "build-local-project.sh"
PROFILES = json.loads((BASELINE / "baselines.json").read_text())["profiles"]
DEB = b"!<arch>\n"
EXPECTED_PROFILES = {
    "fs150-focal-noetic",
    "scout-bionic-melodic",
    "scout-focal-noetic",
    "wheeltec-bionic-melodic",
}


def write_script(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(body).lstrip("\n"))
    path.chmod(0o755)


def parse_mounts(argv):
    mounts = {}
    index = 0
    while index < len(argv):
        if argv[index] == "-v":
            parts = argv[index + 1].split(":")
            mode = parts.pop() if parts[-1] in {"ro", "rw"} else None
            dest = parts[-1]
            mounts[dest] = (":".join(parts[:-1]), mode)
            index += 2
        else:
            index += 1
    return mounts


ARGV_STUB = r'''#!/usr/bin/env python3
import json, os, sys
script = sys.stdin.buffer.read()
stdin_path = os.environ.get("STUB_STDIN")
if stdin_path:
    open(stdin_path, "wb").write(script)
args = sys.argv[1:]
open(os.environ["STUB_ARGV"], "w").write(json.dumps(args))
mounts = {}
index = 0
while index < len(args):
    if args[index] == "-v":
        parts = args[index + 1].split(":")
        if parts[-1] in ("ro", "rw"):
            parts = parts[:-1]
        mounts[parts[-1]] = ":".join(parts[:-1])
        index += 2
    else:
        index += 1
open(os.path.join(mounts["/output"], "pkg.deb"), "wb").write(b"!<arch>\n")
'''

EXEC_STUB = r'''#!/usr/bin/env python3
import json, os, sys, tempfile
script = sys.stdin.buffer.read()
args = sys.argv[1:]
record = os.environ.get("STUB_ARGV")
if record:
    open(record, "w").write(json.dumps(args))
stdin_path = os.environ.get("STUB_STDIN")
if stdin_path:
    open(stdin_path, "wb").write(script)
mounts = {}
env = {}
index = 0
while index < len(args):
    item = args[index]
    if item == "--entrypoint":
        index += 2
    elif item == "-v":
        parts = args[index + 1].split(":")
        if parts[-1] in ("ro", "rw"):
            parts = parts[:-1]
        mounts[parts[-1]] = ":".join(parts[:-1])
        index += 2
    elif item == "-e":
        key, value = args[index + 1].split("=", 1)
        env[key] = value
        index += 2
    elif item in ("--name", "--platform", "-w"):
        index += 2
    else:
        index += 1

def remap(value):
    if value in mounts:
        return mounts[value]
    for dest in sorted(mounts, key=len, reverse=True):
        prefix = dest + "/"
        if value.startswith(prefix):
            return mounts[dest] + value[len(dest):]
    return value

for key, value in env.items():
    os.environ[key] = remap(value)
fd, path = tempfile.mkstemp(prefix="builder-stdin-")
os.write(fd, script)
os.lseek(fd, 0, os.SEEK_SET)
os.dup2(fd, 0)
os.close(fd)
os.unlink(path)
os.execv("/bin/bash", ["/bin/bash", "-s", "--", "--internal-run"])
'''

SLEEP_STUB = r'''#!/usr/bin/env python3
import json, os, sys, time
args = sys.argv[1:]
log = os.environ.get("STUB_ACTIONS")

def note(item):
    if not log:
        return
    with open(log, "a") as handle:
        handle.write(json.dumps(item) + "\n")

if args[:1] == ["stop"]:
    note({"cmd": "stop", "args": args[1:]})
    raise SystemExit(0)
if args[:1] == ["rm"]:
    note({"cmd": "rm", "args": args[1:]})
    raise SystemExit(0)

sys.stdin.buffer.read()
cidfile = None
name = None
output = None
index = 0
while index < len(args):
    item = args[index]
    if item == "--cidfile":
        cidfile = args[index + 1]
        index += 2
    elif item == "--name":
        name = args[index + 1]
        index += 2
    elif item == "-v":
        parts = args[index + 1].split(":")
        if parts[-1] in ("ro", "rw"):
            parts = parts[:-1]
        if parts[-1] == "/output":
            output = ":".join(parts[:-1])
        index += 2
    else:
        index += 1
cid = os.environ.get("STUB_CID", "")
if cidfile and cid:
    open(cidfile, "w").write(cid + "\n")
if output:
    open(os.path.join(output, "pkg.deb"), "wb").write(b"!<arch>\n")
note({"cmd": "run", "name": name, "cidfile": cidfile, "wrote": cid})
open(sys.argv[0] + ".pid", "w").write(str(os.getpid()))
code = os.environ.get("STUB_EXIT", "")
if code:
    raise SystemExit(int(code))
time.sleep(30)
'''

DIRTY_STUB = r'''#!/usr/bin/env python3
import os, shutil, sys
sys.stdin.buffer.read()
args = sys.argv[1:]
mounts = {}
index = 0
while index < len(args):
    if args[index] == "-v":
        parts = args[index + 1].split(":")
        if parts[-1] in ("ro", "rw"):
            parts = parts[:-1]
        mounts[parts[-1]] = ":".join(parts[:-1])
        index += 2
    else:
        index += 1
output = mounts["/output"]
fixture = os.environ["STAGE_FIXTURE"]
for dirpath, dirnames, filenames in os.walk(fixture, followlinks=False):
    rel = os.path.relpath(dirpath, fixture)
    target = output if rel == "." else os.path.join(output, rel)
    os.makedirs(target, exist_ok=True)
    for name in filenames:
        src = os.path.join(dirpath, name)
        dest = os.path.join(target, name)
        if os.path.islink(src):
            os.symlink(os.readlink(src), dest)
        else:
            shutil.copy2(src, dest)
    for name in dirnames:
        src = os.path.join(dirpath, name)
        if os.path.islink(src):
            os.symlink(os.readlink(src), os.path.join(target, name))
'''


class LocalBuilderTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.called = self.root / "runner-called"
        self.stub = self.root / "runner"
        self.argv_path = self.root / "argv.json"
        self.stdin_path = self.root / "stdin.bin"

    def tearDown(self):
        self.tmp.cleanup()

    def use_stub(self, body):
        self.stub.write_text(body)
        self.stub.chmod(0o755)

    def source_tree(self, build_body, install_body=None, build_name="build.sh", install_name="install.sh"):
        source = self.root / "source"
        source.mkdir()
        (source / "README-source.txt").write_text("source repo\n")
        git = source / ".git"
        git.mkdir()
        (git / "config").write_text("source git\n")
        write_script(source / build_name, build_body)
        if install_body is not None:
            write_script(source / install_name, install_body)
        return source

    def run_builder(self, source, output, cache, profile="fs150-focal-noetic", arch="amd64",
                    build="build.sh", install=None, extra_env=None):
        output.mkdir(parents=True, exist_ok=True)
        cache.mkdir(parents=True, exist_ok=True)
        env = os.environ.copy()
        env["BUILDER_RUNNER"] = str(self.stub)
        env["STUB_ARGV"] = str(self.argv_path)
        env["STUB_STDIN"] = str(self.stdin_path)
        if extra_env:
            env.update(extra_env)
        command = [
            str(SCRIPT),
            "--profile", profile,
            "--arch", arch,
            "--source", str(source),
            "--build", build,
            "--output", str(output),
            "--cache-root", str(cache),
        ]
        if install:
            command.extend(["--install", install])
        return subprocess.run(command, env=env, text=True, capture_output=True)

    def test_profiles_are_the_existing_baseline(self):
        self.assertEqual(set(PROFILES), EXPECTED_PROFILES)
        for spec in PROFILES.values():
            self.assertEqual(spec["architectures"], ["amd64", "arm64"])

    def test_argv_uses_profile_image_and_publishes_only_the_deb(self):
        self.use_stub(ARGV_STUB)
        source = self.source_tree("#!/bin/sh\nexit 0\n")
        script_text = SCRIPT.read_text()
        self.assertNotIn("Dockerfile", script_text)
        self.assertNotIn("image-entrypoint", script_text)
        self.assertNotIn("--filter", script_text)
        self.assertNotIn("docker ps", script_text)
        for profile, spec in PROFILES.items():
            for arch in spec["architectures"]:
                with self.subTest(profile=profile, arch=arch):
                    output = self.root / "out" / profile / arch
                    cache = self.root / "cache"
                    if self.argv_path.exists():
                        self.argv_path.unlink()
                    result = self.run_builder(source, output, cache, profile, arch)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    argv = json.loads(self.argv_path.read_text())
                    image = "onboard-sim-%s:latest" % profile
                    self.assertEqual(argv[0], "run")
                    self.assertIn("-i", argv)
                    self.assertIn("--rm", argv)
                    self.assertEqual(
                        argv[argv.index("--cidfile") + 1],
                        str((cache / profile / arch / "cid").resolve()),
                    )
                    self.assertEqual(argv[argv.index(image):], [image, "-s", "--", "--internal-run"])
                    self.assertEqual(argv[argv.index("--platform") + 1], "linux/%s" % arch)
                    self.assertEqual(argv[argv.index("--entrypoint") + 1], "/bin/bash")
                    self.assertEqual(self.stdin_path.read_bytes(), SCRIPT.read_bytes())
                    self.assertNotIn(str(SCRIPT), "\n".join(argv))
                    self.assertIn("ONBOARD_USER=%s" % spec["username"], argv)
                    self.assertIn("ONBOARD_UBUNTU=%s" % spec["ubuntuCodename"], argv)
                    self.assertIn("ONBOARD_ROS=%s" % spec["rosDistro"], argv)
                    self.assertNotIn("--network", argv)
                    joined = " ".join(argv)
                    for banned in ("image-entrypoint", "Dockerfile", "apt-get", "binfmt", "--privileged", "build-local-image.sh", "onboard-baseline.sh"):
                        self.assertNotIn(banned, joined)
                    mounts = parse_mounts(argv)
                    self.assertEqual(mounts["/src"][1], "ro")
                    self.assertEqual(mounts["/src"][0], str(source.resolve()))
                    self.assertNotIn("/builder/build-local-project.sh", mounts)
                    for host, _mode in mounts.values():
                        self.assertFalse(host.endswith("build-local-project.sh"))
                    self.assertIsNone(mounts["/cache"][1])
                    self.assertIsNone(mounts["/work"][1])
                    self.assertIsNone(mounts["/output"][1])
                    self.assertIn("/%s/%s/cache" % (profile, arch), mounts["/cache"][0])
                    self.assertIn("/%s/%s/work" % (profile, arch), mounts["/work"][0])
                    manifest = json.loads((output / "manifest.json").read_text())
                    self.assertFalse(manifest["installed"])
                    self.assertEqual(manifest["robotInstall"], "not-run")
                    self.assertEqual(manifest["username"], spec["username"])
                    self.assertEqual(manifest["builderImage"], image)
                    text = (output / "manifest.json").read_text()
                    self.assertNotIn("relocatable", text)
                    self.assertNotIn("consumed", text)
                    self.assertNotIn("ONBOARD_PROOF", joined)
                    self.assertEqual(manifest["artifacts"], [{
                        "kind": "deb",
                        "name": "pkg.deb",
                        "installed": False,
                    }])
                    self.assertEqual((output / "pkg.deb").read_bytes(), DEB)
                    self.assertFalse((output / "install-space.tar").exists())
                    names = sorted(path.name for path in output.iterdir())
                    self.assertEqual(names, ["manifest.json", "pkg.deb"])

        installed = self.root / "opt/xgc2/tools/onboard-baseline"
        installed.mkdir(parents=True)
        helper = installed / "build-local-project.sh"
        shutil.copy2(SCRIPT, helper)
        helper.chmod(0o755)
        shutil.copy2(BASELINE / "baselines.json", installed / "baselines.json")
        xdg = self.root / "xdg-cache"
        home = self.root / "home"
        output = self.root / "opt-out"
        output.mkdir()
        env = os.environ.copy()
        env["BUILDER_RUNNER"] = str(self.stub)
        env["STUB_ARGV"] = str(self.argv_path)
        env["STUB_STDIN"] = str(self.stdin_path)
        env["XDG_CACHE_HOME"] = str(xdg)
        env.pop("HOME", None)
        self.argv_path.unlink()
        xdg_run = subprocess.run(
            [
                str(helper), "--profile", "fs150-focal-noetic", "--arch", "amd64",
                "--source", str(source), "--build", "build.sh", "--output", str(output),
            ],
            env=env, text=True, capture_output=True,
        )
        self.assertEqual(xdg_run.returncode, 0, xdg_run.stderr)
        argv = json.loads(self.argv_path.read_text())
        self.assertNotIn(str(helper), "\n".join(argv))
        self.assertNotIn("build-local-project.sh", "\n".join(argv))
        self.assertEqual(self.stdin_path.read_bytes(), helper.read_bytes())
        mounts = parse_mounts(argv)
        slot = (xdg / "xgc2/onboard-builder/fs150-focal-noetic/amd64").resolve()
        self.assertEqual(mounts["/cache"][0], str(slot / "cache"))
        self.assertEqual(mounts["/work"][0], str(slot / "work"))
        self.assertEqual(mounts["/output"][0], str(slot / "stage"))
        self.assertEqual(mounts["/src"][0], str(source.resolve()))
        self.assertTrue((slot / "cache").is_dir())
        self.assertFalse(str(slot).startswith(str(installed.resolve())))
        self.assertEqual((output / "pkg.deb").read_bytes(), DEB)
        self.assertFalse((installed / "pkg.deb").exists())

        home_out = self.root / "home-out"
        home_out.mkdir()
        env.pop("XDG_CACHE_HOME")
        env["HOME"] = str(home)
        self.argv_path.unlink()
        home_run = subprocess.run(
            [
                str(helper), "--profile", "fs150-focal-noetic", "--arch", "arm64",
                "--source", str(source), "--build", "build.sh", "--output", str(home_out),
            ],
            env=env, text=True, capture_output=True,
        )
        self.assertEqual(home_run.returncode, 0, home_run.stderr)
        argv = json.loads(self.argv_path.read_text())
        mounts = parse_mounts(argv)
        home_cache = (home / ".cache/xgc2/onboard-builder/fs150-focal-noetic/arm64/cache").resolve()
        self.assertEqual(mounts["/cache"][0], str(home_cache))
        self.assertEqual(mounts["/src"][0], str(source.resolve()))
        self.assertNotIn(str(helper), "\n".join(argv))
        self.assertEqual(self.stdin_path.read_bytes(), helper.read_bytes())

    def test_install_space_packs_the_build_tree_without_running_the_install_script(self):
        self.use_stub(EXEC_STUB)
        source = self.source_tree(
            """\
            #!/bin/sh
            mkdir -p "$ONBOARD_OUTPUT/install/lib" "$ONBOARD_CACHE" "$ONBOARD_WORK"
            printf 'payload-bytes' > "$ONBOARD_OUTPUT/install/lib/lib.so"
            printf '!<arch>\\n' > "$ONBOARD_OUTPUT/pkg.deb"
            printf '%s %s\\n' "$ONBOARD_PROFILE" "$ONBOARD_ARCH" > "$ONBOARD_CACHE/marker"
            printf kept >> "$ONBOARD_WORK/kept"
            """,
            """\
            #!/bin/sh
            printf ran > "$ONBOARD_SOURCE/ran"
            exit 1
            """,
        )
        output = self.root / "out"
        cache = self.root / "cache"
        result = self.run_builder(source, output, cache, install="install.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((source / "ran").exists())
        argv = json.loads(self.argv_path.read_text())
        self.assertNotIn("ONBOARD_PROOF", " ".join(argv))
        self.assertNotIn("build-local-project.sh", "\n".join(argv))
        self.assertEqual(argv[argv.index("--entrypoint") + 1], "/bin/bash")
        self.assertIn("-s", argv)
        self.assertEqual(self.stdin_path.read_bytes(), SCRIPT.read_bytes())
        self.assertFalse(any(item.endswith("install.sh") for item in argv))
        manifest = json.loads((output / "manifest.json").read_text())
        self.assertFalse(manifest["installed"])
        self.assertEqual(manifest["robotInstall"], "not-run")
        text = (output / "manifest.json").read_text()
        self.assertNotIn("consumed", text)
        self.assertNotIn(str(source), text)
        kinds = {item["kind"]: item for item in manifest["artifacts"]}
        self.assertFalse(kinds["deb"]["installed"])
        self.assertNotIn("consumption", kinds["deb"])
        self.assertEqual(kinds["install-space"]["installScript"], "project-install.sh")
        self.assertEqual(kinds["install-space"]["agentArgv"], ["project-install.sh"])
        self.assertEqual(kinds["install-space"]["agentEnv"], ["ONBOARD_INSTALL", "ONBOARD_DEST"])
        self.assertFalse(kinds["install-space"]["installed"])
        self.assertNotIn("consumption", kinds["install-space"])
        self.assertEqual((output / "project-install.sh").read_bytes(), (source / "install.sh").read_bytes())
        self.assertTrue(os.access(output / "project-install.sh", os.X_OK))
        with tarfile.open(output / "install-space.tar") as archive:
            names = archive.getnames()
            payload = archive.extractfile("install/lib/lib.so").read()
        self.assertEqual(payload, b"payload-bytes")
        self.assertNotIn("pkg.deb", names)
        self.assertFalse(any(".git" in name or "README-source" in name or "devel" in name for name in names))
        self.assertFalse((cache / "fs150-focal-noetic/amd64/stage/.builder-proof.json").exists())

    def test_install_script_is_packed_even_when_it_would_fail_if_executed(self):
        self.use_stub(EXEC_STUB)
        source = self.source_tree(
            """\
            #!/bin/sh
            mkdir -p "$ONBOARD_OUTPUT/install/lib"
            printf 'payload-bytes' > "$ONBOARD_OUTPUT/install/lib/lib.so"
            """,
            """\
            #!/bin/sh
            printf ran > "$ONBOARD_SOURCE/ran"
            exit 1
            """,
        )
        output = self.root / "out"
        result = self.run_builder(source, output, self.root / "cache", install="install.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((source / "ran").exists())
        with tarfile.open(output / "install-space.tar") as archive:
            self.assertEqual(archive.extractfile("install/lib/lib.so").read(), b"payload-bytes")
        self.assertEqual((output / "project-install.sh").read_bytes(), (source / "install.sh").read_bytes())

    def test_install_space_without_an_install_script_publishes_nothing(self):
        self.use_stub(EXEC_STUB)
        source = self.source_tree(
            """\
            #!/bin/sh
            mkdir -p "$ONBOARD_OUTPUT/install/lib"
            printf 'payload-bytes' > "$ONBOARD_OUTPUT/install/lib/lib.so"
            """
        )
        output = self.root / "out"
        result = self.run_builder(source, output, self.root / "cache")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("install space requires the project install script", result.stderr)
        self.assertEqual(list(output.iterdir()), [])

    def test_publish_rejects_devel_git_source_and_foreign_files(self):
        self.use_stub(DIRTY_STUB)
        source = self.source_tree("#!/bin/sh\nexit 0\n")

        def fill(root):
            cases = {}
            devel = root / "devel-case"
            (devel / "devel").mkdir(parents=True)
            (devel / "pkg.deb").write_bytes(DEB)
            (devel / "devel" / "x").write_text("x")
            cases["devel"] = devel
            git = root / "git-case"
            (git / "install" / ".git").mkdir(parents=True)
            (git / "install" / ".git" / "config").write_text("git")
            (git / "install" / "lib.so").write_text("lib")
            cases["git"] = git
            nested = root / "nested-devel"
            (nested / "install" / "devel").mkdir(parents=True)
            (nested / "install" / "devel" / "lib.so").write_text("devel")
            (nested / "install" / "lib.so").write_text("lib")
            cases["nested-devel"] = nested
            extra = root / "extra-case"
            extra.mkdir()
            (extra / "pkg.deb").write_bytes(DEB)
            (extra / "notes.txt").write_text("notes")
            cases["extra"] = extra
            magic = root / "magic-case"
            magic.mkdir()
            (magic / "pkg.deb").write_text("not-a-deb\n")
            cases["magic"] = magic
            link = root / "link-case"
            (link / "install" / "lib").mkdir(parents=True)
            (link / "install" / "lib" / "libfoo.so.1").write_text("lib")
            (link / "install" / "lib" / "libfoo.so").symlink_to("/usr/lib/libfoo.so.1")
            cases["link"] = link
            outside = root / "relative-escape"
            (outside / "install" / "lib").mkdir(parents=True)
            (outside / "install" / "lib" / "libfoo.so.1").write_text("lib")
            (outside / "install" / "lib" / "libfoo.so").symlink_to("../../../etc/passwd")
            cases["relative-escape"] = outside
            return cases

        fixtures = fill(self.root / "fixtures")
        expected = {
            "devel": "unexpected output devel",
            "git": "output contains .git",
            "nested-devel": "output contains devel",
            "extra": "unexpected output notes.txt",
            "magic": "is not a deb archive",
            "link": "symlink escapes",
            "relative-escape": "symlink escapes",
        }
        for name, fixture in fixtures.items():
            with self.subTest(name=name):
                output = self.root / "out" / name
                cache = self.root / "cache" / name
                result = self.run_builder(
                    source, output, cache, extra_env={"STAGE_FIXTURE": str(fixture)},
                )
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertIn(expected[name], result.stderr)
                self.assertEqual(list(output.iterdir()), [])

    def test_cache_is_per_profile_and_arch_and_survives_the_next_run(self):
        self.use_stub(EXEC_STUB)
        source = self.source_tree(
            """\
            #!/bin/sh
            mkdir -p "$ONBOARD_CACHE" "$ONBOARD_WORK" "$ONBOARD_OUTPUT"
            printf '%s %s\\n' "$ONBOARD_PROFILE" "$ONBOARD_ARCH" > "$ONBOARD_CACHE/marker"
            printf kept >> "$ONBOARD_WORK/kept"
            printf '!<arch>\\n' > "$ONBOARD_OUTPUT/pkg.deb"
            """
        )
        cache = self.root / "cache"
        first = self.run_builder(source, self.root / "out1", cache)
        self.assertEqual(first.returncode, 0, first.stderr)
        arm = self.run_builder(
            source, self.root / "out-arm", cache,
            profile="scout-bionic-melodic", arch="arm64",
        )
        self.assertEqual(arm.returncode, 0, arm.stderr)
        focal = (cache / "fs150-focal-noetic/amd64/cache/marker").read_text()
        scout = (cache / "scout-bionic-melodic/arm64/cache/marker").read_text()
        self.assertEqual(focal, "fs150-focal-noetic amd64\n")
        self.assertEqual(scout, "scout-bionic-melodic arm64\n")
        self.assertFalse((cache / "fs150-focal-noetic/arm64/cache/marker").exists())
        kept = cache / "fs150-focal-noetic/amd64/work/kept"
        self.assertEqual(kept.read_text(), "kept")
        write_script(
            source / "build.sh",
            """\
            #!/bin/sh
            test -s "$ONBOARD_CACHE/marker"
            test -s "$ONBOARD_WORK/kept"
            mkdir -p "$ONBOARD_OUTPUT"
            printf '!<arch>\\n' > "$ONBOARD_OUTPUT/other.deb"
            """,
        )
        second = self.run_builder(source, self.root / "out2", cache)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(kept.read_text(), "kept")
        self.assertEqual(focal, (cache / "fs150-focal-noetic/amd64/cache/marker").read_text())
        stage = cache / "fs150-focal-noetic/amd64/stage"
        self.assertTrue((stage / "other.deb").is_file())
        self.assertFalse((stage / "pkg.deb").exists())
        self.assertEqual((self.root / "out2" / "other.deb").read_bytes(), DEB)
        self.assertFalse((self.root / "out2" / "pkg.deb").exists())

    def test_cancel_stops_the_runner_and_keeps_cache(self):
        self.use_stub(EXEC_STUB)
        source = self.source_tree(
            """\
            #!/bin/sh
            mkdir -p "$ONBOARD_CACHE" "$ONBOARD_OUTPUT"
            printf stay > "$ONBOARD_CACHE/marker"
            printf '!<arch>\\n' > "$ONBOARD_OUTPUT/pkg.deb"
            """
        )
        cache = self.root / "cache"
        first = self.run_builder(source, self.root / "out1", cache)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.use_stub(SLEEP_STUB)
        output = self.root / "out2"
        actions = self.root / "actions.jsonl"
        cid = "ab" * 32
        robot = "cd" * 32
        robot_file = cache / "robot-container"
        robot_file.write_text(robot + "\n")
        env = os.environ.copy()
        env["BUILDER_RUNNER"] = str(self.stub)
        env["STUB_ACTIONS"] = str(actions)
        env["STUB_CID"] = cid
        proc = subprocess.Popen(
            [
                str(SCRIPT), "--profile", "fs150-focal-noetic", "--arch", "amd64",
                "--source", str(source), "--build", "build.sh",
                "--output", str(output), "--cache-root", str(cache),
            ],
            env=env, start_new_session=True, text=True,
        )
        pid_path = Path(str(self.stub) + ".pid")
        deadline = time.time() + 5
        while time.time() < deadline and not pid_path.exists():
            if proc.poll() is not None:
                break
            time.sleep(0.05)
        self.assertTrue(pid_path.exists(), "runner did not start")
        os.kill(proc.pid, signal.SIGTERM)
        try:
            code = proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            raise
        self.assertEqual(code, 130)
        child = int(pid_path.read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(child, 0)
        self.assertEqual(list(output.iterdir()), [])
        self.assertEqual((cache / "fs150-focal-noetic/amd64/cache/marker").read_text(), "stay")
        recorded = [json.loads(line) for line in actions.read_text().splitlines()]
        self.assertEqual([item["cmd"] for item in recorded], ["run", "stop", "rm"])
        self.assertTrue(recorded[0]["name"].startswith("onboard-builder-"))
        self.assertEqual(recorded[1], {"cmd": "stop", "args": [cid]})
        self.assertEqual(recorded[2], {"cmd": "rm", "args": ["-f", cid]})
        cleanup = json.dumps(recorded[1:])
        self.assertNotIn(recorded[0]["name"], cleanup)
        self.assertNotIn(robot, cleanup)
        self.assertNotIn("label", cleanup)
        self.assertNotIn("--filter", cleanup)
        self.assertEqual(robot_file.read_text(), robot + "\n")
        self.assertEqual((cache / "fs150-focal-noetic/amd64/cid").read_text().strip(), cid)

        actions.write_text("")
        failed = self.root / "out3"
        failed.mkdir()
        env["STUB_EXIT"] = "1"
        broken = subprocess.run(
            [
                str(SCRIPT), "--profile", "fs150-focal-noetic", "--arch", "amd64",
                "--source", str(source), "--build", "build.sh",
                "--output", str(failed), "--cache-root", str(cache),
            ],
            env=env, text=True, capture_output=True,
        )
        self.assertNotEqual(broken.returncode, 0)
        self.assertEqual(list(failed.iterdir()), [])
        self.assertEqual((cache / "fs150-focal-noetic/amd64/cache/marker").read_text(), "stay")
        recorded = [json.loads(line) for line in actions.read_text().splitlines() if line]
        self.assertEqual([item["cmd"] for item in recorded], ["run", "stop", "rm"])
        self.assertEqual(recorded[1]["args"], [cid])
        self.assertEqual(recorded[2]["args"], ["-f", cid])

        actions.write_text("")
        env.pop("STUB_CID")
        missing = self.root / "out4"
        missing.mkdir()
        no_cid = subprocess.run(
            [
                str(SCRIPT), "--profile", "fs150-focal-noetic", "--arch", "amd64",
                "--source", str(source), "--build", "build.sh",
                "--output", str(missing), "--cache-root", str(cache),
            ],
            env=env, text=True, capture_output=True,
        )
        self.assertNotEqual(no_cid.returncode, 0)
        self.assertEqual(list(missing.iterdir()), [])
        recorded = [json.loads(line) for line in actions.read_text().splitlines() if line]
        self.assertEqual([item["cmd"] for item in recorded], ["run"])
        self.assertEqual(robot_file.read_text(), robot + "\n")
        self.assertEqual((cache / "fs150-focal-noetic/amd64/cache/marker").read_text(), "stay")

    def test_second_build_of_the_same_slot_is_rejected_while_the_lock_is_held(self):
        self.use_stub(SLEEP_STUB)
        source = self.source_tree("#!/bin/sh\nexit 0\n")
        cache = self.root / "cache"
        output = self.root / "out1"
        env = os.environ.copy()
        env["BUILDER_RUNNER"] = str(self.stub)
        proc = subprocess.Popen(
            [
                str(SCRIPT), "--profile", "wheeltec-bionic-melodic", "--arch", "arm64",
                "--source", str(source), "--build", "build.sh",
                "--output", str(output), "--cache-root", str(cache),
            ],
            env=env, start_new_session=True,
        )
        pid_path = Path(str(self.stub) + ".pid")
        deadline = time.time() + 5
        while time.time() < deadline and not pid_path.exists():
            if proc.poll() is not None:
                break
            time.sleep(0.05)
        self.assertTrue(pid_path.exists(), "runner did not start")
        try:
            other = self.root / "other-runner"
            other.write_text("#!/bin/sh\ntouch '%s'\n" % (self.called,))
            other.chmod(0o755)
            env["BUILDER_RUNNER"] = str(other)
            result = subprocess.run(
                [
                    str(SCRIPT), "--profile", "wheeltec-bionic-melodic", "--arch", "arm64",
                    "--source", str(source), "--build", "build.sh",
                    "--output", str(self.root / "out2"), "--cache-root", str(cache),
                ],
                env=env, text=True, capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("already running", result.stderr)
            self.assertFalse(self.called.exists())
            self.assertEqual(list((self.root / "out2").iterdir()), [])
        finally:
            os.kill(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait(timeout=5)

    def test_rejects_unknown_profile_arch_and_source_escape_without_a_runner(self):
        self.use_stub(ARGV_STUB)
        source = self.source_tree("#!/bin/sh\nexit 0\n")
        output = self.root / "out"
        cache = self.root / "cache"
        unknown = self.run_builder(source, output, cache, profile="fs150-focal-noetic-sitl")
        self.assertNotEqual(unknown.returncode, 0)
        self.assertIn("unknown profile", unknown.stderr)
        self.assertFalse(self.argv_path.exists())
        bad_arch = self.run_builder(source, output, cache, arch="riscv64")
        self.assertNotEqual(bad_arch.returncode, 0)
        self.assertIn("architecture must be amd64 or arm64", bad_arch.stderr)
        self.assertFalse(self.argv_path.exists())
        escaped = self.run_builder(source, output, cache, build="../build.sh")
        self.assertNotEqual(escaped.returncode, 0)
        self.assertIn("inside the source tree", escaped.stderr)
        self.assertFalse(self.argv_path.exists())
        outside = self.root / "outside.sh"
        write_script(outside, "#!/bin/sh\nexit 0\n")
        link = source / "linked.sh"
        link.symlink_to(outside)
        linked = self.run_builder(source, output, cache, build="linked.sh")
        self.assertNotEqual(linked.returncode, 0)
        self.assertIn("inside the source tree", linked.stderr)
        self.assertFalse(self.argv_path.exists())
        (output / "existing").write_text("keep")
        occupied = self.run_builder(source, output, cache)
        self.assertNotEqual(occupied.returncode, 0)
        self.assertIn("not empty", occupied.stderr)
        self.assertEqual((output / "existing").read_text(), "keep")
        self.assertFalse(self.argv_path.exists())

    def test_in_archive_library_symlink_ships_with_the_install_script(self):
        self.use_stub(EXEC_STUB)
        source = self.source_tree(
            """\
            #!/bin/sh
            mkdir -p "$ONBOARD_OUTPUT/install/lib" "$ONBOARD_OUTPUT/install/share/pkg"
            printf 'library-bytes' > "$ONBOARD_OUTPUT/install/lib/libfoo.so.1"
            ln -s libfoo.so.1 "$ONBOARD_OUTPUT/install/lib/libfoo.so"
            printf 'project cmake\\n' > "$ONBOARD_OUTPUT/install/share/pkg/CMakeLists.txt"
            """,
            """\
            #!/bin/sh
            printf ran > "$ONBOARD_SOURCE/ran"
            exit 1
            """,
        )
        output = self.root / "out"
        result = self.run_builder(source, output, self.root / "cache", install="install.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((source / "ran").exists())
        with tarfile.open(output / "install-space.tar") as archive:
            soname = archive.getmember("install/lib/libfoo.so")
            self.assertTrue(soname.issym())
            self.assertEqual(soname.linkname, "libfoo.so.1")
            self.assertEqual(archive.extractfile("install/lib/libfoo.so.1").read(), b"library-bytes")
            self.assertIn("install/share/pkg/CMakeLists.txt", archive.getnames())
        manifest = json.loads((output / "manifest.json").read_text())
        shipped = manifest["artifacts"][0]
        self.assertEqual(shipped["installScript"], "project-install.sh")
        self.assertEqual(shipped["agentArgv"], ["project-install.sh"])
        self.assertNotIn(str(source), (output / "manifest.json").read_text())
        self.assertEqual((output / "project-install.sh").read_bytes(), (source / "install.sh").read_bytes())

    def run_prepare(self, source, role, env):
        merged = os.environ.copy()
        merged.update(env)
        return subprocess.run(
            [str(SCRIPT), "prepare", "--profile", "fs150-focal-noetic",
             "--source", str(source), "--script", "deps.sh", "--role", role],
            env=merged, text=True, capture_output=True,
        )

    def write_prepare_fixtures(self, source, log, marker, count):
        quoted_log = json.dumps(str(log))
        quoted_count = json.dumps(str(count))
        quoted_marker = json.dumps(str(marker))
        (self.root / "baseline").write_text(
            "#!/bin/sh\n"
            "printf '%%s\\n' \"$*\" >> %s\n"
            "if [ \"$1\" = check ]; then\n"
            "  n=0\n"
            "  if [ -f %s ]; then n=$(cat %s); fi\n"
            "  n=$((n+1))\n"
            "  printf '%%s\\n' \"$n\" > %s\n"
            "  if [ \"$n\" = 1 ]; then exit \"$FIRST_CHECK\"; fi\n"
            "fi\nexit 0\n" % (quoted_log, quoted_count, quoted_count, quoted_count)
        )
        (self.root / "baseline").chmod(0o755)
        write_script(
            source / "deps.sh",
            "#!/bin/sh\nprintf '%%s\\n' \"$ONBOARD_PREPARE\" > %s\n" % quoted_marker,
        )

    def test_prepare_reuses_a_ready_profile_and_keeps_build_deps_off_apply(self):
        source = self.source_tree("#!/bin/sh\nexit 0\n")
        log = self.root / "baseline.log"
        marker = self.root / "role"
        count = self.root / "checks"
        self.write_prepare_fixtures(source, log, marker, count)
        env = {"ONBOARD_BASELINE_BIN": str(self.root / "baseline"), "FIRST_CHECK": "0"}
        ready = self.run_prepare(source, "runtime", env)
        self.assertEqual(ready.returncode, 0, ready.stderr)
        self.assertEqual(log.read_text().splitlines(), ["check --profile fs150-focal-noetic"])
        self.assertEqual(marker.read_text(), "runtime\n")
        log.unlink()
        marker.unlink()
        if count.exists():
            count.unlink()
        build = self.run_prepare(source, "build", env)
        self.assertEqual(build.returncode, 0, build.stderr)
        self.assertFalse(log.exists())
        self.assertEqual(marker.read_text(), "build\n")

    def test_prepare_apply_runs_only_as_root_when_the_profile_is_not_ready(self):
        source = self.source_tree("#!/bin/sh\nexit 0\n")
        log = self.root / "baseline.log"
        marker = self.root / "role"
        count = self.root / "checks"
        self.write_prepare_fixtures(source, log, marker, count)
        env = {"ONBOARD_BASELINE_BIN": str(self.root / "baseline"), "FIRST_CHECK": "4"}
        denied = self.run_prepare(source, "runtime", env)
        self.assertNotEqual(denied.returncode, 0)
        self.assertIn("needs root", denied.stderr)
        self.assertEqual(log.read_text().splitlines(), ["check --profile fs150-focal-noetic"])
        self.assertFalse(marker.exists())
        log.write_text("")
        count.unlink()
        bindir = self.root / "bin"
        bindir.mkdir()
        ident = bindir / "id"
        ident.write_text("#!/bin/sh\nif [ \"$1\" = -u ]; then echo 0; exit 0; fi\nexec /usr/bin/id \"$@\"\n")
        ident.chmod(0o755)
        env = dict(env, PATH="%s:%s" % (bindir, os.environ.get("PATH", "")))
        allowed = self.run_prepare(source, "runtime", env)
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        self.assertEqual(log.read_text().splitlines(), [
            "check --profile fs150-focal-noetic",
            "apply --profile fs150-focal-noetic",
            "check --profile fs150-focal-noetic",
        ])
        self.assertEqual(marker.read_text(), "runtime\n")


if __name__ == "__main__":
    unittest.main()
