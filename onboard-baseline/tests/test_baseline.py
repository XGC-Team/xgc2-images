#!/usr/bin/env python3
"""Offline process/fixture tests; not evidence of ROS, Docker or hardware success."""
import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import tarfile
import tempfile
import unittest

BASELINE = Path(__file__).resolve().parents[1]
PROFILES = json.loads((BASELINE / 'baselines.json').read_text())['profiles']
CANONICAL_GEOID_SHA256 = 'c46224f8f723dc915d97179f4e1580a98d6c742fe2b82cd8fef0ecaaad13e614'
CANONICAL_GEOID_URL = 'https://downloads.sourceforge.net/project/geographiclib/geoids-distrib/egm96-5.tar.bz2?use_mirror=autoselect'


def geoid_archive(members):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode='w:bz2') as archive:
        for name, payload in members:
            info = tarfile.TarInfo(name)
            info.size = len(payload)
            archive.addfile(info, io.BytesIO(payload))
    return raw.getvalue()


FIXTURE_GEOID_MEMBERS = (
    ('geoids/egm96-5.pgm', b'valid fixture'),
    ('geoids/egm96-5.wld', b'fixture wld\n'),
    ('geoids/egm96-5.pgm.aux.xml', b'<PAMDataset/>\n'),
)
FIXTURE_GEOID_ARCHIVE = geoid_archive(FIXTURE_GEOID_MEMBERS)
FIXTURE_GEOID_SHA256 = hashlib.sha256(FIXTURE_GEOID_ARCHIVE).hexdigest()
EMPTY_MEMBER_ARCHIVE = geoid_archive((
    ('geoids/egm96-5.pgm', b'valid fixture'),
    ('geoids/egm96-5.wld', b'fixture wld\n'),
    ('geoids/egm96-5.pgm.aux.xml', b''),
))
MISSING_MEMBER_ARCHIVE = geoid_archive((
    ('geoids/egm96-5.pgm', b'valid fixture'),
    ('geoids/egm96-5.wld', b'fixture wld\n'),
))

# Intercept package/service mutations. Only paths in a disposable script copy
# are relocated; production gets no test-only skip-check or alternate ROS root.
STUB = r'''#!/usr/bin/python3
import json, os, pathlib, shutil, subprocess, sys
root = pathlib.Path(ROOT_LITERAL)
state = json.loads((root / 'state.json').read_text())
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with (root / 'calls.jsonl').open('a') as f:
    f.write(json.dumps([name, args, os.environ.get('HOME')]) + '\n')
def save():
    (root / 'state.json').write_text(json.dumps(state))
if name == 'id':
    if args == ['-u']: print(state.get('uid', '0'))
    elif args == ['-un']: print(state.get('name', 'robot-user'))
    elif args[:1] == ['-gn']: print('robot-user')
    elif len(args) == 1 and not args[0].startswith('-'):
        accounts = state.get('accounts', ['robot-user', 'marvsmart', 'agilex', 'nvidia', 'wheeltec'])
        if args[0] == state.get('missing_user') or args[0] not in accounts: sys.exit(1)
    else: sys.exit(1)
elif name == 'dpkg':
    if args == ['--print-architecture']:
        if state.get('arch_failure'): sys.exit(1)
        print(state['arch'])
    elif args[:1] == ['-i']:
        state['installed'].append('xgc2-agent'); save()
    elif args[:1] == ['--compare-versions']:
        sys.exit(subprocess.call(['/usr/bin/dpkg'] + args))
    else: sys.exit(91)
elif name == 'dpkg-query':
    if args[-1] not in state['installed']: sys.exit(1)
    if '${Status}' in args[1]:
        print(state.get('package_status', {}).get(args[-1], 'install ok installed'), end='')
        if '${Version}' in args[1]:
            print('\t' + state.get('versions', {}).get(args[-1], '1.0'), end='')
        if state.get('query_failure'): sys.exit(1)
    elif '${Version}' == args[1][3:]: print(state.get('versions', {}).get(args[-1], '1.0'), end='')
    else: print('manual\t%s\t1.0\t%s' % (args[-1], state['arch']))
elif name == 'apt-mark':
    print('\n'.join(state['installed']))
elif name == 'apt-get':
    if state.get('apt_failure'): sys.exit(100)
    if args[0] == 'install':
        for spec in (a for a in args[1:] if not a.startswith('-')):
            package, separator, version = spec.partition('=')
            state['installed'].append(package)
            if separator: state.setdefault('versions', {})[package] = version
            elif package in state.get('available_versions', {}):
                state.setdefault('versions', {})[package] = state['available_versions'][package]
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
    cache = pathlib.Path(os.environ['ROS_HOME'])
    cache.mkdir(parents=True, exist_ok=True); (cache / 'rospack_cache').write_text('fixture')
    print('/fixture/' + args[-1])
elif name in ('python', 'python3'):
    if state.get('python_failure'): sys.exit(1)
elif name == 'ldd':
    if state.get('missing_library'): print('libmavconn.so => not found')
    elif state.get('gateway_missing_library') and 'adapter_node' in args[-1]: print('libgateway.so => not found')
    else: print('libc.so => /lib/libc.so')
    if state.get('ldd_failure'): sys.exit(1)
elif name == 'roslaunch':
    if args != ['--files', 'mavros', 'px4.launch'] or state.get('launch_failure'): sys.exit(1)
elif name == 'GeoidEval':
    if (root / 'usr/share/GeographicLib/geoids/egm96-5.pgm').read_text() != 'valid fixture': sys.exit(1)
    print('17.16')
elif name == 'getent':
    print('robot-user:x:1000:1000::%s:/bin/bash' % (root / 'home'))
elif name == 'curl':
    if state.get('curl_failure'): sys.exit(22)
    output = pathlib.Path(args[args.index('-o') + 1])
    if any('egm96-5.tar.bz2' in arg for arg in args):
        if state.get('geoid_download_failure'): sys.exit(9)
        if state.get('geoid_sha256_failure'):
            output.write_bytes(b'corrupt archive bytes')
        else:
            kind = state.get('geoid_archive', 'ok')
            output.write_bytes((root / ('fixture-geoid-%s.tar.bz2' % kind)).read_bytes())
    else:
        output.write_bytes(b'fixture signing key')
elif name == 'gpg':
    if '--show-keys' in args:
        print('gpg: invalid option "--show-keys"', file=sys.stderr); sys.exit(2)
    home = pathlib.Path(os.environ['GNUPGHOME'])
    state.setdefault('gpg_homes', []).append(str(home)); save()
    if home.stat().st_mode & 0o777 != 0o700: sys.exit(93)
    if '--import' in args:
        if state.get('gpg_import_failure'): sys.exit(2)
        if pathlib.Path(args[-1]).read_bytes() != b'fixture signing key': sys.exit(94)
        (home / 'imported').write_text('key imported')
    elif '--list-keys' in args:
        if not (home / 'imported').exists(): sys.exit(95)
        print('fpr:::::::::%s:' % state.get('gpg_fingerprint', '2A8E11B36F56D307ADF626D85E5FDC30979EA43F'))
    else: sys.exit(96)
elif name == 'install':
    paths = []
    i = 0
    while i < len(args):
        if args[i] in ('-o', '-g', '-m'): i += 2; continue
        if not args[i].startswith('-'): paths.append(pathlib.Path(args[i]))
        i += 1
    if '-d' in args:
        for path in paths: path.mkdir(parents=True, exist_ok=True)
    else:
        shutil.copyfile(paths[0], paths[1])
        if '-m' in args: paths[1].chmod(int(args[args.index('-m') + 1], 8))
elif name == 'runuser':
    sys.exit(subprocess.call(args[args.index('--') + 1:]))
elif name == 'xgc-agent':
    (root / 'agent-env.json').write_text(json.dumps({
        'argv': args, 'id': os.environ.get('XGC_AGENT_ID'),
        'core': os.environ.get('XGC_CORE_ENDPOINT'),
        'catalog': os.environ.get('XGC_PROCESS_DEFINITION_PLUGINS'),
        'adapter': os.environ.get('XGC_ADAPTER_RUNTIME_UDS')}))
elif name == 'configure-agent-user':
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
        return text.replace(CANONICAL_GEOID_SHA256, FIXTURE_GEOID_SHA256)

    def geoid_curls(self):
        return [row for row in self.calls('curl') if any('egm96-5.tar.bz2' in arg for arg in row[1])]

    def pin_disposable(self, digest):
        text = self.script.read_text()
        self.assertIn(FIXTURE_GEOID_SHA256, text)
        self.assertNotIn(CANONICAL_GEOID_SHA256, text)
        self.script.write_text(text.replace(FIXTURE_GEOID_SHA256, digest))

    def configure(self, profile, arch='amd64'):
        self.profile = profile
        p = PROFILES[profile]
        self.state = {'arch': arch, 'installed': p['packages'][:],
                      'versions': p.get('minimumVersions', {}).copy()}
        self.save()
        (self.root / 'os-release').write_text('ID=ubuntu\nVERSION_CODENAME=%s\nVERSION_ID=%s\n' %
                                              (p['ubuntuCodename'], p['ubuntuVersionId']))
        ros = self.root / 'opt/ros' / p['rosDistro']
        (ros / 'lib/mavros').mkdir(parents=True, exist_ok=True)
        (ros / 'lib/mavros/mavros_node').write_text('fixture executable')
        (ros / 'lib/mavros/mavros_node').chmod(0o755)
        for package in ('xgc_px4_multirotor_ros1_adapter', 'xgc_ugv_ros1_adapter'):
            node = ros / 'lib' / package / (package + '_node')
            node.parent.mkdir(parents=True, exist_ok=True)
            node.write_text('fixture executable')
            node.chmod(0o755)
        (ros / 'setup.bash').write_text(
            '[[ -z "${ROS_DISTRO:-}${ROS_PACKAGE_PATH:-}${CMAKE_PREFIX_PATH:-}${PYTHONPATH:-}${LD_LIBRARY_PATH:-}${ROS_MASTER_URI:-}" ]] || exit 70\n'
            'export ROS_DISTRO=%s\nexport PATH=%s:$PATH\n' %
            (p['rosDistro'], shlex.quote(str(self.root / 'runtime-bin'))))
        self.geoid = self.root / 'usr/share/GeographicLib/geoids/egm96-5.pgm'
        self.geoid.write_text('valid fixture')
        self.config = self.root / 'etc/xgc2/agent.env'
        self.config.write_text('XGC_AGENT_ID=existing-robot\n# preserve user configuration\n')
        (self.root / 'calls.jsonl').write_text('')
        (self.root / 'fixture-geoid-ok.tar.bz2').write_bytes(FIXTURE_GEOID_ARCHIVE)
        (self.root / 'fixture-geoid-empty-member.tar.bz2').write_bytes(EMPTY_MEMBER_ARCHIVE)
        (self.root / 'fixture-geoid-missing-member.tar.bz2').write_bytes(MISSING_MEMBER_ARCHIVE)

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

    def root_namespace(self):
        if os.geteuid() == 0:
            return []
        probe = subprocess.run(['unshare', '--user', '--map-root-user', 'true'],
                               capture_output=True, text=True)
        if probe.returncode != 0:
            self.skipTest('user namespace is not permitted here: ' + probe.stderr.strip())
        return ['unshare', '--user', '--map-root-user', '--']

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

    def test_missing_os_fields_cannot_use_inherited_values(self):
        (self.root / 'os-release').write_text('ID=ubuntu\n')
        self.env.update(VERSION_ID='20.04', VERSION_CODENAME='focal')
        self.apply(expected=3)
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

    def test_failed_dpkg_query_is_not_installed(self):
        self.state['query_failure'] = True; self.save()
        self.check(expected=4)
        self.assertEqual(self.calls('rosversion'), [])
        self.assertEqual(self.calls('apt-get'), [])

    def test_installed_held_packages_are_not_reinstalled(self):
        self.state['package_status'] = {'curl': 'hold ok installed'}; self.save()
        self.check()
        self.apply()
        self.assertEqual(self.calls('apt-get'), [])

    def test_incomplete_package_states_are_not_installed(self):
        for status in ('install ok unpacked', 'install reinstreq half-installed'):
            with self.subTest(status=status):
                self.state['package_status'] = {'curl': status}; self.save()
                self.check(expected=4)
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
        self.assertEqual(self.geoid_curls(), [])

    def test_canonical_geoid_pin_stays_on_the_observed_archive(self):
        text = (BASELINE / 'onboard-baseline.sh').read_text()
        self.assertIn(CANONICAL_GEOID_SHA256, text)
        self.assertIn(CANONICAL_GEOID_URL, text)
        self.assertIn('curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 --retry-max-time 300 ', text)
        self.assertNotIn(FIXTURE_GEOID_SHA256, text)
        self.assertNotIn('geographiclib-get-geoids', text)
        disposable = self.script.read_text()
        self.assertIn(FIXTURE_GEOID_SHA256, disposable)
        self.assertNotIn(CANONICAL_GEOID_SHA256, disposable)

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
        self.assertEqual(self.geoid_curls(), [])

    def test_geoid_installs_once_without_unnecessary_apt(self):
        self.geoid.unlink()
        temporary = self.root / 'geoid-tmp'
        temporary.mkdir()
        self.env['TMPDIR'] = str(temporary)
        self.apply()
        self.assertEqual(list(temporary.iterdir()), [])
        geoid = self.geoid.parent
        self.assertEqual((geoid / 'egm96-5.pgm').read_bytes(), b'valid fixture')
        self.assertEqual((geoid / 'egm96-5.wld').read_bytes(), b'fixture wld\n')
        self.assertEqual((geoid / 'egm96-5.pgm.aux.xml').read_bytes(), b'<PAMDataset/>\n')
        for name in ('egm96-5.pgm', 'egm96-5.wld', 'egm96-5.pgm.aux.xml'):
            self.assertEqual((geoid / name).stat().st_mode & 0o777, 0o644)
        self.check()
        self.apply()
        curls = self.geoid_curls()
        self.assertEqual(len(curls), 1)
        argv = curls[0][1]
        self.assertIn(CANONICAL_GEOID_URL, argv)
        self.assertEqual(argv[argv.index('--retry') + 1], '2')
        self.assertEqual(argv[argv.index('--connect-timeout') + 1], '10')
        self.assertEqual(argv[argv.index('--max-time') + 1], '120')
        self.assertEqual(argv[argv.index('--retry-max-time') + 1], '300')
        self.assertEqual(self.calls('geographiclib-get-geoids'), [])
        self.assertEqual(self.calls('apt-get'), [])
        self.assertEqual(list(temporary.iterdir()), [])

    def test_apt_failure_is_propagated(self):
        self.state['installed'].remove('curl')
        self.state['apt_failure'] = True; self.save()
        self.assertNotIn('applied', self.apply(expected=100).stdout)

    def test_geoid_download_failure_is_propagated(self):
        self.geoid.unlink()
        temporary = self.root / 'geoid-tmp'
        temporary.mkdir()
        self.env['TMPDIR'] = str(temporary)
        self.state['geoid_download_failure'] = True; self.save()
        self.assertNotIn('applied', self.apply(expected=9).stdout)
        self.assertFalse(self.geoid.exists())
        self.assertEqual(list(temporary.iterdir()), [])
        self.assertEqual(self.calls('geographiclib-get-geoids'), [])

    def test_geoid_sha256_mismatch_is_propagated(self):
        self.geoid.unlink()
        temporary = self.root / 'geoid-tmp'
        temporary.mkdir()
        self.env['TMPDIR'] = str(temporary)
        self.state['geoid_sha256_failure'] = True; self.save()
        result = self.apply(expected=1)
        self.assertNotIn('applied', result.stdout)
        self.assertIn('EGM96-5 archive SHA256 mismatch', result.stderr)
        self.assertFalse(self.geoid.exists())
        self.assertFalse((self.geoid.parent / 'egm96-5.wld').exists())
        self.assertFalse((self.geoid.parent / 'egm96-5.pgm.aux.xml').exists())
        self.assertEqual(list(temporary.iterdir()), [])

    def test_geoid_empty_member_installs_nothing(self):
        self.geoid.unlink()
        temporary = self.root / 'geoid-tmp'
        temporary.mkdir()
        self.env['TMPDIR'] = str(temporary)
        self.pin_disposable(hashlib.sha256(EMPTY_MEMBER_ARCHIVE).hexdigest())
        self.state['geoid_archive'] = 'empty-member'; self.save()
        result = self.apply(expected=1)
        self.assertNotIn('applied', result.stdout)
        self.assertIn('egm96-5.pgm.aux.xml', result.stderr)
        self.assertFalse(self.geoid.exists())
        self.assertFalse((self.geoid.parent / 'egm96-5.wld').exists())
        self.assertFalse((self.geoid.parent / 'egm96-5.pgm.aux.xml').exists())
        self.assertEqual(list(temporary.iterdir()), [])

    def test_geoid_missing_member_installs_nothing(self):
        self.geoid.unlink()
        temporary = self.root / 'geoid-tmp'
        temporary.mkdir()
        self.env['TMPDIR'] = str(temporary)
        self.pin_disposable(hashlib.sha256(MISSING_MEMBER_ARCHIVE).hexdigest())
        self.state['geoid_archive'] = 'missing-member'; self.save()
        result = self.apply(expected=2)
        self.assertNotIn('applied', result.stdout)
        self.assertFalse(self.geoid.exists())
        self.assertFalse((self.geoid.parent / 'egm96-5.wld').exists())
        self.assertEqual(list(temporary.iterdir()), [])

    def test_install_agent_uses_existing_user_without_base_apt(self):
        self.state['installed'].append('xgc2-agent'); self.save()
        before = self.config.read_bytes()
        self.invoke('install-agent', '--user', 'robot-user')
        self.assertEqual(self.calls('configure-agent-user')[0][1], ['robot-user'])
        self.assertEqual(self.calls('apt-get'), [])
        self.assertEqual(self.calls('dpkg'), [])
        self.assertEqual(self.config.read_bytes(), before)

    def test_xsim_installs_the_formal_runtime_pair_once_on_both_architectures(self):
        self.env['ONBOARD_BASELINE_XSIM_VERSION'] = '1.4.0-4'
        for arch in ('amd64', 'arm64'):
            with self.subTest(arch=arch):
                self.configure('fs150-focal-noetic', arch)
                before = self.config.read_bytes()
                self.invoke('install-xsim', '--profile', self.profile)
                self.assertEqual(self.calls('apt-get')[-1][1], [
                    'install', '-y', '--no-install-recommends',
                    'xsim=1.4.0-4', 'libxgc2-sensing-gpu=1.4.0-4'])
                installed = self.calls('apt-get')
                self.invoke('install-xsim', '--profile', self.profile)
                self.assertEqual(self.calls('apt-get'), installed)
                self.assertEqual(self.calls('configure-agent-user'), [])
                self.assertEqual(self.config.read_bytes(), before)

    def test_xsim_repairs_only_the_missing_or_wrong_version_runtime(self):
        self.env['ONBOARD_BASELINE_XSIM_VERSION'] = '1.4.0-4'
        self.state['installed'] += ['xsim', 'libxgc2-sensing-gpu']
        self.state['versions'] = {'xsim': '1.4.0-4', 'libxgc2-sensing-gpu': '1.4.0-3'}
        self.save()
        self.invoke('install-xsim', '--profile', self.profile)
        self.assertEqual(self.calls('apt-get')[-1][1], [
            'install', '-y', '--no-install-recommends', 'libxgc2-sensing-gpu=1.4.0-4'])

    def test_xsim_requires_an_explicit_version_without_its_own_default(self):
        self.invoke('install-xsim', '--profile', self.profile, expected=2)
        self.assertEqual(self.calls('apt-get'), [])
        self.env['ONBOARD_BASELINE_XSIM_VERSION'] = '1.4.0-5'
        self.invoke('install-xsim', '--profile', self.profile)
        self.assertEqual(self.calls('apt-get')[-1][1], [
            'install', '-y', '--no-install-recommends',
            'xsim=1.4.0-5', 'libxgc2-sensing-gpu=1.4.0-5'])

    def test_xsim_does_not_extend_other_robot_profiles(self):
        for profile in PROFILES:
            if profile == 'fs150-focal-noetic':
                continue
            with self.subTest(profile=profile):
                self.configure(profile)
                self.invoke('install-xsim', '--profile', profile, expected=2)
                self.assertEqual(self.calls('apt-get'), [])

    def test_agent_version_uses_the_existing_explicit_version_parameter(self):
        env = dict(self.env, ONBOARD_BASELINE_AGENT_VERSION='0.1.0-11')
        self.invoke('install-agent', '--profile', self.profile, '--user', 'marvsmart', env=env)
        self.assertEqual(self.calls('apt-get')[-1][1], [
            'install', '-y', '--no-install-recommends', 'xgc2-agent=0.1.0-11'])

    def test_fresh_agent_install_verifies_key_in_isolated_home_for_bionic_and_focal(self):
        temporary = self.root / 'temporary'
        temporary.mkdir()
        caller_home = self.root / 'caller-gnupg'
        caller_home.mkdir()
        (caller_home / 'keep').write_text('caller keyring')
        env = dict(self.env, TMPDIR=str(temporary), GNUPGHOME=str(caller_home))
        for profile in ('scout-bionic-melodic', 'wheeltec-bionic-melodic', 'fs150-focal-noetic'):
            with self.subTest(profile=profile):
                self.configure(profile)
                source = self.root / 'etc/apt/sources.list.d/xgc2.list'
                if source.exists():
                    source.unlink()
                before = self.config.read_bytes()
                self.invoke('install-agent', '--profile', profile, '--user', PROFILES[profile]['username'], env=env)
                apt_calls = self.calls('apt-get')
                self.state = json.loads((self.root / 'state.json').read_text())
                self.assertIn('xgc2-agent', self.state['installed'])
                self.assertEqual(apt_calls[1][1], ['install', '-y', '--no-install-recommends', 'xgc2-agent'])
                self.assertEqual(len(apt_calls), 2)
                self.assertIn(PROFILES[profile]['ubuntuCodename'] + ' main', source.read_text())
                key = self.root / 'etc/apt/keyrings/xgc2-archive-keyring.gpg'
                self.assertEqual(key.read_bytes(), b'fixture signing key')
                self.assertEqual(key.stat().st_mode & 0o777, 0o644)
                self.assertEqual(len(self.calls('gpg')), 2)
                self.assertTrue(all(not Path(home).exists() for home in self.state['gpg_homes']))
                self.assertEqual(list(temporary.iterdir()), [])
                self.assertEqual((caller_home / 'keep').read_text(), 'caller keyring')
                self.assertEqual(self.config.read_bytes(), before)

    def test_fresh_agent_install_rejects_key_failures_and_cleans_temporary_home(self):
        temporary = self.root / 'temporary'
        temporary.mkdir()
        env = dict(self.env, TMPDIR=str(temporary))
        for failure, value, expected in (('gpg_fingerprint', 'BAD', 1),
                                         ('gpg_import_failure', True, 2), ('curl_failure', True, 22)):
            with self.subTest(failure=failure):
                self.configure('scout-bionic-melodic')
                self.state[failure] = value
                self.save()
                result = self.invoke('install-agent', '--profile', self.profile,
                                     '--user', 'agilex', env=env, expected=expected)
                if failure == 'gpg_fingerprint':
                    self.assertIn('fingerprint mismatch', result.stderr)
                self.assertEqual(self.calls('apt-get'), [])
                self.assertFalse((self.root / 'etc/apt/sources.list.d/xgc2.list').exists())
                self.assertFalse((self.root / 'etc/apt/keyrings/xgc2-archive-keyring.gpg').exists())
                self.assertEqual(list(temporary.iterdir()), [])

    def test_copied_agent_package_is_refused(self):
        deb = self.root / 'agent.deb'; deb.write_text('fixture deb')
        env = dict(self.env, ONBOARD_BASELINE_AGENT_DEB=str(deb))
        self.assertIn('copied agent package', self.invoke('install-agent', '--user', 'robot-user', env=env, expected=1).stderr)
        self.assertEqual(self.calls('dpkg'), [])
        self.assertEqual(self.calls('apt-get'), [])

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
                   XGC_AGENT_ID='w06-entrypoint-robot',
                   XGC_CORE_ENDPOINT='127.0.0.1:19102',
                   XGC_AGENT_ADVERTISED_ENDPOINT='127.0.0.1:19090',
                   XGC_AGENT_DATA_DIR=str(self.root / 'data'),
                   XGC_AGENT_MANAGED_ROOT=str(self.root / 'managed'))
        # The production entrypoint prepares directories as root. Use a user
        # namespace when running this command-fixture test without privilege.
        prefix = self.root_namespace()
        for _ in range(2):
            result = subprocess.run(prefix + ['bash', str(entry)], env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls('xgc-agent')), 2)
        for command in ('apt-get', 'dpkg', 'dpkg-query', 'geographiclib-get-geoids', 'useradd'):
            self.assertEqual(self.calls(command), [], command)
        self.assertTrue(all(row[1][0:2] == ['-u', 'robot-user'] or '--preserve-environment' in row[1]
                            for row in self.calls('runuser')))

    def test_entrypoint_initializes_owned_data_and_preserves_identity_files(self):
        text = (BASELINE / 'image-entrypoint.sh').read_text()
        block = text[text.index('data_dir="${XGC_AGENT_DATA_DIR:'):text.index('# This permission applies')]
        # Exercise the exact directory-preparation body with real install/stat,
        # as the test account; no namespace privilege, daemon, APT or host paths.
        block = self.relocate(block)
        for state in ('missing', 'empty', 'saved-private', 'saved-insecure'):
            with self.subTest(state=state):
                data = self.root / state
                managed = self.root / (state + '-managed')
                expected_mode = 0o700
                if state != 'missing':
                    initial_mode = 0o755 if state == 'empty' else (0o750 if state == 'saved-insecure' else 0o700)
                    data.mkdir(mode=initial_mode)
                    data.chmod(initial_mode)
                if state.startswith('saved-'):
                    (data / 'database.db').write_bytes(b'preserved database bytes')
                    (data / 'identity.key').write_bytes(b'preserved identity fixture')
                env = dict(os.environ, PATH='/usr/bin:/bin', XGC_AGENT_DATA_DIR=str(data),
                           XGC_AGENT_MANAGED_ROOT=str(managed))
                prefix = 'set -euo pipefail; agent_user=%s; agent_group=%s;\n' % (os.getuid(), os.getgid())
                result = subprocess.run(['bash', '-c', prefix + block], env=env,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(data.stat().st_mode & 0o777, expected_mode)
                self.assertEqual((data.stat().st_uid, data.stat().st_gid), (os.getuid(), os.getgid()))
                self.assertEqual(managed.stat().st_mode & 0o777, 0o750)
                if state.startswith('saved-'):
                    self.assertEqual((data / 'database.db').read_bytes(), b'preserved database bytes')
                    self.assertEqual((data / 'identity.key').read_bytes(), b'preserved identity fixture')

    def test_entrypoint_does_not_adopt_foreign_nonempty_or_follow_symlink(self):
        text = (BASELINE / 'image-entrypoint.sh').read_text()
        block = text[text.index('data_dir="${XGC_AGENT_DATA_DIR:'):text.index('install -d -o "$agent_user" -g "$agent_group" -m 0750 -- "$managed_root"')]
        data = self.root / 'foreign'
        data.mkdir(mode=0o750)
        (data / 'identity.key').write_bytes(b'preserve foreign identity')
        # Compare a real directory owned by this test account against another
        # real account. Only the data block runs, so no privileged install occurs.
        other_user = 'nobody' if os.getuid() != 65534 else 'root'
        env = dict(os.environ, PATH='/usr/bin:/bin', XGC_AGENT_DATA_DIR=str(data))
        prefix = 'set -euo pipefail; agent_user=%s; agent_group=%s;\n' % (other_user, os.getgid())
        before = (data.stat().st_mode, data.stat().st_uid, data.stat().st_gid)
        result = subprocess.run(['bash', '-c', prefix + block], env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((data.stat().st_mode, data.stat().st_uid, data.stat().st_gid), before)
        link = self.root / 'linked-data'
        link.symlink_to(data, target_is_directory=True)
        env['XGC_AGENT_DATA_DIR'] = str(link)
        result = subprocess.run(['bash', '-c', prefix + block], env=env, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('symlink', result.stderr)
        self.assertTrue(link.is_symlink())
        self.assertEqual((data.stat().st_mode, data.stat().st_uid, data.stat().st_gid), before)
        self.assertEqual((data / 'identity.key').read_bytes(), b'preserve foreign identity')

    def test_profiles_keep_distinct_accounts_and_base_ros(self):
        expected = {
            'fs150-focal-noetic': ('marvsmart', 'focal', '20.04', 'noetic', 'ros-noetic-ros-base'),
            'scout-bionic-melodic': ('agilex', 'bionic', '18.04', 'melodic', 'ros-melodic-ros-base'),
            'scout-focal-noetic': ('nvidia', 'focal', '20.04', 'noetic', 'ros-noetic-ros-base'),
            'wheeltec-bionic-melodic': ('wheeltec', 'bionic', '18.04', 'melodic', 'ros-melodic-ros-base'),
        }
        self.assertEqual(set(PROFILES), set(expected))
        doc = json.loads((BASELINE / 'baselines.json').read_text())
        self.assertEqual(doc['selection']['defaults']['scout'], 'scout-bionic-melodic')
        self.assertNotIn('scout-focal-noetic', doc['selection']['defaults'].values())
        self.assertEqual(doc['selection']['explicit'], ['scout-focal-noetic'])
        self.assertNotEqual(PROFILES['scout-bionic-melodic']['username'], PROFILES['scout-focal-noetic']['username'])
        self.assertNotEqual(PROFILES['scout-bionic-melodic']['rosDistro'], PROFILES['scout-focal-noetic']['rosDistro'])
        for profile, (user, codename, version, distro, package) in expected.items():
            got = PROFILES[profile]
            self.assertEqual((got['username'], got['ubuntuCodename'], got['ubuntuVersionId'], got['rosDistro']),
                             (user, codename, version, distro))
            self.assertIn(package, got['packages'])

    def test_profile_user_must_match_the_preinstalled_account(self):
        env = dict(self.env, ONBOARD_BASELINE_USER='wheeltec')
        self.assertIn('user is marvsmart', self.invoke('check', '--profile', self.profile, env=env, expected=3).stderr)
        self.assertEqual(self.calls('apt-get'), [])
        self.state['uid'] = '1000'
        self.state['name'] = 'nvidia'
        self.state['missing_user'] = 'marvsmart'
        self.save()
        self.assertIn('must run as marvsmart', self.check(expected=3).stderr)


    def test_entrypoint_keeps_caller_endpoint_and_drops_old_catalog(self):
        entry = self.root / 'entrypoint.sh'
        entry.write_text(self.relocate((BASELINE / 'image-entrypoint.sh').read_text()))
        env = dict(self.env, ONBOARD_BASELINE_USER='robot-user',
                   XGC_AGENT_ID='w06-entrypoint-robot',
                   XGC_CORE_ENDPOINT='.251:9092',
                   XGC_AGENT_ADVERTISED_ENDPOINT='127.0.0.1:19090',
                   XGC_AGENT_DATA_DIR=str(self.root / 'data'),
                   XGC_AGENT_MANAGED_ROOT=str(self.root / 'managed'),
                   XGC_PROCESS_DEFINITION_PLUGINS='/opt/old/catalog',
                   XGC_ADAPTER_RUNTIME_UDS='/run/xgc2/adapter/runtime.sock')
        self.config.write_text('XGC_AGENT_ID=agent-01\nXGC_CORE_ENDPOINT=127.0.0.1:9092\n'
                               'XGC_PROCESS_DEFINITION_PLUGINS=/usr/share/xgc2-agent/process-definitions\n')
        prefix = self.root_namespace()
        result = subprocess.run(prefix + ['bash', str(entry)], env=env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        recorded = json.loads((self.root / 'agent-env.json').read_text())
        self.assertEqual(recorded['argv'], [])
        self.assertEqual(recorded['id'], 'w06-entrypoint-robot')
        self.assertEqual(recorded['core'], '.251:9092')
        self.assertIsNone(recorded['catalog'])
        self.assertIsNone(recorded['adapter'])
        self.assertEqual(self.calls('apt-get'), [])
        self.assertEqual(self.calls('dpkg'), [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
