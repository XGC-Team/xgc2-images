"""Check the product boundary against installed package state, including dependencies."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2]/'apps/onboard-sim-fs150-focal-noetic/check-network-databases.sh'

ROOT = Path(__file__).resolve().parents[2]

class BaseBoundaryTest(unittest.TestCase):
    def test_guard_allows_stable_interfaces_and_rejects_products_and_drivers(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            query = root / 'dpkg-query'
            query.write_text('#!/bin/sh\nprintf "%s\\n" "$PACKAGE_STATE"\n')
            query.chmod(0o755)
            for package, expected in [('ros-noetic-ros-base', 0),
                                      ('libxgc2-math-geometry-dev', 0),
                                      ('libxgc2-state-machine-dev', 0),
                                      ('libxgc2-xrpc-udp1:arm64', 0),
                                      ('libxgc2-chassis-hold1', 0),
                                      ('libxgc2-hover-thrust-core0', 0),
                                      ('xgc2-protobuf-dev', 0), ('xgc2-acados', 0),
                                      ('ros-noetic-xgc2-ros-msgs', 0),
                                      ('ros-melodic-scout-msgs', 0),
                                      ('ros-noetic-xgc2-ros1-utils', 0),
                                      ('xgc2-agent', 1),
                                      ('ros-noetic-xgc2-px4-multirotor-adapter', 1),
                                      ('ros-noetic-xgc2-ugv-controller', 1),
                                      ('xsim', 1), ('libxgc2-sensing-gpu', 1),
                                      ('ros-melodic-scout-base', 1), ('nvidia-driver-550', 1)]:
                with self.subTest(package=package):
                    env = dict(os.environ, PATH=str(root)+':'+os.environ['PATH'], PACKAGE_STATE=package+'\tinstalled')
                    result = subprocess.run(['bash', str(ROOT/'onboard-baseline/assert-base-only.sh')], env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, expected, result.stdout+result.stderr)
            for profile, expected in [('fs150-focal-noetic', 0), ('scout-focal-noetic', 1)]:
                env['ONBOARD_BASELINE_PROFILE'] = profile
                env['PACKAGE_STATE'] = 'ros-noetic-xgc2-gazebo-sim-fs150-sitl\tinstalled'
                result = subprocess.run(['bash', str(ROOT/'onboard-baseline/assert-base-only.sh')], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)
            env['ONBOARD_BASELINE_PROFILE'] = 'fs150-focal-noetic'
            env['PACKAGE_STATE'] = 'ros-noetic-xgc2-runtime-sync\tinstalled'
            result = subprocess.run(['bash', str(ROOT/'onboard-baseline/assert-base-only.sh')], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            env['ONBOARD_BASELINE_PROFILE'] = 'scout-focal-noetic'
            env['PACKAGE_STATE'] = 'ros-noetic-xgc2-runtime-sync\tinstalled'
            result = subprocess.run(['bash', str(ROOT/'onboard-baseline/assert-base-only.sh')], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout+result.stderr)
            env['ONBOARD_BASELINE_PROFILE'] = 'fs150-focal-noetic'
            env['PACKAGE_STATE'] = 'ros-noetic-xgc2-runtime-sync\tinstalled\nxgc2-agent\tinstalled'
            result = subprocess.run(['bash', str(ROOT/'onboard-baseline/assert-base-only.sh')], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout+result.stderr)
            env['PACKAGE_STATE'] = 'ros-noetic-xgc2-runtime-sync\tinstalled\nros-noetic-xgc2-px4-multirotor-adapter\tinstalled'
            result = subprocess.run(['bash', str(ROOT/'onboard-baseline/assert-base-only.sh')], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout+result.stderr)
            env['PACKAGE_STATE'] = 'libxgc2-xrpc-dev\tinstalled\nxgc2-agent\tinstalled'
            result = subprocess.run(['bash', str(ROOT/'onboard-baseline/assert-base-only.sh')], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout+result.stderr)

    def test_all_profiles_leave_iterated_products_out_of_the_base(self):
        profiles = {name: {} for name in ('fs150-focal-noetic', 'scout-bionic-melodic', 'scout-focal-noetic', 'wheeltec-bionic-melodic')}
        for profile, config in profiles.items():
            with self.subTest(profile=profile):
                text = (ROOT/'apps'/('onboard-sim-'+profile)/'Dockerfile').read_text()
                for forbidden in ('install-agent', 'install-xsim', 'install-sitl', 'agentdeb', 'AGENT_INSTALL', 'image-entrypoint.sh'):
                    self.assertNotIn(forbidden, text)
                self.assertIn('/opt/xgc2/onboard-baseline/assert-base-only.sh', text)
                self.assertIn('ENTRYPOINT ["/ros_entrypoint.sh"]', text)
                self.assertIn('COPY --from=tool-scripts onboard-baseline/baselines.json', text)
                self.assertIn('/usr/sbin/policy-rc.d', text)
                app = (ROOT/'apps'/('onboard-sim-'+profile)/'app.yml').read_text()
                if profile == 'fs150-focal-noetic':
                    self.assertIn('version: runtime\n', app)
                    self.assertIn('  - builder\n', app)
                    self.assertIn('FROM runtime AS builder', text)
                else:
                    self.assertIn('version: latest\n', app)
                    self.assertIn(':latest\n', app)


class NetworkDatabasesTest(unittest.TestCase):
    def test_missing_files_and_wrong_protocols_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            protocols = root/'protocols'; services = root/'services'
            protocols.write_text('fixture'); services.write_text('fixture')
            script = root/'check.sh'
            script.write_text(SCRIPT.read_text().replace('/etc/protocols', str(protocols))
                              .replace('/etc/services', str(services)))
            binary = root/'bin'; binary.mkdir()
            getent = binary/'getent'
            getent.write_text('#!/bin/sh\ncase "$2" in tcp) echo "tcp ${TCP_NUMBER:-6}";; udp) echo "udp ${UDP_NUMBER:-17}";; *) exit 2;; esac\n')
            getent.chmod(0o755)
            env = dict(os.environ, PATH=str(binary)+':/usr/bin:/bin')
            def run(overrides=None):
                return subprocess.run(['bash', str(script)], env=dict(env, **(overrides or {})),
                                      capture_output=True, text=True)
            self.assertEqual(run().returncode, 0)
            self.assertIn('tcp=6', run({'TCP_NUMBER':'7'}).stderr)
            self.assertIn('udp=17', run({'UDP_NUMBER':'18'}).stderr)
            services.unlink()
            self.assertIn('services', run().stderr)
            protocols.unlink()
            self.assertIn('protocols', run().stderr)

class MavrosVisionPluginTest(unittest.TestCase):
    def test_plugin_export_class_and_library_are_required(self):
        import importlib.util
        path = ROOT/'apps/onboard-sim-fs150-focal-noetic/check-mavros-vision-plugin.py'
        spec = importlib.util.spec_from_file_location('vision_plugin_check', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as temporary:
            prefix = Path(temporary)
            package_dir = prefix/'share/mavros_extras'; package_dir.mkdir(parents=True)
            library_dir = prefix/'lib'; library_dir.mkdir()
            manifest = package_dir/'package.xml'
            xml = package_dir/'mavros_plugins.xml'
            library = library_dir/'libmavros_extras.so'
            manifest.write_text('<package><export><mavros plugin="${prefix}/mavros_plugins.xml"/></export></package>')
            xml.write_text('<library path="lib/libmavros_extras"><class name="vision_pose_estimate" '
                           'type="mavros::extra_plugins::VisionPoseEstimatePlugin" '
                           'base_class_type="mavros::plugin::PluginBase"/></library>')
            library.write_bytes(b'fixture')
            module.check(prefix)
            xml.write_text(xml.read_text().replace('vision_pose_estimate', 'another_plugin'))
            with self.assertRaisesRegex(ValueError, 'class is missing'): module.check(prefix)
            xml.write_text(xml.read_text().replace('another_plugin', 'vision_pose_estimate'))
            manifest.write_text('<package><export/></package>')
            with self.assertRaisesRegex(ValueError, 'export is missing'): module.check(prefix)
            manifest.write_text('<package><export><mavros plugin="${prefix}/mavros_plugins.xml"/></export></package>')
            library.unlink()
            with self.assertRaisesRegex(ValueError, 'libmavros_extras'): module.check(prefix)
