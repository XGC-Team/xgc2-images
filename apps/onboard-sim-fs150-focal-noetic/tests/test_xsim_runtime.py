#!/usr/bin/env python3
"""Structural contract for the optional source XSim runtime image target."""
import re
from pathlib import Path
import subprocess
import unittest

DOCKERFILE = Path(__file__).resolve().parents[1] / "Dockerfile"


def stages(text):
    result = []
    for match in re.finditer(r"^FROM ([^\n]+)\n", text, re.MULTILINE):
        if result:
            result[-1]["body"] = text[result[-1]["start"]:match.start()]
        parts = match.group(1).split()
        result.append({"base": parts[0],
                       "name": parts[2] if len(parts) == 3 else None,
                       "start": match.start(), "body": ""})
    result[-1]["body"] = text[result[-1]["start"]:]
    return result


class XSimRuntimeImageTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = DOCKERFILE.read_text()
        cls.stages = stages(cls.text)
        cls.named = {stage["name"]: stage for stage in cls.stages}
        cls.simulation = cls.named["xsim-simulation"]["body"]

    def test_default_agent_paths_do_not_depend_on_simulation_material(self):
        self.assertIn("ARG AGENT_INSTALL=apt\n", self.text)
        self.assertEqual(self.stages[-1]["body"], "FROM ${AGENT_INSTALL}-agent\n")
        for role in ("apt", "source"):
            pending = [self.stages[-1]]
            visited = set()
            while pending:
                stage = pending.pop()
                name = stage["name"]
                if name in visited:
                    continue
                visited.add(name)
                body = stage["body"]
                self.assertNotIn("xsim-runtime", body)
                self.assertNotIn("/opt/xgc2/xsim", body)
                self.assertNotIn("xsim-simulation", body)
                parents = [stage["base"].replace("${AGENT_INSTALL}", role)]
                parents += re.findall(r"--from=([^\s]+)", body)
                pending.extend(self.named[parent] for parent in parents
                               if parent in self.named)
            self.assertIn(role + "-agent", visited)
            self.assertIn("baseline", visited)

    def test_simulation_has_one_explicit_runtime_context(self):
        self.assertEqual(self.named["xsim-simulation"]["base"],
                         "${XSIM_PARENT_IMAGE}")
        self.assertEqual(re.findall(r"--from=([^\s]+)", self.simulation),
                         ["xsim-runtime"])
        self.assertIn("COPY --from=xsim-runtime /rootfs/ /\n", self.simulation)
        self.assertNotIn("--from=core", self.simulation)
        self.assertNotRegex(self.simulation, r"\b(?:apt-get|curl|wget)\b")

    def test_runtime_parent_defaults_to_selected_agent_without_changing_default(self):
        self.assertIn("ARG AGENT_INSTALL=apt\n"
                      "ARG XSIM_PARENT_IMAGE=${AGENT_INSTALL}-agent\n",
                      self.text)
        self.assertEqual(self.text.count("XSIM_PARENT_IMAGE"), 2)
        self.assertEqual(self.stages[-1]["body"], "FROM ${AGENT_INSTALL}-agent\n")
        for role in ("source", "apt"):
            self.assertIn(role + "-agent", self.named)

    def test_entrypoint_is_inherited_without_a_world_command(self):
        self.assertIn('ENTRYPOINT ["/opt/xgc2/onboard-baseline/image-entrypoint.sh"]',
                      self.named["baseline"]["body"])
        self.assertNotRegex(self.simulation, r"(?m)^(?:ENTRYPOINT|CMD)\b")
        self.assertNotIn("--experiment-stdin", self.simulation)
        self.assertNotIn("LD_PRELOAD", self.simulation)
        self.assertNotIn("LD_LIBRARY_PATH", self.simulation)

    def test_runtime_check_requires_gpu_material_and_resolves_actual_files(self):
        for path in ("/opt/xgc2/xsim/bin/xsim",
                     "/usr/lib/xgc2-sensing/libxgc2-sensing-gpu.so"):
            self.assertIn(path, self.simulation)
        self.assertIn('resolved="$(readlink -e -- "$library")"', self.simulation)
        self.assertIn('dependencies="$(ldd "$resolved")"', self.simulation)
        self.assertIn("grep -F 'not found'", self.simulation)
        self.assertIn("/opt/xgc2/xsim/bin/xsim --help >/dev/null", self.simulation)
        self.assertIn("source /opt/ros/noetic/setup.bash", self.simulation)
        body = self.simulation.split("RUN bash <<'EOF'\n", 1)[1].split("\nEOF", 1)[0]
        syntax = subprocess.run(["bash", "-n"], input=body, text=True,
                                capture_output=True, check=False)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)


if __name__ == "__main__":
    unittest.main()
