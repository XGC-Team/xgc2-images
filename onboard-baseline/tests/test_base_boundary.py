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
        profiles = {name: {} for name in ('fs150-focal-noetic', 'scout-bionic-melodic', 'scout-focal-noetic', 'wheeltec-bionic-melodic')}
        for profile, config in profiles.items():
            with self.subTest(profile=profile):
                text = (ROOT/'apps'/('onboard-sim-'+profile)/'Dockerfile').read_text()
                for forbidden in ('install-agent', 'install-xsim', 'install-sitl', 'agentdeb', 'AGENT_INSTALL'):
                    self.assertNotIn(forbidden, text)
                self.assertIn('RUN /opt/xgc2/onboard-baseline/assert-base-only.sh', text)
                self.assertIn('ENTRYPOINT ["/ros_entrypoint.sh"]', text)
                self.assertIn('COPY --from=tool-scripts onboard-baseline/baselines.json', text)
                self.assertIn('/usr/sbin/policy-rc.d', text)
                app = (ROOT/'apps'/('onboard-sim-'+profile)/'app.yml').read_text()
                self.assertIn('version: latest\n', app)
                self.assertIn(':latest\n', app)
