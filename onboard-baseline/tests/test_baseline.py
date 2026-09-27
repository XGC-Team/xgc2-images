#!/usr/bin/env python3
"""Offline process/fixture tests; not evidence of ROS, Docker or hardware success."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

BASELINE = Path(__file__).resolve().parents[1]
PROFILES = json.loads((BASELINE / 'baselines.json').read_text())['profiles']

# Intercept package/service mutations. Only paths in a disposable script copy
# are relocated; production gets no test-only skip-check or alternate ROS root.
STUB = r'''#!/usr/bin/python3
import json, os, pathlib, subprocess, sys
root = pathlib.Path(ROOT_LITERAL)
state = json.loads((root / 'state.json').read_text())
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with (root / 'calls.jsonl').open('a') as f:
    f.write(json.dumps([name, args, os.environ.get('HOME')]) + '\n')
def save():
    (root / 'state.json').write_text(json.dumps(state))
if name == 'id':
    if args == ['-u']: print(state.get('uid', '0'))
    elif args == ['-un']: print('robot-user')
    elif args[:1] == ['-gn']: print('robot-user')
    elif args[-1] != 'robot-user': sys.exit(1)
elif name == 'dpkg':
    if args == ['--print-architecture']:
        if state.get('arch_failure'): sys.exit(1)
        print(state['arch'])
    elif args[:1] == ['-i']:
        state['installed'].append('xgc2-agent'); save()
    else: sys.exit(91)
elif name == 'dpkg-query':
    if args[-1] not in state['installed']: sys.exit(1)
    if '${Status}' in args[1]: print('install ok installed', end='')
    elif '${Version}' == args[1][3:]: print('1.0', end='')
    else: print('manual\t%s\t1.0\t%s' % (args[-1], state['arch']))
elif name == 'apt-mark':
    print('\n'.join(state['installed']))
elif name == 'apt-get':
    if state.get('apt_failure'): sys.exit(100)
    if args[0] == 'install':
        state['installed'] += [a for a in args[1:] if not a.startswith('-')]
        save()
elif name == 'install-ros-apt-source.sh':
    (root / 'etc/apt/sources.list.d/ros1.list').write_text('fixture source\n')
elif name == 'geographiclib-get-geoids':
    if state.get('geoid_download_failure'): sys.exit(9)
    (root / 'usr/share/GeographicLib/geoids/egm96-5.pgm').write_text('valid fixture')
elif name == 'rosversion':
    print(state.get('rosversion', os.environ['ROS_DISTRO']))
elif name == 'rospack':
    if args[-1] == state.get('missing_ros_package'): sys.exit(1)
    cache = pathlib.Path(os.environ['HOME']) / '.ros'
    cache.mkdir(exist_ok=True); (cache / 'rospack_cache').write_text('fixture')
    print('/fixture/' + args[-1])
elif name in ('python', 'python3'):
    if state.get('python_failure'): sys.exit(1)
elif name == 'ldd':
    print('libmavconn.so => not found' if state.get('missing_library') else 'libc.so => /lib/libc.so')
    if state.get('ldd_failure'): sys.exit(1)
elif name == 'roslaunch':
    if args != ['--files', 'mavros', 'px4.launch'] or state.get('launch_failure'): sys.exit(1)
elif name == 'GeoidEval':
    if (root / 'usr/share/GeographicLib/geoids/egm96-5.pgm').read_text() != 'valid fixture': sys.exit(1)
    print('17.16')
elif name == 'getent':
    print('robot-user:x:1000:1000::%s:/bin/bash' % (root / 'home'))
elif name == 'install':
    i = 0
    while i < len(args):
        if args[i] in ('-o', '-g', '-m'): i += 2; continue
        if not args[i].startswith('-'): pathlib.Path(args[i]).mkdir(parents=True, exist_ok=True)
        i += 1
elif name == 'runuser':
    sys.exit(subprocess.call(args[args.index('--') + 1:]))
elif name in ('configure-agent-user', 'xgc-agent'):
    pass
else:
    # Any unexpected mutation/network command is a test failure.
    sys.exit(92)
'''


class BaselineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for path in ('bin', 'runtime-bin', 'home', 'etc/apt/sources.list.d',
                     'etc/xgc2', 'usr/share/GeographicLib/geoids', 'usr/lib/xgc2'):
            (self.root / path).mkdir(parents=True)
        self.script = self.root / 'onboard-baseline.sh'
        self.script.write_text(self.relocate((BASELINE / 'onboard-baseline.sh').read_text()))
        self.script.chmod(0o755)
        (self.root / 'baselines.json').write_bytes((BASELINE / 'baselines.json').read_bytes())
        stub = self.root / 'stub.py'
        stub.write_text(STUB.replace('ROOT_LITERAL', repr(str(self.root))))
        stub.chmod(0o755)
        for name in ('id', 'dpkg', 'dpkg-query', 'apt-mark', 'apt-get',
                     'geographiclib-get-geoids', 'getent', 'install', 'runuser',
                     'curl', 'gpg', 'systemctl', 'useradd'):
            (self.root / 'bin' / name).symlink_to(stub)
        for name in ('rosversion', 'rospack', 'python', 'python3', 'ldd', 'roslaunch', 'GeoidEval'):
            (self.root / 'runtime-bin' / name).symlink_to(stub)
        for path in ('install-ros-apt-source.sh', 'usr/lib/xgc2/configure-agent-user', 'usr/lib/xgc2/xgc-agent'):
            (self.root / path).symlink_to(stub)
        self.env = {'PATH': str(self.root / 'bin') + ':/usr/bin:/bin',
                    'HOME': str(self.root / 'home'), 'LANG': 'C.UTF-8',
                    'ONBOARD_BASELINE_OS_RELEASE': str(self.root / 'os-release')}
        self.configure('fs150-focal-noetic')

    def relocate(self, text):
        for path in ('/opt/ros', '/usr/share/GeographicLib', '/usr/share/xgc2-agent',
                     '/usr/lib/xgc2', '/etc/apt', '/etc/xgc2', '/etc/sudoers.d',
                     '/run/systemd', '/run/xgc2'):
            text = text.replace(path, str(self.root) + path)
        return text

    def configure(self, profile, arch='amd64'):
        self.profile = profile
        p = PROFILES[profile]
        self.state = {'arch': arch, 'installed': p['packages'][:]}
        self.save()
        (self.root / 'os-release').write_text('ID=ubuntu\nVERSION_CODENAME=%s\nVERSION_ID=%s\n' %
                                              (p['ubuntuCodename'], p['ubuntuVersionId']))
        ros = self.root / 'opt/ros' / p['rosDistro']
        (ros / 'lib/mavros').mkdir(parents=True, exist_ok=True)
        (ros / 'lib/mavros/mavros_node').write_text('fixture executable')
        (ros / 'lib/mavros/mavros_node').chmod(0o755)
        (ros / 'setup.bash').write_text(
            '[[ -z "${ROS_DISTRO:-}${ROS_PACKAGE_PATH:-}${CMAKE_PREFIX_PATH:-}${PYTHONPATH:-}${LD_LIBRARY_PATH:-}${ROS_MASTER_URI:-}" ]] || exit 70\n'
            'export ROS_DISTRO=%s\nexport PATH=%s:$PATH\n' %
            (p['rosDistro'], shlex.quote(str(self.root / 'runtime-bin'))))
        self.geoid = self.root / 'usr/share/GeographicLib/geoids/egm96-5.pgm'
        self.geoid.write_text('valid fixture')
        self.config = self.root / 'etc/xgc2/agent.env'
        self.config.write_text('XGC_AGENT_ID=existing-robot\n# preserve user configuration\n')
        (self.root / 'calls.jsonl').write_text('')

    def save(self):
        (self.root / 'state.json').write_text(json.dumps(self.state))

    def calls(self, name=None):
        rows = [json.loads(line) for line in (self.root / 'calls.jsonl').read_text().splitlines()]
        return [r for r in rows if name is None or r[0] == name]

    def invoke(self, *args, expected=0, env=None):
        result = subprocess.run(['bash', str(self.script), *args], env=env or self.env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def check(self, expected=0):
        return self.invoke('check', '--profile', self.profile, expected=expected)

    def apply(self, expected=0):
        return self.invoke('apply', '--profile', self.profile, expected=expected)

    def test_all_profiles_and_architectures_load_without_sourced_shell(self):
        for profile in PROFILES:
            for arch in ('amd64', 'arm64'):
                with self.subTest(profile=profile, arch=arch):
                    self.configure(profile, arch)
                    result = self.check()
                    self.assertIn('arch=%s user=robot-user' % arch, result.stdout)
                    python = 'python' if PROFILES[profile]['rosDistro'] == 'melodic' else 'python3'
                    self.assertTrue(self.calls(python))
                    self.assertEqual(self.calls('apt-get'), [])

    def test_melodic_can_read_metadata_before_python3_is_installed(self):
        self.configure('scout-bionic-melodic')
        self.state['installed'].remove('python3'); self.save()
        # Hide python3 only from the shell's availability probe. The fallback
        # uses the host interpreter for this offline test, not a real Python 2.
        wrapper = self.root / 'bootstrap-shell'
        wrapper.write_text('command() { if [[ "$*" == "-v python3" ]]; then return 1; fi; builtin command "$@"; }\n')
        (self.root / 'bin/python').symlink_to('/usr/bin/python3')
        self.env['BASH_ENV'] = str(wrapper)
        self.apply()
        self.assertEqual(self.calls('apt-get')[-1][1],
                         ['install', '-y', '--no-install-recommends', '--no-remove', 'python3'])

    def test_unknown_profile_fails_before_side_effects_even_with_inherited_values(self):
        self.env.update(ubuntu_codename='focal', ubuntu_version_id='20.04', ros_distro='noetic')
        result = self.invoke('apply', '--profile', 'not-a-profile', expected=2)
        self.assertIn('invalid or unknown profile', result.stderr)
        self.assertEqual(self.calls(), [])

    def test_malformed_json_fails_without_eval_or_install(self):
        (self.root / 'baselines.json').write_text('{broken')
        self.apply(expected=2)
        self.assertEqual(self.calls(), [])

    def test_incomplete_profile_fails_before_install(self):
        doc = json.loads((self.root / 'baselines.json').read_text())
        del doc['profiles'][self.profile]['architectures']
        (self.root / 'baselines.json').write_text(json.dumps(doc))
        self.apply(expected=2)
        self.assertEqual(self.calls(), [])

    def test_cli_missing_values_have_usage_status(self):
        for args in ((), ('apply', '--profile'), ('apply', '--profile', '--user'),
                     ('install-agent', '--user'), ('manualdiff', '--before'),
                     ('manualdiff', '--after', '')):
            with self.subTest(args=args):
                self.assertIn('usage:', self.invoke(*args, expected=2).stderr)

    def test_wrong_ubuntu_suite_or_os_is_rejected_before_apt(self):
        for value in ('ID=debian\nVERSION_CODENAME=focal\nVERSION_ID=20.04\n',
                      'ID=ubuntu\nVERSION_CODENAME=bionic\nVERSION_ID=18.04\n',
                      'ID=ubuntu\nVERSION_CODENAME=focal\nVERSION_ID=22.04\n'):
            (self.root / 'os-release').write_text(value)
            self.apply(expected=3)
        self.assertEqual(self.calls(), [])

    def test_unsupported_architecture_is_rejected(self):
        self.state['arch'] = 'armhf'; self.save()
        self.assertIn('unsupported architecture', self.apply(expected=3).stderr)
        self.assertEqual(self.calls('apt-get'), [])

    def test_architecture_probe_failure_is_not_success(self):
        self.state['arch_failure'] = True; self.save()
        self.apply(expected=3)
        self.assertEqual(self.calls('apt-get'), [])

    def test_check_rejects_missing_debian_package(self):
        self.state['installed'].remove('ros-noetic-mavros'); self.save()
        self.assertIn('ros-noetic-mavros', self.check(expected=4).stderr)
        self.assertEqual(self.calls('rosversion'), [])
        self.assertEqual(self.calls('apt-get'), [])

    def test_check_rejects_missing_setup_despite_ambient_ros(self):
        (self.root / 'opt/ros/noetic/setup.bash').unlink()
        self.env['ROS_DISTRO'] = 'noetic'
        self.assertIn('missing ROS setup', self.check(expected=4).stderr)

    def test_check_discards_caller_overlay_and_cleans_only_temporary_home(self):
        self.env.update(ROS_DISTRO='melodic', ROS_PACKAGE_PATH='/wrong', PYTHONPATH='/wrong',
                        CMAKE_PREFIX_PATH='/wrong', LD_LIBRARY_PATH='/wrong', ROS_MASTER_URI='http://wrong:11311')
        before = self.config.read_bytes()
        self.check()
        self.assertEqual(self.config.read_bytes(), before)
        for row in self.calls('rospack'):
            self.assertFalse(Path(row[2]).exists(), 'temporary ROS cache home leaked')
        self.assertEqual(list((self.root / 'home').iterdir()), [])

    def test_wrong_loaded_ros_distro_is_rejected(self):
        self.state['rosversion'] = 'melodic'; self.save()
        self.check(expected=4)

    def test_missing_ros_package_is_rejected(self):
        self.state['missing_ros_package'] = 'nav_msgs'; self.save()
        self.check(expected=4)

    def test_python_import_failure_is_rejected(self):
        self.state['python_failure'] = True; self.save()
        self.check(expected=4)

    def test_missing_mavros_executable_is_rejected(self):
        (self.root / 'opt/ros/noetic/lib/mavros/mavros_node').unlink()
        self.check(expected=4)

    def test_mavros_missing_dynamic_library_is_rejected(self):
        self.state['missing_library'] = True; self.save()
        self.assertIn('libmavconn.so => not found', self.check(expected=4).stderr)

    def test_failed_dynamic_loader_check_is_rejected(self):
        self.state['ldd_failure'] = True; self.save()
        self.check(expected=4)

    def test_broken_mavros_launch_graph_is_rejected(self):
        self.state['launch_failure'] = True; self.save()
        self.check(expected=4)

    def test_missing_and_corrupt_geoid_are_rejected_without_repair(self):
        self.geoid.unlink()
        self.check(expected=4)
        self.geoid.write_text('nonempty but invalid geoid')
        self.check(expected=4)
        self.assertEqual(self.calls('geographiclib-get-geoids'), [])

    def test_apply_requires_privilege(self):
        self.state['uid'] = '1000'; self.save()
        self.apply(expected=1)
        self.assertEqual(self.calls('apt-get'), [])

    def test_apply_installs_only_missing_packages_then_is_noop(self):
        self.state['installed'].remove('curl'); self.save()
        before = self.config.read_bytes()
        self.apply(); self.apply()
        self.assertEqual([c[1] for c in self.calls('apt-get')],
                         [['update'], ['install', '-y', '--no-install-recommends', '--no-remove', 'curl']])
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(self.calls('useradd'), [])
        self.assertEqual(self.calls('systemctl'), [])

    def test_complete_apply_never_uses_apt_or_geoid_download(self):
        self.apply(); self.apply()
        self.assertEqual(self.calls('apt-get'), [])
        self.assertEqual(self.calls('geographiclib-get-geoids'), [])

    def test_geoid_installs_once_without_unnecessary_apt(self):
        self.geoid.unlink()
        self.apply(); self.apply()
        self.assertEqual(len(self.calls('geographiclib-get-geoids')), 1)
        self.assertEqual(self.calls('apt-get'), [])

    def test_apt_failure_is_propagated(self):
        self.state['installed'].remove('curl')
        self.state['apt_failure'] = True; self.save()
        self.assertNotIn('applied', self.apply(expected=100).stdout)

    def test_geoid_download_failure_is_propagated(self):
        self.geoid.unlink()
        self.state['geoid_download_failure'] = True; self.save()
        self.assertNotIn('applied', self.apply(expected=9).stdout)

    def test_install_agent_uses_existing_user_without_base_apt(self):
        deb = self.root / 'agent.deb'; deb.write_text('fixture deb')
        env = dict(self.env, ONBOARD_BASELINE_AGENT_DEB=str(deb))
        before = self.config.read_bytes()
        self.invoke('install-agent', '--user', 'robot-user', env=env)
        self.assertEqual(self.calls('dpkg')[0][1], ['-i', str(deb)])
        self.assertEqual(self.calls('configure-agent-user')[0][1], ['robot-user'])
        self.assertEqual(self.calls('apt-get'), [])
        self.assertEqual(self.config.read_bytes(), before)

    def test_install_agent_rejects_missing_or_unknown_user(self):
        self.invoke('install-agent', expected=2)
        self.invoke('install-agent', '--user', 'not-existing', expected=1)
        self.assertEqual(self.calls('apt-get'), [])
        self.assertEqual(self.calls('useradd'), [])

    def test_snapshot_and_manualdiff_remain_compatible(self):
        result = self.invoke('snapshot', '--profile', self.profile)
        self.assertIn('runtime_user=robot-user', result.stdout)
        self.assertIn('manual\t', result.stdout)
        before = self.root / 'before'; before.write_text(result.stdout)
        after = self.root / 'after'; after.write_text(result.stdout)
        self.invoke('manualdiff', '--before', str(before), '--after', str(after))
        after.write_text(result.stdout + 'manual\tadded-package\t1.0\tamd64\n')
        changed = self.invoke('manualdiff', '--before', str(before), '--after', str(after), expected=1)
        self.assertIn('removed=0 added=1', changed.stdout)
        self.assertEqual(self.calls('apt-get'), [])

    def test_normal_entrypoint_restart_never_calls_apply_or_apt(self):
        entry = self.root / 'entrypoint.sh'
        entry.write_text(self.relocate((BASELINE / 'image-entrypoint.sh').read_text()))
        env = dict(self.env, ONBOARD_BASELINE_USER='robot-user',
                   ONBOARD_BASELINE_AGENT_DEB='/nonexistent/unused.deb',
                   XGC_AGENT_DATA_DIR=str(self.root / 'data'),
                   XGC_AGENT_MANAGED_ROOT=str(self.root / 'managed'))
        for _ in range(2):
            result = subprocess.run(['bash', str(entry)], env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls('xgc-agent')), 2)
        for command in ('apt-get', 'dpkg', 'dpkg-query', 'geographiclib-get-geoids', 'useradd'):
            self.assertEqual(self.calls(command), [], command)
        self.assertTrue(all(row[1][0:2] == ['-u', 'robot-user'] or '--preserve-environment' in row[1]
                            for row in self.calls('runuser')))

    def test_dockerfiles_use_only_shared_apply_and_check_as_robot_user(self):
        for profile in PROFILES:
            text = (BASELINE.parent / ('apps/onboard-sim-%s/Dockerfile' % profile)).read_text()
            p = PROFILES[profile]
            self.assertIn('ARG PARENT_IMAGE=ros:%s-ros-core-%s' % (p['rosDistro'], p['ubuntuCodename']), text)
            self.assertIn('onboard-baseline.sh apply --profile ' + profile, text)
            self.assertIn('runuser -u "$ONBOARD_BASELINE_USER" -- /opt/xgc2/onboard-baseline/onboard-baseline.sh check', text)
            self.assertNotIn('apt-get install', text)
            self.assertNotIn('USER root', text)


if __name__ == '__main__':
    unittest.main(verbosity=2)
