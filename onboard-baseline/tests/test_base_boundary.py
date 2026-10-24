"""Check the product boundary against installed package state, including dependencies."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class BaseBoundaryTest(unittest.TestCase):
    def test_guard_rejects_installed_products_and_drivers(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            grep = root / 'grep'
            grep.write_text('#!/bin/sh\nif [ "$1" = -R ]; then exit 1; fi\nexec /usr/bin/grep "$@"\n')
            grep.chmod(0o755)
            query = root / 'dpkg-query'
            query.write_text('#!/bin/sh\nprintf "%s\\n" "$PACKAGE_STATE"\n')
            query.chmod(0o755)
            for package, expected in [('ros-noetic-ros-base', 0), ('xgc2-agent', 1),
                                      ('ros-noetic-xgc2-px4-multirotor-adapter', 1),
                                      ('xsim', 1), ('libxgc2-sensing-gpu', 1),
                                      ('ros-melodic-scout-base', 1), ('nvidia-driver-550', 1)]:
                with self.subTest(package=package):
                    env = dict(os.environ, PATH=str(root)+':'+os.environ['PATH'], PACKAGE_STATE=package+'\tinstalled')
                    result = subprocess.run(['bash', str(ROOT/'onboard-baseline/assert-base-only.sh')], env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, expected, result.stdout+result.stderr)

    def test_all_profiles_build_a_product_free_shell(self):
        profiles = json.loads((ROOT/'onboard-baseline/baselines.json').read_text())['profiles']
        for profile, config in profiles.items():
            with self.subTest(profile=profile):
                text = (ROOT/'apps'/('onboard-sim-'+profile)/'Dockerfile').read_text()
                for forbidden in ('install-agent', 'install-xsim', 'install-sitl', 'agentdeb', 'AGENT_INSTALL'):
                    self.assertNotIn(forbidden, text)
                self.assertIn('RUN /opt/xgc2/onboard-baseline/assert-base-only.sh', text)
                self.assertIn('ENTRYPOINT ["/ros_entrypoint.sh"]', text)
                self.assertFalse(any('xgc2' in package for package in config['packages']))
                app = (ROOT/'apps'/('onboard-sim-'+profile)/'app.yml').read_text()
                self.assertIn('version: latest\n', app)
                self.assertIn(':latest\n', app)


BASELINE=ROOT/'onboard-baseline'

class MirrorTests(unittest.TestCase):
    def test_architectures_suites_signatures_and_idempotency(self):
        for arch,archive in [('amd64','ubuntu'),('arm64','ubuntu-ports')]:
            with self.subTest(arch=arch), tempfile.TemporaryDirectory() as directory:
                root=Path(directory)
                apt=root/'apt'; (apt/'sources.list.d').mkdir(parents=True)
                bin=root/'bin';bin.mkdir()
                (bin/'dpkg').write_text('#!/bin/sh\necho '+arch+'\n');(bin/'dpkg').chmod(0o755)
                legacy=apt/'sources.list'
                legacy.write_text('deb [signed-by=/key.gpg] http://archive.ubuntu.com/ubuntu focal main universe\n'
                                  'deb https://security.ubuntu.com/ubuntu focal-security main\n'
                                  'deb http://ports.ubuntu.com/ubuntu-ports bionic-updates main\n'
                                  'deb http://packages.ros.org/ros/ubuntu focal main\n')
                modern=apt/'sources.list.d/ubuntu.sources'
                modern.write_text('Types: deb\nURIs: https://mirrors.ustc.edu.cn/ubuntu\nSuites: focal focal-updates\nSigned-By: /ubuntu.gpg\n')
                script=root/'mirror.sh'
                script.write_text((BASELINE/'configure-ubuntu-mirror.sh').read_text().replace('/etc/apt',str(apt)))
                env=dict(os.environ,PATH=str(bin)+':'+os.environ['PATH']);env.pop('ONBOARD_APT_MIRROR',None)
                def run(): subprocess.run(['bash',str(script)],env=env,check=True)
                run()
                expected='https://mirrors.tuna.tsinghua.edu.cn/'+archive+'/'
                self.assertEqual(legacy.read_text().count(expected),3)
                self.assertIn('focal-security main',legacy.read_text())
                self.assertIn('bionic-updates main',legacy.read_text())
                self.assertIn('signed-by=/key.gpg',legacy.read_text())
                self.assertIn('http://packages.ros.org/ros/ubuntu',legacy.read_text())
                self.assertIn('URIs: '+expected,modern.read_text())
                before=(legacy.read_text(),modern.read_text());run()
                self.assertEqual((legacy.read_text(),modern.read_text()),before)
                env['ONBOARD_APT_MIRROR']='https://mirror.example/ubuntu'
                run();self.assertIn('https://mirror.example/ubuntu/',legacy.read_text())
