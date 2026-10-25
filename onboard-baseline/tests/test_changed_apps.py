"""Changes to local developer tooling must not republish clean CI robot bases."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2]/'scripts/detect-changed-apps.sh'
APPS = ['onboard-sim-'+p for p in ('fs150-focal-noetic','scout-bionic-melodic','scout-focal-noetic','wheeltec-bionic-melodic')]

class ChangedAppsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git('init','-q')
        for app in APPS:
            path = self.root/'apps'/app
            path.mkdir(parents=True)
            (path/'Dockerfile').write_text('FROM scratch\n')
        self.write('tool-scripts.json', '{}')
        self.git('add','.')
        self.git('-c','user.name=Test','-c','user.email=test@localhost','commit','-qm','fixture')
        self.base = self.git('rev-parse','HEAD')

    def git(self, *args):
        return subprocess.check_output(['git','-C',str(self.root),*args], text=True).strip()

    def write(self, name, content):
        path = self.root/name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def changed(self):
        self.git('add','.')
        self.git('-c','user.name=Test','-c','user.email=test@localhost','commit','-qm','change')
        return json.loads(subprocess.check_output(['bash',str(SCRIPT),self.base,'HEAD'],cwd=self.root,text=True))['apps']

    def test_local_tools_and_tests_do_not_rebuild_robot_latest(self):
        self.write('onboard-baseline/tests/developer-tool.sh','source build tool')
        self.write('onboard-baseline/tests/test_source_tool.py','test')
        self.assertEqual(self.changed(), [])

    def test_base_inputs_rebuild_all_four_profiles(self):
        self.write('tool-scripts.json','{"changed":true}')
        self.assertEqual(set(self.changed()), set(APPS))

    def test_base_entrypoint_is_a_real_image_input(self):
        self.write('onboard-baseline/image-entrypoint.sh','entrypoint')
        self.assertEqual(set(self.changed()), set(APPS))

    def test_mirror_policy_is_a_real_image_input(self):
        self.write('scripts/tool-scripts-context.py','mirror')
        self.assertEqual(set(self.changed()), set(APPS))

    def test_source_sdk_is_a_real_image_input(self):
        self.write('tool-scripts.json','sdk')
        self.assertEqual(set(self.changed()), set(APPS))

    def test_one_robot_dockerfile_only_rebuilds_that_profile(self):
        self.write('apps/'+APPS[0]+'/Dockerfile','FROM other\n')
        self.assertEqual(self.changed(), [APPS[0]])
