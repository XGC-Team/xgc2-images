#!/usr/bin/env python3
"""Isolated queue-only regression for the pinned Gazebo Scene producer methods."""
import argparse
from pathlib import Path
import shlex
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--scene", type=Path, required=True, help="Unpatched Gazebo 11.15.1 Scene.cc")
parser.add_argument("--artifacts", type=Path, required=True)
args = parser.parse_args()
owner = Path(__file__).resolve().parent
args.artifacts.mkdir(parents=True, exist_ok=True)
original = args.scene.read_text()
template = (owner / "scene-queue-contract.test.cpp").read_text()

def methods(source):
    result = []
    for signature in ["bool Scene::ProcessModelMsg(", "void Scene::OnVisualMsg(",
                      "void Scene::OnJointMsg(", "void Scene::OnSensorMsg(",
                      "void Scene::OnModelMsg(", "void Scene::OnLightFactoryMsg("]:
        start = source.index(signature)
        end = source.index("\n/////////////////////////////////////////////////", start)
        result.append(source[start:end])
    start = source.index("bool Scene::ProcessSceneMsg(")
    end = source.index("  if (_msg->has_ambient())", start)
    result.append(source[start:end] + "  return true;\n}\n")
    return "namespace gazebo { namespace rendering {\n" + "\n".join(result) + "\n}}\n"

def package_flags(kind):
    return shlex.split(subprocess.check_output(["pkg-config", kind, "gazebo"], text=True))

with tempfile.TemporaryDirectory(prefix="scene-queue-") as temporary:
    stage = Path(temporary)
    scene = stage / "gazebo/rendering/Scene.cc"
    scene.parent.mkdir(parents=True)
    scene.write_text(original)
    subprocess.run(["patch", "--batch", "-d", str(stage), "-p1", "-i",
                    str(owner / "scene-visual-producer-lock.patch")], check=True)
    fixed = scene.read_text()
    for variant, source in [("original", original), ("fixed", fixed)]:
        translation = args.artifacts / (variant + ".cpp")
        translation.write_text(template.replace("// NATIVE_PRODUCER_METHODS", methods(source)))
        executable = args.artifacts / ("queue-" + variant)
        command = ["g++", *package_flags("--cflags"), "-std=c++17", "-O0", "-pthread",
                   str(translation), *package_flags("--libs"), "-o", str(executable)]
        with (args.artifacts / ("build-" + variant + ".log")).open("w") as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        result = subprocess.run([str(executable)], text=True, capture_output=True, timeout=15)
        (args.artifacts / (variant + ".log")).write_text(result.stdout + result.stderr)
        print(result.stdout, end="")
        expected = 1 if variant == "original" else 0
        if result.returncode != expected:
            raise SystemExit("unexpected " + variant + " result: " + str(result.returncode))
